defmodule Crawler.Sitemap.Document do
  @moduledoc false

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Charset
  alias Crawler.Charset.Encoding
  alias Crawler.Charset.Labels
  alias Crawler.Deadline
  alias Crawler.URL

  @text_elements ["loc", "link", "thumbnail_loc", "content_loc", "guid"]
  @image_elements ["thumbnail_loc", "content_loc"]
  @prose_elements ["title", "description", "summary", "subtitle", "caption", "keywords"]
  @catalogs %{
    "urlset" => :urlset,
    "sitemapindex" => :sitemapindex,
    "rss" => :rss,
    "feed" => :atom,
    "rdf" => :rdf
  }
  @limit_keys [
    :max_body,
    :max_control_entries,
    :max_control_token_bytes,
    :max_xml_depth,
    :max_xml_tokens,
    :max_xml_attributes,
    :max_analysis_bytes
  ]

  # The shared analysis charge includes output, the document URL, active frames and operation
  # workspace. Binary occurrences are charged independently, without identity
  # tracking. Retained frame/output binaries are detached from their backing.
  # Fixed charges cover maps, list cells, spans, binary headers and alignment
  # on the 64-bit BEAM. Local scanner workspace allows 128 bytes per input
  # byte plus 4096 for attribute/scalar buffers, lists and small terms. URL
  # resolution owns its allocations through the same carried Budget value.
  # Input/transcoding buffers remain under max_body and the request envelope.
  @result_metadata_bytes 4_096
  @entry_metadata_bytes 1_024
  @frame_metadata_bytes 1_024
  @workspace_metadata_bytes 4_096
  @workspace_bytes_per_byte 128

  # Limits must already be normalized by the public options boundary.
  # Spans refer to the decoded UTF-8 document, before entity decoding.
  def parse(body, document_url, opts)
      when is_binary(body) and is_binary(document_url) and is_map(opts) do
    limits = document_limits(opts)
    deadline = Map.get(opts, :deadline)

    try do
      check_deadline!(deadline)
      bound!(byte_size(body), limits.max_body, :max_body)
      state = initial_state(limits, document_url, new_budget(limits), deadline)
      text = decode_document(body)
      if text == :error, do: throw({:document_error, :invalid_encoding})
      check_deadline!(deadline)
      bound!(byte_size(text), limits.max_body, :max_body)

      state =
        if String.starts_with?(String.trim_leading(text), "<"),
          do: walk(text, 0, state),
          else: text_lines(text, 0, %{state | kind: :text})

      check_deadline!(deadline)

      {:ok, document(state, byte_size(body), byte_size(text))}
    catch
      {:document_error, reason} -> {:error, reason}
    end
  end

  # The caller retains the analysis and collection while semantic output is live.
  # Only local frame/operation scratch is released; output stays on the carried ledger.
  def from_analysis(%Analysis{} = analysis, collection, opts) when is_map(opts) do
    with {:ok, budget} <- Analysis.continuation_budget(analysis, collection),
         :xml <- analysis.mode,
         %{kind: :xml} = root <- analysis.regions[analysis.root] do
      limits = document_limits(opts)
      deadline = Map.get(opts, :deadline)

      try do
        check_deadline!(deadline)

        if budget.limit != limits.max_analysis_bytes,
          do: document_error(:incompatible_analysis_limits)

        bound!(byte_size(root.source), limits.max_body, :max_body)
        lexical_limits!(root.facts, limits)
        base = opts[:referrer_url] || opts[:url] || ""
        state = initial_state(limits, base, budget, deadline)
        state = fact_elements(root.facts.tags, state, 0)
        state = finish(state, byte_size(root.source))
        state = lexical_stats(state, root.facts)
        check_deadline!(deadline)
        document = document(state, byte_size(root.source), byte_size(root.source))
        {:ok, document, %{collection | budget: state.budget}}
      catch
        {:document_error, reason} -> {:error, reason}
      end
    else
      {:error, _reason} = error -> error
      _root -> {:error, :unsupported_analysis_mode}
    end
  end

  defp lexical_limits!(%{document_summary: stats}, limits) do
    for {field, key} <- [
          tokens: :max_xml_tokens,
          max_token_bytes: :max_control_token_bytes,
          max_scalar_bytes: :max_control_token_bytes,
          max_depth: :max_xml_depth,
          max_attributes: :max_xml_attributes
        ] do
      bound!(Map.fetch!(stats, field), Map.fetch!(limits, key), key)
    end
  end

  defp lexical_stats(state, %{document_summary: stats}) do
    %{
      state
      | tokens: stats.tokens,
        max_token_bytes: stats.max_token_bytes,
        max_scalar_bytes: stats.max_scalar_bytes,
        max_depth: stats.max_depth,
        attributes: stats.attributes,
        max_attributes: stats.max_attributes
    }
  end

  defp document_limits(opts) do
    limits = Map.take(opts, @limit_keys)
    Enum.each(@limit_keys, &Map.fetch!(limits, &1))
    limits
  end

  defp fact_elements([], state, 0), do: state

  defp fact_elements([%{header?: true} | rest], state, skipped),
    do: fact_elements(rest, state, skipped)

  defp fact_elements([tag | rest], state, skipped) do
    check_deadline!(state.deadline)
    state = token(state, elem(tag.span, 1))

    cond do
      tag.closing? and skipped > 1 ->
        fact_elements(rest, state, skipped - 1)

      tag.closing? ->
        fact_elements(rest, pop_frame(state), 0)

      skipped > 0 ->
        state =
          state
          |> attributes(length(tag.attributes))
          |> record_depth(state.depth + skipped)

        skipped = if tag.self_closing?, do: skipped, else: skipped + 1
        fact_elements(rest, state, skipped)

      true ->
        {state, workspace} = reserve_workspace(state, elem(tag.span, 1))
        local = String.downcase(tag.name, :ascii)

        located_attrs =
          Enum.map(tag.attributes, fn attr ->
            {String.downcase(attr.qualified_name, :ascii), attr.decoded, attr.value_span}
          end)

        attrs = element_attributes(located_attrs)

        {frame, parent, depth, state} =
          begin_element(local, attrs, length(located_attrs), state)

        text? = local in @text_elements and not tag.self_closing?
        prose? = prose?(local, attrs) and not tag.self_closing?
        {text, span, state, scalar_workspace} = fact_text(tag, local, parent, attrs, text?, state)
        state = add_entry(state, local, parent, attrs, text, frame.base, located_attrs, span)

        state =
          if tag.self_closing?,
            do: release_frame(state, frame),
            else: %{state | stack: [frame | state.stack], depth: depth}

        state = release_working(state, workspace + scalar_workspace)
        fact_elements(rest, state, if(text? or prose?, do: 1, else: 0))
    end
  end

  defp fact_text(_tag, _local, _parent, _attrs, false, state), do: {"", nil, state, 0}

  defp fact_text(tag, local, parent, attrs, true, state) do
    cond do
      tag.content_scalar? ->
        {_, size} = tag.content_span
        state = scalar(state, size)
        {state, workspace} = reserve_workspace(state, size)
        {String.trim(tag.content), tag.content_span, state, workspace}

      text_candidate?(local, parent, attrs) ->
        document_error(:unsupported_control_scalar_markup)

      true ->
        {"", nil, state, 0}
    end
  end

  defp text_candidate?("loc", parent, _attrs), do: parent in ["url", "sitemap", "image"]
  defp text_candidate?(local, _parent, _attrs) when local in @image_elements, do: true

  defp text_candidate?("link", "item", attrs),
    do: not (is_binary(blank(attrs["href"])) and enclosure?(attrs["rel"]))

  defp text_candidate?("guid", "item", attrs), do: permalink?(attrs)
  defp text_candidate?(_local, _parent, _attrs), do: false

  defp initial_state(limits, document_url, budget, deadline) do
    prior_retained = budget.retained
    context_bytes = byte_size(document_url)
    budget = budget!(Budget.charge(budget, @result_metadata_bytes))
    budget = budget!(Budget.reserve(budget, context_bytes))
    document_url = :binary.copy(document_url)

    %{
      entries: [],
      budget: budget,
      prior_retained: prior_retained,
      context_bytes: context_bytes,
      frame_bytes: 0,
      working_bytes: context_bytes,
      peak_working_bytes:
        max(context_bytes, budget.peak - prior_retained - @result_metadata_bytes),
      peak_analysis_bytes: budget.peak,
      output_bytes: @result_metadata_bytes,
      output_binary_bytes: 0,
      output_metadata_bytes: @result_metadata_bytes,
      entry_count: 0,
      tokens: 0,
      frames: 0,
      max_depth: 0,
      consumed_bytes: 0,
      base_resolutions: 0,
      max_scalar_bytes: 0,
      max_token_bytes: 0,
      attributes: 0,
      max_attributes: 0,
      kind: nil,
      stack: [],
      depth: 0,
      limits: limits,
      deadline: deadline,
      document_url: document_url
    }
  end

  defp document(state, input_bytes, decoded_bytes) do
    %{
      kind: state.kind || :xml,
      entries: Enum.reverse(state.entries),
      span_source: :decoded_utf8,
      stats: %{
        input_bytes: input_bytes,
        prior_analysis_bytes: state.prior_retained,
        analysis_bytes: state.budget.retained,
        decoded_bytes: decoded_bytes,
        consumed_bytes: state.consumed_bytes,
        xml_tokens: state.tokens,
        frames_created: state.frames,
        max_depth: state.max_depth,
        base_resolutions: state.base_resolutions,
        entries: length(state.entries),
        entry_candidates: state.entry_count,
        working_bytes: state.working_bytes,
        peak_working_bytes: state.peak_working_bytes,
        peak_analysis_bytes: state.peak_analysis_bytes,
        output_bytes: state.output_bytes,
        output_binary_bytes: state.output_binary_bytes,
        output_metadata_bytes: state.output_metadata_bytes,
        attributes: state.attributes,
        max_attributes: state.max_attributes,
        max_scalar_bytes: state.max_scalar_bytes,
        max_token_bytes: state.max_token_bytes
      }
    }
  end

  defp walk(<<>>, offset, state), do: finish(state, offset)

  defp walk(body, offset, state) do
    check_deadline!(state.deadline)

    case body do
      <<"<!--", _::binary>> ->
        marked(body, offset, state, "-->")

      <<"<![CDATA[", _::binary>> ->
        marked(body, offset, state, "]]>")

      <<"<?", _::binary>> ->
        marked(body, offset, state, "?>")

      <<"<!", _::binary>> ->
        size = declaration_size(body, state)
        walk(drop(body, size), offset + size, token(state, size))

      <<"</", _::binary>> ->
        {size, _attrs, _self_closing, state, workspace} = tag(body, offset, state)
        state = state |> token(size) |> release_working(workspace) |> pop_frame()
        walk(drop(body, size), offset + size, state)

      <<"<", rest::binary>> ->
        if name_start?(state.deadline, rest) do
          element(body, offset, state)
        else
          walk(rest, offset + 1, token(state, 1))
        end

      _ ->
        size = plain_length(body, state.limits.max_control_token_bytes)
        state = state |> token(size) |> scalar(size)
        walk(drop(body, size), offset + size, state)
    end
  end

  defp element(body, offset, state) do
    {size, located_attrs, self_closing?, state, tag_workspace} = tag(body, offset, state)
    {name, _} = take_name(drop(binary_part(body, 0, size), 1))
    local = local_name(name)

    attrs = element_attributes(located_attrs)

    {frame, parent, depth, state} =
      begin_element(local, attrs, length(located_attrs), token(state, size))

    base = frame.base
    rest = drop(body, size)

    cond do
      prose?(local, attrs) and not self_closing? ->
        state = add_entry(state, local, parent, attrs, "", base, located_attrs, nil)
        window = window(rest, state)
        {state, scalar_workspace} = reserve_workspace(state, byte_size(window))
        tail = skip_prose(state.deadline, window, local)
        consumed = byte_size(window) - byte_size(tail)
        ensure_window!(rest, window, tail, state)
        state = scalar(state, consumed)
        state = scalar_budget(binary_part(rest, 0, consumed), offset + size, state, depth)
        state = state |> release_working(scalar_workspace + tag_workspace) |> release_frame(frame)
        walk(drop(rest, consumed), offset + size + consumed, state)

      local in @text_elements and not self_closing? ->
        window = window(rest, state)
        {state, scalar_workspace} = reserve_workspace(state, byte_size(window))
        {value, tail} = read_text(state.deadline, window)
        consumed = byte_size(window) - byte_size(tail)
        ensure_window!(rest, window, tail, state)
        state = scalar(state, consumed)
        state = scalar_budget(binary_part(rest, 0, consumed), offset + size, state, depth)
        span = {offset + size, consumed}
        state = add_entry(state, local, parent, attrs, value, base, located_attrs, span)
        remaining = drop(rest, consumed)

        {closing_size, state} =
          case remaining do
            <<"</", _::binary>> ->
              {n, _, _, state, closing_workspace} =
                tag(remaining, offset + size + consumed, state)

              {n, state |> token(n) |> release_working(closing_workspace)}

            _ ->
              {0, state}
          end

        state = state |> release_working(scalar_workspace + tag_workspace) |> release_frame(frame)
        walk(drop(remaining, closing_size), offset + size + consumed + closing_size, state)

      true ->
        state = add_entry(state, local, parent, attrs, "", base, located_attrs, nil)

        state =
          if self_closing?,
            do: release_frame(state, frame),
            else: %{state | stack: [frame | state.stack], depth: depth}

        walk(rest, offset + size, release_working(state, tag_workspace))
    end
  end

  defp element_attributes(located_attrs) do
    Enum.reduce(located_attrs, %{}, fn {key, value, _span}, attrs ->
      Map.put_new(attrs, key, value)
    end)
  end

  defp begin_element(local, attrs, attribute_count, state) do
    state = attributes(state, attribute_count)
    depth = state.depth + 1
    state = record_depth(state, depth)

    parent =
      case state.stack do
        [frame | _] -> frame.local
        [] -> ""
      end

    inherited =
      case state.stack do
        [frame | _] -> frame.base
        [] -> state.document_url
      end

    {frame, state} = new_frame(local, attrs["xml:base"], inherited, state)
    state = if state.kind, do: state, else: %{state | kind: Map.get(@catalogs, local, :xml)}
    {frame, parent, depth, state}
  end

  defp window(body, state),
    do: binary_part(body, 0, min(byte_size(body), state.limits.max_control_token_bytes + 2))

  defp ensure_window!(body, window, tail, state) do
    consumed = byte_size(window) - byte_size(tail)
    bound!(consumed, state.limits.max_control_token_bytes, :max_control_token_bytes)

    if tail == "" and byte_size(body) > byte_size(window),
      do: throw({:document_error, {:limit, :max_control_token_bytes}})
  end

  defp marked(body, offset, state, marker) do
    size = marker_size(body, marker, state)
    walk(drop(body, size), offset + size, token(state, size))
  end

  defp marker_size(body, marker, state) do
    candidate = window(body, state)

    size =
      case :binary.match(candidate, marker) do
        {at, n} -> at + n
        :nomatch -> byte_size(candidate)
      end

    bound!(size, state.limits.max_control_token_bytes, :max_control_token_bytes)
    check_deadline!(state.deadline)
    size
  end

  defp declaration_size(body, state), do: declaration_size(body, 0, nil, 0, state)
  defp declaration_size(<<>>, size, _quote, _brackets, _state), do: size

  defp declaration_size(<<byte, rest::binary>>, size, quote, brackets, state) do
    bound!(size + 1, state.limits.max_control_token_bytes, :max_control_token_bytes)
    check_deadline!(state.deadline)

    cond do
      quote != nil ->
        declaration_size(rest, size + 1, if(byte == quote, do: nil, else: quote), brackets, state)

      byte in [?", ?'] ->
        declaration_size(rest, size + 1, byte, brackets, state)

      byte == ?[ ->
        declaration_size(rest, size + 1, nil, brackets + 1, state)

      byte == ?] ->
        declaration_size(rest, size + 1, nil, max(brackets - 1, 0), state)

      byte == ?> and brackets == 0 ->
        size + 1

      true ->
        declaration_size(rest, size + 1, nil, brackets, state)
    end
  end

  defp tag(body, offset, state) do
    size = tag_size(body, 0, nil, state)
    {state, workspace} = reserve_workspace(state, size)
    candidate = binary_part(body, 0, size)

    {_, name_rest} =
      take_name(
        String.trim_leading(
          drop(candidate, if(String.starts_with?(candidate, "</"), do: 2, else: 1))
        )
      )

    start = size - byte_size(name_rest)
    attrs = read_attributes(name_rest, offset + start, [], 0, state)
    self_closing? = String.ends_with?(String.trim_trailing(candidate), "/>")
    {size, attrs, self_closing?, state, workspace}
  end

  defp tag_size(<<>>, size, _quote, _state), do: size

  defp tag_size(<<byte, rest::binary>>, size, quote, state) do
    bound!(size + 1, state.limits.max_control_token_bytes, :max_control_token_bytes)
    check_deadline!(state.deadline)

    cond do
      quote != nil -> tag_size(rest, size + 1, if(byte == quote, do: nil, else: quote), state)
      byte in [?", ?'] -> tag_size(rest, size + 1, byte, state)
      byte == ?> -> size + 1
      true -> tag_size(rest, size + 1, nil, state)
    end
  end

  defp read_attributes(body, offset, acc, count, state) do
    rest = skip_space(body)
    offset = offset + byte_size(body) - byte_size(rest)

    case rest do
      <<>> ->
        Enum.reverse(acc)

      <<byte, _::binary>> when byte in [?>, ?/] ->
        Enum.reverse(acc)

      _ ->
        {name, tail} = take_name(rest)

        if name == "" do
          read_attributes(drop(rest, 1), offset + 1, acc, count, state)
        else
          bound!(count + 1, state.limits.max_xml_attributes, :max_xml_attributes)
          after_name = skip_space(tail)

          read_attribute_value(after_name, name, rest, offset, acc, count, state)
        end
    end
  end

  defp read_attribute_value(<<"=", remaining::binary>>, name, rest, offset, acc, count, state) do
    value_body = skip_space(remaining)
    at = offset + byte_size(rest) - byte_size(value_body)
    {raw, next, quoted?} = attribute_value(value_body)
    span = {at + if(quoted?, do: 1, else: 0), byte_size(raw)}
    value = decode_entities(raw)
    next_at = offset + byte_size(rest) - byte_size(next)

    read_attributes(
      next,
      next_at,
      [{String.downcase(name, :ascii), value, span} | acc],
      count + 1,
      state
    )
  end

  defp read_attribute_value(after_name, name, rest, offset, acc, count, state) do
    next_at = offset + byte_size(rest) - byte_size(after_name)

    read_attributes(
      after_name,
      next_at,
      [{String.downcase(name, :ascii), "", nil} | acc],
      count + 1,
      state
    )
  end

  defp attribute_value(<<quote, rest::binary>>) when quote in [?", ?'] do
    case :binary.match(rest, <<quote>>) do
      {at, 1} -> {binary_part(rest, 0, at), drop(rest, at + 1), true}
      :nomatch -> {rest, "", true}
    end
  end

  defp attribute_value(body) do
    size = unquoted_size(body, 0)
    {binary_part(body, 0, size), drop(body, size), false}
  end

  defp unquoted_size(<<c, rest::binary>>, n) when c not in ~c" \t\n\r>/",
    do: unquoted_size(rest, n + 1)

  defp unquoted_size(_, n), do: n

  defp scalar_budget(body, offset, state, depth),
    do: scalar_budget(body, offset, state, depth, [])

  defp scalar_budget(<<>>, _offset, state, _depth, _stack), do: state

  defp scalar_budget(body, offset, state, depth, stack) do
    check_deadline!(state.deadline)

    case body do
      <<"<!--", _::binary>> ->
        prose_marker(body, offset, state, depth, stack, "-->")

      <<"<![CDATA[", _::binary>> ->
        prose_marker(body, offset, state, depth, stack, "]]>")

      <<"<?", _::binary>> ->
        prose_marker(body, offset, state, depth, stack, "?>")

      <<"</", rest::binary>> ->
        scalar_closing_tag(body, rest, offset, state, depth, stack)

      <<"<", rest::binary>> ->
        scalar_opening_tag(body, rest, offset, state, depth, stack)

      _ ->
        size = plain_length(body, state.limits.max_control_token_bytes)
        scalar_budget(drop(body, size), offset + size, token(state, size), depth, stack)
    end
  end

  defp scalar_opening_tag(body, rest, offset, state, depth, stack) do
    case tag_boundary(state.deadline, rest, "") do
      {:tag, name, tail, self_closing?} ->
        size = byte_size(body) - byte_size(tail)
        {_, attrs, _, state, workspace} = tag(binary_part(body, 0, size), offset, state)

        nested_depth =
          case stack do
            [{_, n} | _] -> n
            [] -> 0
          end

        state =
          state
          |> token(size)
          |> attributes(length(attrs))
          |> record_depth(depth + nested_depth + 1)

        stack = if self_closing?, do: stack, else: [{name, nested_depth + 1} | stack]
        scalar_budget(tail, offset + size, release_working(state, workspace), depth, stack)

      :text ->
        scalar_budget(rest, offset + 1, token(state, 1), depth, stack)
    end
  end

  defp scalar_closing_tag(body, rest, offset, state, depth, stack) do
    {name, _} = take_name(rest)

    case :binary.match(rest, [">", "<"]) do
      {n, 1} ->
        closing? = :binary.at(rest, n) == ?>
        size = n + 2 + if(closing?, do: 1, else: 0)

        stack =
          case stack do
            [{^name, _} | tail] -> tail
            _ -> stack
          end

        scalar_budget(drop(body, size), offset + size, token(state, size), depth, stack)

      :nomatch ->
        token(state, byte_size(body))
    end
  end

  defp prose_marker(body, offset, state, depth, stack, marker) do
    case :binary.match(body, marker) do
      {at, n} ->
        size = at + n
        scalar_budget(drop(body, size), offset + size, token(state, size), depth, stack)

      :nomatch ->
        scalar_budget(drop(body, 2), offset + 2, token(state, 2), depth, stack)
    end
  end

  defp text_lines(<<>>, offset, state), do: finish(state, offset)

  defp text_lines(body, offset, state) do
    check_deadline!(state.deadline)
    candidate = window(body, state)

    size =
      case :binary.match(candidate, ["\r", "\n"]) do
        {at, _} -> at
        :nomatch -> byte_size(candidate)
      end

    state = state |> scalar(size) |> token(size)
    {state, workspace} = reserve_workspace(state, size)
    raw = binary_part(body, 0, size)

    state =
      if absolute_http?(String.trim(raw)),
        do:
          resolved_entry(
            state,
            :page,
            String.trim(raw),
            state.document_url,
            %{element: nil, attribute: nil},
            {offset, size}
          ),
        else: state

    consumed = if size < byte_size(body), do: size + 1, else: size
    text_lines(drop(body, consumed), offset + consumed, release_working(state, workspace))
  end

  defp new_frame(local, raw, inherited, state) do
    value = blank(raw)

    if value do
      bound!(byte_size(value), state.limits.max_control_token_bytes, :max_control_token_bytes)
      bound!(byte_size(inherited), state.limits.max_control_token_bytes, :max_control_token_bytes)
    end

    base_capacity = if value, do: state.limits.max_control_token_bytes, else: byte_size(inherited)
    reservation = @frame_metadata_bytes + byte_size(local) + base_capacity
    state = reserve_working(state, reservation)
    {base, state, url_charge} = resolve_base(value, inherited, state)
    charge = @frame_metadata_bytes + byte_size(local) + byte_size(base)
    frame = %{local: :binary.copy(local), base: :binary.copy(base), charge: charge}
    state = release_working(state, reservation - charge)
    state = release_url(state, url_charge)
    {frame, %{state | frames: state.frames + 1, frame_bytes: state.frame_bytes + charge}}
  end

  defp resolve_base(nil, inherited, state), do: {inherited, state, 0}

  defp resolve_base(value, inherited, state) do
    state = %{state | base_resolutions: state.base_resolutions + 1}

    case resolve_url(value, inherited, state) do
      {:ok, base, state, charge} ->
        bound!(byte_size(base), state.limits.max_control_token_bytes, :max_control_token_bytes)
        {base, state, charge}

      {:skip, state} ->
        {inherited, state, 0}
    end
  end

  defp pop_frame(%{stack: [frame | tail]} = state) do
    state = release_frame(state, frame)
    %{state | stack: tail, depth: state.depth - 1}
  end

  defp pop_frame(state), do: state

  defp release_frame(state, frame) do
    budget = budget!(Budget.release(state.budget, frame.charge))
    update_budget(%{state | frame_bytes: state.frame_bytes - frame.charge}, budget)
  end

  defp finish(
         %{working_bytes: working, frame_bytes: frames, context_bytes: context} = state,
         offset
       )
       when working == frames + context do
    budget = budget!(Budget.release(state.budget, working))

    state = %{
      state
      | stack: [],
        depth: 0,
        frame_bytes: 0,
        context_bytes: 0,
        document_url: nil,
        consumed_bytes: offset
    }

    update_budget(state, budget)
  end

  defp add_entry(state, local, parent, attrs, text, base, located_attrs, text_span) do
    case classify(local, parent, attrs, text) do
      {kind, raw} ->
        attribute =
          cond do
            local == "link" and is_binary(blank(attrs["href"])) and
                (parent != "item" or enclosure?(attrs["rel"])) ->
              "href"

            local == "content" and is_binary(blank(attrs["url"])) ->
              "url"

            local == "content" and is_binary(blank(attrs["src"])) ->
              "src"

            local in ["enclosure", "thumbnail"] ->
              "url"

            true ->
              nil
          end

        span = entry_span(attribute, located_attrs, text_span)

        source = %{element: local, parent: parent, attribute: attribute}
        resolved_entry(state, kind, raw, base, source, span)

      :skip ->
        state
    end
  end

  defp entry_span(nil, _located_attrs, text_span), do: text_span

  defp entry_span(attribute, located_attrs, _text_span) do
    Enum.find_value(located_attrs, fn {key, _value, span} ->
      if key == attribute, do: span
    end)
  end

  defp resolved_entry(state, kind, raw, base, source, span) do
    # Count candidates before resolution so invalid URLs cannot evade the work budget.
    count = state.entry_count + 1
    bound!(count, state.limits.max_control_entries, :max_control_entries)
    state = %{state | entry_count: count}

    bound!(byte_size(raw), state.limits.max_control_token_bytes, :max_control_token_bytes)
    bound!(byte_size(base), state.limits.max_control_token_bytes, :max_control_token_bytes)

    case resolve_url(raw, base, state) do
      {:ok, url, state, url_charge} ->
        binary_bytes = output_binary_bytes([url, raw, base | Map.values(source)], state)
        output_bytes = state.output_bytes + @entry_metadata_bytes + binary_bytes
        budget = budget!(Budget.charge(state.budget, @entry_metadata_bytes + binary_bytes))
        state = update_budget(%{state | output_bytes: output_bytes}, budget)
        check_deadline!(state.deadline)

        # Detach every binary field so its charged size also bounds its backing.
        entry = %{
          url: :binary.copy(url),
          raw: :binary.copy(raw),
          role: if(kind == :child, do: :control, else: kind),
          control_kind: if(kind == :child, do: :sitemap, else: nil),
          source: Map.new(source, fn {key, value} -> {key, copy_optional(value)} end),
          span: span,
          effective_base: :binary.copy(base)
        }

        state = %{
          state
          | entries: [entry | state.entries],
            output_binary_bytes: state.output_binary_bytes + binary_bytes,
            output_metadata_bytes: state.output_metadata_bytes + @entry_metadata_bytes
        }

        release_url(state, url_charge)

      {:skip, state} ->
        state
    end
  end

  defp resolve_url(raw, base, state) do
    retained = state.budget.retained

    case URL.resolve_result(raw, base, state.budget) do
      {:ok, url, budget} ->
        check_deadline!(state.deadline)
        {:ok, url, update_budget(state, budget), budget.retained - retained}

      {:skip, budget} ->
        check_deadline!(state.deadline)
        {:skip, update_budget(state, budget)}

      {:error, reason} ->
        document_error(reason)
    end
  end

  defp release_url(state, charge),
    do: update_budget(state, budget!(Budget.refund(state.budget, charge)))

  defp output_binary_bytes(fields, state) do
    Enum.reduce(fields, 0, fn
      nil, bytes ->
        bytes

      value, bytes ->
        size = byte_size(value)
        bound!(size, state.limits.max_control_token_bytes, :max_control_token_bytes)
        bytes + size
    end)
  end

  defp copy_optional(nil), do: nil
  defp copy_optional(value), do: :binary.copy(value)

  defp workspace_bytes(bytes), do: @workspace_metadata_bytes + @workspace_bytes_per_byte * bytes

  defp reserve_workspace(state, bytes) do
    charge = workspace_bytes(bytes)
    {reserve_working(state, charge), charge}
  end

  defp reserve_working(state, bytes) do
    check_deadline!(state.deadline)
    update_budget(state, budget!(Budget.reserve(state.budget, bytes)))
  end

  defp release_working(
         %{working_bytes: working, frame_bytes: frames, context_bytes: context} = state,
         bytes
       )
       when bytes >= 0 and bytes <= working - frames - context do
    update_budget(state, budget!(Budget.release(state.budget, bytes)))
  end

  defp update_budget(state, budget) do
    # The kernel peak includes released URL scratch and can predate this continuation.
    working = budget.retained + budget.scratch - state.prior_retained - state.output_bytes

    %{
      state
      | budget: budget,
        working_bytes: working,
        peak_working_bytes:
          max(state.peak_working_bytes, budget.peak - state.prior_retained - state.output_bytes),
        peak_analysis_bytes: budget.peak
    }
  end

  # Native XML/entry counters keep their existing semantics; URL work uses bytes.
  defp new_budget(limits) do
    Budget.new(%{
      max_total_bytes: limits.max_analysis_bytes,
      max_facts: limits.max_xml_tokens,
      max_regions: limits.max_xml_tokens,
      max_occurrences: limits.max_control_entries,
      max_edits: 0
    })
  end

  defp budget!({:ok, budget}), do: budget
  defp budget!({:error, reason}), do: document_error(reason)

  @spec document_error(term()) :: no_return()
  defp document_error({:limit, :analysis_bytes}),
    do: throw({:document_error, {:limit, :max_analysis_bytes}})

  defp document_error(reason), do: throw({:document_error, reason})

  defp token(state, bytes) do
    bound!(bytes, state.limits.max_control_token_bytes, :max_control_token_bytes)
    bound!(state.tokens + 1, state.limits.max_xml_tokens, :max_xml_tokens)
    %{state | tokens: state.tokens + 1, max_token_bytes: max(state.max_token_bytes, bytes)}
  end

  defp scalar(state, bytes) do
    bound!(bytes, state.limits.max_control_token_bytes, :max_control_token_bytes)
    %{state | max_scalar_bytes: max(state.max_scalar_bytes, bytes)}
  end

  defp attributes(state, n),
    do: %{state | attributes: state.attributes + n, max_attributes: max(state.max_attributes, n)}

  defp record_depth(state, n) do
    bound!(n, state.limits.max_xml_depth, :max_xml_depth)
    %{state | max_depth: max(state.max_depth, n)}
  end

  defp bound!(n, max, key) do
    if n > max, do: throw({:document_error, {:limit, key}})
  end

  defp check_deadline!(nil), do: :ok

  defp check_deadline!(deadline) do
    case Deadline.check(deadline) do
      :ok -> :ok
      {:error, reason} -> throw({:document_error, reason})
    end
  end

  defp drop(body, n), do: binary_part(body, n, byte_size(body) - n)

  defp plain_length(body, max) do
    candidate = binary_part(body, 0, min(byte_size(body), max + 1))

    case :binary.match(candidate, "<") do
      {n, _} -> n
      :nomatch -> byte_size(candidate)
    end
  end

  defp prose?(local, attrs),
    do: local in @prose_elements or (local == "content" and blank(attrs["url"]) == nil)

  defp local_name(name),
    do: name |> String.split(":", parts: 2) |> List.last() |> String.downcase(:ascii)

  defp skip_space(<<c, rest::binary>>) when c in ~c" \t\r\n", do: skip_space(rest)
  defp skip_space(body), do: body

  defp absolute_http?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        String.downcase(scheme, :ascii) in ["http", "https"]

      _ ->
        false
    end
  end

  defp bounded_integer(text, radix) do
    digits = String.trim_leading(text, "0")

    cond do
      digits == "" -> 0
      byte_size(digits) > 8 -> -1
      true -> String.to_integer(digits, radix)
    end
  end

  defp take_name(rest) do
    size = name_size(rest, 0)
    <<name::binary-size(size), rest::binary>> = rest
    {name, rest}
  end

  defp name_size(<<char, rest::binary>>, size)
       when char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char in [?_, ?-, ?:, ?.] do
    name_size(rest, size + 1)
  end

  defp name_size(_rest, size), do: size

  defp decode_document(body) do
    case Encoding.bom(body) do
      {:utf8, rest} -> Encoding.to_utf8(rest)
      {:utf16, endian, rest} -> Encoding.to_utf16(rest, endian)
      :none -> decode_without_bom(body)
    end
  end

  # encoding="UTF-16" does not say which byte order. The "<?xml" bytes do.
  defp decode_without_bom(body) do
    Charset.utf16_xml(body) || decode_declared_document(body)
  end

  defp decode_declared_document(body) do
    case declared_encoding(ascii_prefix(body)) do
      {:known, label} -> decode_declared(body, label)
      _unknown_or_missing -> if(String.valid?(body), do: body, else: :error)
    end
  end

  # Charset may already have decoded a text/xml body and left the declaration.
  # Decoding those UTF-8 bytes again corrupts a non-ASCII address. Raw
  # single-byte bytes are not valid UTF-8, so they still use the declaration.
  # Raw UTF-16 is handled above.
  defp decode_declared(body, label) do
    if String.valid?(body) do
      body
    else
      decode_raw(body, label)
    end
  end

  defp decode_raw(body, label) do
    case Encoding.encoding(label) do
      {:utf16, _endian} -> :error
      _encoding -> Encoding.decode_label(body, label)
    end
  end

  defp ascii_prefix(body) do
    size = ascii_size(body, 0, min(byte_size(body), 512))
    binary_part(body, 0, size)
  end

  defp ascii_size(_body, size, limit) when size >= limit, do: size

  defp ascii_size(body, size, limit) do
    if :binary.at(body, size) < 128, do: ascii_size(body, size + 1, limit), else: size
  end

  defp declared_encoding(prefix) do
    prefix = String.trim_leading(prefix)

    if String.starts_with?(String.downcase(prefix, :ascii), "<?xml") do
      encoding_label(prefix |> String.split("?>", parts: 2) |> hd())
    else
      :none
    end
  end

  defp encoding_label(prolog) do
    case Regex.run(~r/encoding\s*=\s*["']([^"']+)["']/i, prolog) do
      [_, label] -> known_label(Labels.normalize(label))
      _none -> :none
    end
  end

  defp known_label(label) when is_binary(label) do
    if Encoding.encoding(label) == :unknown, do: :unknown, else: {:known, label}
  end

  defp known_label(_label), do: :unknown

  defp classify(local, parent, attrs, text) do
    href = blank(Map.get(attrs, "href"))
    rel = Map.get(attrs, "rel")
    src = blank(Map.get(attrs, "src"))
    url_attr = blank(Map.get(attrs, "url"))

    cond do
      local == "loc" and parent == "url" -> tagged(:page, text)
      local == "loc" and parent == "sitemap" -> tagged(:child, text)
      local == "loc" and parent == "image" -> tagged(:image, text)
      local in @image_elements -> tagged(:image, text)
      local == "link" and is_binary(href) and enclosure?(rel) -> tagged(:image, href)
      local == "link" and parent == "item" -> tagged(:page, text)
      local == "link" and parent == "entry" and entry_page?(rel) -> tagged(:page, href)
      local == "link" and parent == "url" and alternate?(rel) -> tagged(:page, href)
      local == "guid" and parent == "item" and permalink?(attrs) -> tagged(:page, http_text(text))
      local == "content" and is_binary(url_attr) -> tagged(:image, url_attr)
      local == "content" and parent == "entry" and is_binary(src) -> tagged(:page, src)
      local == "enclosure" and is_binary(url_attr) -> tagged(:image, url_attr)
      local == "thumbnail" and is_binary(url_attr) -> tagged(:image, url_attr)
      true -> :skip
    end
  end

  defp tagged(kind, text) do
    case blank(text) do
      nil -> :skip
      url -> {kind, url}
    end
  end

  defp entry_page?(nil), do: true

  defp entry_page?(rel) when is_binary(rel) do
    case String.trim(rel) do
      "" -> true
      _other -> alternate?(rel)
    end
  end

  defp alternate?(rel), do: rel_token?(rel, "alternate")

  defp enclosure?(rel), do: rel_token?(rel, "enclosure")

  defp rel_token?(rel, token) when is_binary(rel) do
    rel
    |> String.split(~r/[\t\n\f\r ]+/, trim: true)
    |> Enum.any?(&(String.downcase(&1, :ascii) == token))
  end

  defp rel_token?(_rel, _token), do: false

  defp permalink?(attrs) do
    case attrs |> Map.get("ispermalink") |> blank() do
      nil -> true
      value -> String.downcase(value, :ascii) != "false"
    end
  end

  defp http_text(text) do
    case blank(text) do
      url when is_binary(url) -> if absolute_http?(url), do: url
      _none -> nil
    end
  end

  defp blank(nil), do: nil

  defp blank(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp decode_entities(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> decode_numeric()
    |> String.replace("&amp;", "&")
  end

  defp decode_numeric(text) do
    Regex.replace(~r/&#(?:([0-9]+)|[xX]([0-9A-Fa-f]+));/, text, fn
      _match, decimal, "" -> codepoint_char(bounded_integer(decimal, 10))
      _match, "", hex -> codepoint_char(bounded_integer(hex, 16))
    end)
  end

  defp codepoint_char(codepoint) do
    if codepoint?(codepoint), do: <<codepoint::utf8>>, else: ""
  end

  defp codepoint?(codepoint) when codepoint in 0..0xD7FF, do: true
  defp codepoint?(codepoint) when codepoint in 0xE000..0x10FFFF, do: true
  defp codepoint?(_codepoint), do: false

  defp skip_prose(deadline, rest, local) do
    check_deadline!(deadline)
    skip_prose(deadline, rest, local, 1)
  end

  defp skip_prose(deadline, rest, _local, 0) do
    check_deadline!(deadline)
    rest
  end

  defp skip_prose(deadline, <<>>, _local, _depth) do
    check_deadline!(deadline)
    <<>>
  end

  defp skip_prose(deadline, <<"<![CDATA[", rest::binary>>, local, depth) do
    check_deadline!(deadline)
    skip_marked(deadline, rest, "]]>", local, depth)
  end

  defp skip_prose(deadline, <<"<!--", rest::binary>>, local, depth) do
    check_deadline!(deadline)
    skip_marked(deadline, rest, "-->", local, depth)
  end

  defp skip_prose(deadline, <<"<?", rest::binary>>, local, depth) do
    check_deadline!(deadline)

    case take_instruction(deadline, rest, local) do
      {:closed, tail} -> skip_prose(deadline, tail, local, depth)
      :open -> skip_prose(deadline, rest, local, depth)
    end
  end

  defp skip_prose(deadline, <<"</", rest::binary>>, local, depth) do
    check_deadline!(deadline)

    case tag_boundary(deadline, rest, local) do
      {:tag, name, tail, _self_closing?} ->
        depth =
          if local_name(name) == local do
            depth - 1
          else
            depth
          end

        skip_prose(deadline, tail, local, depth)

      :text ->
        close_open_field(deadline, rest, local, depth)
    end
  end

  defp skip_prose(deadline, <<"<", rest::binary>>, local, depth) do
    check_deadline!(deadline)

    case tag_boundary(deadline, rest, local) do
      {:tag, name, tail, self_closing?} ->
        depth =
          if local_name(name) == local and not self_closing? do
            depth + 1
          else
            depth
          end

        skip_prose(deadline, tail, local, depth)

      :text ->
        skip_prose(deadline, rest, local, depth)
    end
  end

  defp skip_prose(deadline, <<_byte, rest::binary>>, local, depth) do
    check_deadline!(deadline)
    skip_prose(deadline, rest, local, depth)
  end

  defp close_open_field(deadline, rest, local, depth) do
    check_deadline!(deadline)

    if field_end?(deadline, rest, local) do
      release_field(deadline, rest, local, depth)
    else
      skip_prose(deadline, rest, local, depth)
    end
  end

  defp release_field(deadline, rest, _local, 1) do
    check_deadline!(deadline)
    rest
  end

  defp release_field(deadline, rest, local, depth) do
    check_deadline!(deadline)
    skip_prose(deadline, rest, local, depth - 1)
  end

  defp skip_marked(deadline, rest, marker, local, depth) do
    check_deadline!(deadline)

    case take_marker(deadline, rest, marker) do
      {_inner, rest} -> skip_prose(deadline, rest, local, depth)
      :missing -> skip_prose(deadline, rest, local, depth)
    end
  end

  defp take_instruction(deadline, rest, local) do
    check_deadline!(deadline)
    take_instruction(deadline, rest, local, :text)
  end

  defp take_instruction(deadline, <<"?>", rest::binary>>, _local, :text) do
    check_deadline!(deadline)
    {:closed, rest}
  end

  defp take_instruction(deadline, <<"</", rest::binary>>, local, :text) do
    check_deadline!(deadline)

    if field_end?(deadline, rest, local) do
      :open
    else
      take_instruction(deadline, rest, local, :text)
    end
  end

  defp take_instruction(deadline, <<"</", _rest::binary>> = rest, local, quote)
       when quote != :text do
    check_deadline!(deadline)

    if quote_crosses_field?(deadline, rest, local, quote) do
      :open
    else
      <<_byte, rest::binary>> = rest
      take_instruction(deadline, rest, local, quote)
    end
  end

  defp take_instruction(deadline, <<"\"", rest::binary>>, local, :text) do
    check_deadline!(deadline)
    take_instruction(deadline, rest, local, :double)
  end

  defp take_instruction(deadline, <<"'", rest::binary>>, local, :text) do
    check_deadline!(deadline)
    take_instruction(deadline, rest, local, :single)
  end

  defp take_instruction(deadline, <<"\"", rest::binary>>, local, :double) do
    check_deadline!(deadline)
    take_instruction(deadline, rest, local, :text)
  end

  defp take_instruction(deadline, <<"'", rest::binary>>, local, :single) do
    check_deadline!(deadline)
    take_instruction(deadline, rest, local, :text)
  end

  defp take_instruction(deadline, <<_byte, rest::binary>>, local, quote) do
    check_deadline!(deadline)
    take_instruction(deadline, rest, local, quote)
  end

  defp take_instruction(deadline, <<>>, _local, _quote) do
    check_deadline!(deadline)
    :open
  end

  defp field_end?(deadline, rest, local) do
    check_deadline!(deadline)

    case field_mark(deadline, rest, local) do
      {:yes, _tail} -> true
      :no -> false
    end
  end

  defp field_mark(deadline, rest, local) do
    check_deadline!(deadline)

    {name, tail} = take_name(rest)

    if name != "" and local_name(name) == local do
      mark_tail(deadline, tail)
    else
      :no
    end
  end

  defp mark_tail(deadline, <<">", rest::binary>>) do
    check_deadline!(deadline)
    {:yes, rest}
  end

  defp mark_tail(deadline, <<"<", _rest::binary>> = rest) do
    check_deadline!(deadline)
    {:yes, rest}
  end

  defp mark_tail(deadline, <<byte, rest::binary>>) when byte in ~c" \t\n\r" do
    check_deadline!(deadline)
    mark_tail(deadline, rest)
  end

  defp mark_tail(deadline, _rest) do
    check_deadline!(deadline)
    :no
  end

  defp tag_boundary(deadline, rest, local) do
    check_deadline!(deadline)

    if name_start?(deadline, rest) do
      case scan_tag(deadline, rest, :text, false, local) do
        {:tag, after_tag, self_closing?} ->
          {name, _remainder} = take_name(rest)
          {:tag, name, after_tag, self_closing?}

        :text ->
          :text
      end
    else
      :text
    end
  end

  defp name_start?(deadline, <<char, _::binary>>)
       when char in ?A..?Z or char in ?a..?z or char in ~c"_:" do
    check_deadline!(deadline)
    true
  end

  defp name_start?(deadline, _rest) do
    check_deadline!(deadline)
    false
  end

  defp scan_tag(deadline, <<">", rest::binary>>, :text, slash, _local) do
    check_deadline!(deadline)
    {:tag, rest, slash}
  end

  defp scan_tag(deadline, <<"<", _rest::binary>>, :text, _slash, _local) do
    check_deadline!(deadline)
    :text
  end

  defp scan_tag(deadline, <<"\"", rest::binary>>, :text, _slash, local) do
    check_deadline!(deadline)
    scan_tag(deadline, rest, :double, false, local)
  end

  defp scan_tag(deadline, <<"'", rest::binary>>, :text, _slash, local) do
    check_deadline!(deadline)
    scan_tag(deadline, rest, :single, false, local)
  end

  defp scan_tag(deadline, <<"/", rest::binary>>, :text, _slash, local) do
    check_deadline!(deadline)
    scan_tag(deadline, rest, :text, true, local)
  end

  defp scan_tag(deadline, <<byte, rest::binary>>, :text, slash, local) when byte in ~c" \t\n\r" do
    check_deadline!(deadline)
    scan_tag(deadline, rest, :text, slash, local)
  end

  defp scan_tag(deadline, <<_byte, rest::binary>>, :text, _slash, local) do
    check_deadline!(deadline)
    scan_tag(deadline, rest, :text, false, local)
  end

  defp scan_tag(deadline, <<"</", _rest::binary>> = rest, quote, _slash, local)
       when quote != :text do
    check_deadline!(deadline)

    if quote_crosses_field?(deadline, rest, local, quote) do
      :text
    else
      <<_byte, rest::binary>> = rest
      scan_tag(deadline, rest, quote, false, local)
    end
  end

  defp scan_tag(deadline, <<"\"", rest::binary>>, :double, _slash, local) do
    check_deadline!(deadline)
    scan_tag(deadline, rest, :text, false, local)
  end

  defp scan_tag(deadline, <<"'", rest::binary>>, :single, _slash, local) do
    check_deadline!(deadline)
    scan_tag(deadline, rest, :text, false, local)
  end

  defp scan_tag(deadline, <<_byte, rest::binary>>, quote, _slash, local) when quote != :text do
    check_deadline!(deadline)
    scan_tag(deadline, rest, quote, false, local)
  end

  defp scan_tag(deadline, <<>>, _quote, _slash, _local) do
    check_deadline!(deadline)
    :text
  end

  defp quote_crosses_field?(deadline, <<"</", rest::binary>>, local, quote) do
    check_deadline!(deadline)

    case field_mark(deadline, rest, local) do
      {:yes, tail} -> not quote_closes_first?(deadline, tail, quote)
      :no -> false
    end
  end

  defp quote_closes_first?(deadline, <<"<", _rest::binary>>, _quote) do
    check_deadline!(deadline)
    false
  end

  defp quote_closes_first?(deadline, <<"\"", _rest::binary>>, :double) do
    check_deadline!(deadline)
    true
  end

  defp quote_closes_first?(deadline, <<"'", _rest::binary>>, :single) do
    check_deadline!(deadline)
    true
  end

  defp quote_closes_first?(deadline, <<_byte, rest::binary>>, quote) do
    check_deadline!(deadline)
    quote_closes_first?(deadline, rest, quote)
  end

  defp quote_closes_first?(deadline, <<>>, _quote) do
    check_deadline!(deadline)
    false
  end

  defp read_text(deadline, rest) do
    check_deadline!(deadline)
    read_text(deadline, rest, [])
  end

  defp read_text(deadline, <<"<?", rest::binary>>, parts) do
    check_deadline!(deadline)

    case take_marker(deadline, rest, "?>") do
      {_instruction, rest} -> read_text(deadline, rest, parts)
      :missing -> read_text(deadline, rest, [{:text, "<?"} | parts])
    end
  end

  defp read_text(deadline, <<"<![CDATA[", rest::binary>>, parts) do
    check_deadline!(deadline)

    case take_marker(deadline, rest, "]]>") do
      {inner, rest} -> read_text(deadline, rest, [{:raw, inner} | parts])
      :missing -> {join_text(deadline, [{:raw, rest} | parts]), ""}
    end
  end

  defp read_text(deadline, <<"<!--", rest::binary>>, parts) do
    check_deadline!(deadline)

    case take_marker(deadline, rest, "-->") do
      {_comment, rest} -> read_text(deadline, rest, parts)
      :missing -> {join_text(deadline, parts), ""}
    end
  end

  defp read_text(deadline, <<"</", _rest::binary>> = rest, parts) do
    check_deadline!(deadline)
    {join_text(deadline, parts), rest}
  end

  defp read_text(deadline, <<>>, parts) do
    check_deadline!(deadline)
    {join_text(deadline, parts), ""}
  end

  defp read_text(deadline, <<"<", rest::binary>>, parts) do
    check_deadline!(deadline)
    read_text(deadline, rest, [{:text, "<"} | parts])
  end

  defp read_text(deadline, rest, parts) do
    check_deadline!(deadline)

    size = plain_size(deadline, rest, 0)
    <<chunk::binary-size(size), rest::binary>> = rest
    read_text(deadline, rest, [{:text, chunk} | parts])
  end

  defp plain_size(deadline, <<"<", _rest::binary>>, size) do
    check_deadline!(deadline)
    size
  end

  defp plain_size(deadline, <<_byte, rest::binary>>, size) do
    check_deadline!(deadline)
    plain_size(deadline, rest, size + 1)
  end

  defp plain_size(deadline, <<>>, size) do
    check_deadline!(deadline)
    size
  end

  defp join_text(deadline, parts) do
    check_deadline!(deadline)

    parts
    |> Enum.reverse()
    |> Enum.map_join(fn
      {:raw, text} -> text
      {:text, text} -> decode_entities(text)
    end)
    |> String.trim()
  end

  defp take_marker(deadline, body, marker) do
    check_deadline!(deadline)

    case :binary.split(body, marker) do
      [before, rest] -> {before, rest}
      [_] -> :missing
    end
  end
end
