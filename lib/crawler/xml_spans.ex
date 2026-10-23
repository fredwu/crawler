defmodule Crawler.XMLSpans do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.MediaType

  @html "http://www.w3.org/1999/xhtml"
  @svg "http://www.w3.org/2000/svg"
  @math "http://www.w3.org/1998/Math/MathML"
  @xml "http://www.w3.org/XML/1998/namespace"
  @xmlns "http://www.w3.org/2000/xmlns/"
  @document_text_elements ~w(loc link thumbnail_loc content_loc guid)
  @document_prose_elements ~w(title description summary subtitle caption keywords)
  @empty_document_summary %{
    tokens: 0,
    max_token_bytes: 0,
    max_scalar_bytes: 0,
    max_depth: 0,
    max_attributes: 0,
    attributes: 0
  }
  @space ~c" \t\n\r"
  @entities %{"amp" => "&", "lt" => "<", "gt" => ">", "quot" => "\"", "apos" => "'"}
  # XML 1.0 Fifth Edition, productions 4 and 4a; QName parts exclude colons.
  @name_start ~S|A-Z_a-z\x{C0}-\x{D6}\x{D8}-\x{F6}\x{F8}-\x{2FF}\x{370}-\x{37D}\x{37F}-\x{1FFF}\x{200C}-\x{200D}\x{2070}-\x{218F}\x{2C00}-\x{2FEF}\x{3001}-\x{D7FF}\x{F900}-\x{FDCF}\x{FDF0}-\x{FFFD}\x{10000}-\x{EFFFF}|
  @name_char @name_start <> ~S|\-.0-9\x{B7}\x{300}-\x{36F}\x{203F}-\x{2040}|
  @ncname_pattern "[#{@name_start}][#{@name_char}]*"
  @ncname Regex.compile!("\\A#{@ncname_pattern}\\z", "u")
  @name Regex.compile!("\\A(?:#{@ncname_pattern}:)?#{@ncname_pattern}\\z", "u")

  def analyze(body, opts \\ []) when is_binary(body) do
    case analyze_result(body, opts, Budget.unlimited()) do
      {:ok, analysis, _budget} -> {:ok, analysis}
      {:error, _reason} = error -> error
    end
  end

  def analyze_result(body, opts, budget) when is_binary(body),
    do: analyze(body, opts, budget, :all)

  defp analyze(body, opts, budget, projection) do
    opts = Map.new(opts)
    document_text? = opts[:document_text] == true

    limits = %{
      bytes: Map.get(opts, :max_bytes, 20_000_000),
      depth: Map.get(opts, :max_depth, 256),
      tokens: Map.get(opts, :max_tokens, 100_000),
      attributes: Map.get(opts, :max_attributes, 1_024)
    }

    cond do
      not valid_limits?(limits) ->
        {:error, :invalid_limits}

      byte_size(body) > limits.bytes ->
        {:error, {:limit, :xml_bytes}}

      body == "" ->
        if document_text? and projection == :all do
          budget = charge!(budget, Budget.cost(:frame))
          {:ok, %{tags: [], instructions: [], document_summary: @empty_document_summary}, budget}
        else
          {:ok, %{tags: [], instructions: []}, budget}
        end

      true ->
        scratch =
          Budget.cost(:frame, 2) + Budget.cost(:map_entry, 2) +
            if(document_text?, do: Budget.cost(:frame), else: 0)

        budget = if document_text?, do: charge!(budget, Budget.cost(:frame)), else: budget

        type_scratch =
          512 +
            if(is_binary(opts[:content_type]), do: byte_size(opts[:content_type]) * 8, else: 0)

        budget = reserve!(budget, scratch + type_scratch)
        namespace = default_namespace(opts[:content_type])
        budget = release!(budget, type_scratch)

        state = %{
          stack: [],
          tags: [],
          contents: %{},
          instructions: [],
          tokens: 0,
          tag_count: 0,
          instruction_count: 0,
          instruction_bytes: 0,
          content_count: 0,
          budget: budget,
          parser_scratch: scratch,
          projection: projection,
          document_text?: document_text?,
          document_summary: if(document_text?, do: @empty_document_summary),
          default_namespace: namespace
        }

        walk(body, 0, state, %{"xml" => @xml, "" => nil}, limits)
    end
  catch
    {:xml_budget_error, reason} -> {:error, reason}
  end

  def tags(body, opts \\ []) do
    case tags_result(body, opts, Budget.unlimited()) do
      {:ok, tags, _budget} -> tags
      {:error, _reason} -> []
    end
  end

  def tags_result(body, opts, budget) do
    case analyze(body, opts, budget, :tags) do
      {:ok, analysis, budget} -> {:ok, analysis.tags, budget}
      {:error, _reason} = error -> error
    end
  end

  def resolve_bases(tags, base) do
    {:ok, tags, _budget} = resolve_bases_result(tags, base, Budget.unlimited())
    tags
  end

  def resolve_bases_result(tags, base, budget) do
    resolve_bases(tags, base, [], [], budget, 0)
  catch
    {:xml_budget_error, reason} -> {:error, reason}
  end

  defp resolve_bases([], _base, _stack, acc, budget, active) do
    budget = release!(budget, active)
    scratch = Budget.cost(:list_cell, length(acc))
    budget = reserve!(budget, scratch)
    tags = Enum.reverse(acc)
    {:ok, tags, release!(budget, scratch)}
  end

  defp resolve_bases([tag | rest], base, stack, acc, budget, active) do
    budget = charge!(budget, Budget.cost(:tag) + Budget.cost(:list_cell))

    inherited =
      case stack do
        [current | _rest] -> current
        [] -> base
      end

    if tag.closing? do
      {stack, budget, active} =
        case stack do
          [_current | tail] ->
            {tail, release!(budget, Budget.cost(:frame)), active - Budget.cost(:frame)}

          [] ->
            {[], budget, active}
        end

      resolve_bases(
        rest,
        base,
        stack,
        [Map.put(tag, :effective_base, inherited) | acc],
        budget,
        active
      )
    else
      {effective, budget} = merge_base(tag.xml_base, inherited, budget)

      {stack, budget, active} =
        if tag.self_closing? do
          {stack, budget, active}
        else
          budget = reserve!(budget, Budget.cost(:frame))
          {[effective | stack], budget, active + Budget.cost(:frame)}
        end

      resolve_bases(
        rest,
        base,
        stack,
        [Map.put(tag, :effective_base, effective) | acc],
        budget,
        active
      )
    end
  end

  def decode(value) do
    case decode_result(value, Budget.unlimited()) do
      {:ok, decoded, _budget} -> {:ok, decoded}
      {:error, _reason} -> :error
    end
  end

  def decode_result(value, budget) do
    case decode_with_spans_result(value, 0, :text, budget) do
      {:ok, decoded, segments, budget} ->
        {:ok, decoded, refund!(budget, segment_bytes(length(segments)))}

      {:error, _reason} = error ->
        error
    end
  end

  def decode_with_spans(value, offset \\ 0, context \\ :text) do
    case decode_with_spans_result(value, offset, context, Budget.unlimited()) do
      {:ok, decoded, segments, _budget} -> {:ok, decoded, segments}
      {:error, _reason} -> :error
    end
  end

  def decode_with_spans_result(value, offset, context, budget) do
    decode_parts(value, 0, offset, 0, [], [], context, budget, 0, 0)
  catch
    {:xml_budget_error, reason} -> {:error, reason}
  end

  defp summarize_token(state, bytes) do
    count = state.tokens + 1

    summary =
      if state.document_text? do
        %{
          state.document_summary
          | tokens: count,
            max_token_bytes: max(state.document_summary.max_token_bytes, bytes)
        }
      end

    %{state | tokens: count, document_summary: summary}
  end

  defp summarize_scalar(%{document_text?: false} = state, _bytes), do: state

  defp summarize_scalar(state, bytes) do
    %{
      state
      | document_summary: %{
          state.document_summary
          | max_scalar_bytes: max(state.document_summary.max_scalar_bytes, bytes)
        }
    }
  end

  defp summarize_attributes(%{document_text?: false} = state, _attrs), do: state

  defp summarize_attributes(state, attrs) do
    count = length(attrs)

    summary = %{
      state.document_summary
      | attributes: state.document_summary.attributes + count,
        max_attributes: max(state.document_summary.max_attributes, count)
    }

    Enum.reduce(attrs, %{state | document_summary: summary}, fn attr, state ->
      summarize_scalar(state, elem(attr.value_span, 1))
    end)
  end

  defp summarize_opening(state, attrs) do
    state = summarize_attributes(state, attrs)

    if state.document_text? do
      %{
        state
        | document_summary: %{
            state.document_summary
            | max_depth: max(state.document_summary.max_depth, length(state.stack) + 1)
          }
      }
    else
      state
    end
  end

  defp document_frame(_local, _attrs, false, budget), do: {nil, budget}

  defp document_frame(local, attrs, true, budget) do
    folded = if byte_size(local) <= 13, do: String.downcase(local, :ascii)
    capture? = folded in @document_text_elements

    {bounded?, budget} =
      cond do
        capture? or folded in @document_prose_elements -> {true, budget}
        folded == "content" -> content_prose(attrs, budget)
        true -> {false, budget}
      end

    {%{capture?: capture?, bounded?: bounded?, scalar?: true}, budget}
  end

  defp content_prose(attrs, budget) do
    attr =
      Enum.find(attrs, fn attr ->
        byte_size(attr.qualified_name) == 3 and
          String.downcase(attr.qualified_name, :ascii) == "url"
      end)

    if attr do
      scratch = Budget.cost(:frame, 2) + byte_size(attr.decoded) * 2
      budget = reserve!(budget, scratch)
      prose? = String.trim(attr.decoded) == ""
      {prose?, release!(budget, scratch)}
    else
      {true, budget}
    end
  end

  defp nested_scalar(
         %{stack: [%{document: %{capture?: true, scalar?: true} = document} = frame | rest]} =
           state
       ) do
    scratch = Budget.cost(:frame)
    budget = reserve!(state.budget, scratch)
    frame = %{frame | document: %{document | scalar?: false}}
    %{state | stack: [frame | rest], budget: release!(budget, scratch)}
  end

  defp nested_scalar(state), do: state

  defp scalar_marker(tag, %{capture?: true}, budget) do
    scratch = Budget.cost(:tag)
    budget = reserve!(budget, scratch)
    tag = Map.put(tag, :content_scalar?, true)
    {tag, release!(budget, scratch)}
  end

  defp scalar_marker(tag, _document, budget), do: {tag, budget}

  defp closing_marker(tag, %{capture?: true}, budget) do
    scratch = Budget.cost(:tag)
    budget = reserve!(budget, scratch)
    tag = Map.delete(tag, :content_scalar?)
    {tag, release!(budget, scratch)}
  end

  defp closing_marker(tag, _document, budget), do: {tag, budget}

  defp valid_limits?(limits) do
    Enum.all?(limits, fn
      {:bytes, value} -> is_integer(value) and value >= 0
      {_key, value} -> is_integer(value) and value > 0
    end)
  end

  defp default_namespace(type) do
    cond do
      MediaType.xhtml?(type) -> @html
      MediaType.svg?(type) -> @svg
      true -> nil
    end
  end

  defp walk(body, offset, state, _namespaces, _limits) when offset == byte_size(body) do
    if state.stack == [] do
      scratch =
        Budget.cost(:tag, state.tag_count) +
          Budget.cost(:list_cell, 2 * state.tag_count + state.instruction_count)

      budget = reserve!(state.budget, scratch)

      tags =
        state.tags
        |> Enum.reverse()
        |> Enum.map(fn tag -> Map.merge(tag, Map.get(state.contents, elem(tag.span, 0), %{})) end)

      instructions = if state.projection == :all, do: Enum.reverse(state.instructions), else: []

      budget =
        budget
        |> release!(scratch + state.parser_scratch)
        |> refund!(content_bytes(state.content_count))

      budget =
        if state.projection == :tags, do: refund!(budget, state.instruction_bytes), else: budget

      if state.document_text? and state.projection == :all do
        {:ok, %{tags: tags, instructions: instructions, document_summary: state.document_summary},
         budget}
      else
        budget = if state.document_text?, do: refund!(budget, Budget.cost(:frame)), else: budget
        {:ok, %{tags: tags, instructions: instructions}, budget}
      end
    else
      {:error, :invalid_xml}
    end
  end

  defp walk(body, offset, state, namespaces, limits) do
    with :ok <- token_limit(state, limits),
         {:ok, next, state} <- token(body, offset, state, namespaces, limits) do
      walk(body, next, summarize_token(state, next - offset), namespaces, limits)
    end
  end

  defp token_limit(%{tokens: count}, %{tokens: limit}) when count >= limit,
    do: {:error, {:limit, :xml_tokens}}

  defp token_limit(_state, _limits), do: :ok

  defp token(body, offset, state, namespaces, limits) do
    cond do
      starts?(body, offset, "<!--") -> terminated(body, offset + 4, "-->", state)
      starts?(body, offset, "<![CDATA[") -> cdata(body, offset + 9, state)
      starts?(body, offset, "<?") -> instruction(body, offset, state, limits)
      starts?(body, offset, "<!") -> declaration(body, offset + 2, state, nil, 0)
      starts?(body, offset, "</") -> closing(body, offset, state)
      starts?(body, offset, "<") -> opening(body, offset, state, namespaces, limits)
      true -> text(body, offset, state)
    end
  end

  defp terminated(body, offset, ending, state) do
    case match(body, offset, ending) do
      {finish, length} -> {:ok, finish + length, state}
      :nomatch -> {:error, :invalid_xml}
    end
  end

  defp text(body, offset, state) do
    finish =
      case match(body, offset, "<") do
        {at, _length} -> at
        :nomatch -> byte_size(body)
      end

    case decode_with_spans_result(
           binary_part(body, offset, finish - offset),
           offset,
           :text,
           state.budget
         ) do
      {:ok, decoded, segments, budget} ->
        state = summarize_scalar(%{state | budget: budget}, finish - offset)
        {:ok, finish, add_text(state, decoded, segments, :xml_text)}

      {:error, _reason} = error ->
        error
    end
  end

  defp cdata(body, offset, %{stack: [_frame | _rest]} = state) do
    case match(body, offset, "]]>") do
      {finish, 3} ->
        length = finish - offset

        {:ok, text, segments, budget} =
          decode_literal(binary_part(body, offset, length), offset, state.budget)

        state = summarize_scalar(%{state | budget: budget}, length)
        {:ok, finish + 3, add_text(state, text, segments, :xml_cdata)}

      :nomatch ->
        {:error, :invalid_xml}
    end
  end

  defp cdata(_body, _offset, _state), do: {:error, :invalid_xml}

  defp add_text(%{stack: [%{capture?: true} = frame | rest]} = state, text, segments, kind) do
    count = length(segments)
    scratch = segment_bytes(count) + Budget.cost(:list_cell, 2 * count + 1)
    budget = state.budget |> charge!(Budget.cost(:list_cell)) |> reserve!(scratch)

    segments =
      Enum.map(segments, fn {at, length, source_at, source_length} ->
        %{
          span: {source_at, source_length},
          decoded_span: {frame.text_size + at, length},
          kind: kind
        }
      end)

    frame = %{
      frame
      | text: [text | frame.text],
        text_size: frame.text_size + byte_size(text),
        text_count: frame.text_count + 1,
        segment_count: frame.segment_count + count,
        segments: Enum.reverse(segments, frame.segments)
    }

    budget = release!(budget, scratch)
    %{state | stack: [frame | rest], budget: budget}
  end

  defp add_text(state, text, segments, _kind) do
    bytes = binary_bytes(byte_size(text)) + segment_bytes(length(segments))
    %{state | budget: refund!(state.budget, bytes)}
  end

  defp opening(body, offset, state, namespaces, limits) do
    state = nested_scalar(state)

    with :ok <- depth_limit(state, limits),
         budget <- charge!(state.budget, Budget.cost(:tag) + Budget.cost(:list_cell), facts: 1),
         {:ok, qualified, after_name, budget} <- name(body, offset + 1, budget),
         {:ok, attrs, finish, self_closing?, budget} <-
           attributes(body, after_name, limits.attributes, budget),
         frame_scratch <-
           Budget.cost(:frame) +
             Budget.cost(
               :map_entry,
               namespace_size(state, namespaces) + length(attrs) + 1
             ) + if(state.document_text?, do: Budget.cost(:frame), else: 0),
         budget <- reserve!(budget, frame_scratch * 2),
         inherited <- inherited_namespaces(state, namespaces, attrs),
         {:ok, namespaces} <- bindings(attrs, inherited),
         {:ok, namespace, local} <- expanded_name(qualified, namespaces, true),
         {:ok, attrs, budget} <- expand_attributes(attrs, namespaces, budget) do
      budget = release!(budget, frame_scratch)
      {document_frame, budget} = document_frame(local, attrs, state.document_text?, budget)
      state = summarize_opening(state, attrs)

      tag = %{
        name: local,
        qualified_name: qualified,
        namespace: vocabulary(namespace),
        namespace_uri: namespace,
        closing?: false,
        self_closing?: self_closing?,
        span: {offset, finish - offset},
        source: binary_part(body, offset, finish - offset),
        attributes: attrs,
        content_span: nil,
        content: "",
        content_segments: [],
        xml_base: xml_base(attrs),
        in_template?: in_template?(state.stack),
        in_shadow_root?: false
      }

      {tag, budget} = scalar_marker(tag, document_frame, budget)

      {stack, budget} =
        if self_closing? do
          {state.stack, release!(budget, frame_scratch)}
        else
          frame = %{
            qualified_name: qualified,
            namespaces: namespaces,
            tag: tag,
            content_start: finish,
            capture?:
              (local in ["script", "style"] and namespace in [@html, @svg]) or
                (document_frame != nil and document_frame.capture?),
            document: document_frame,
            text: [],
            text_size: 0,
            text_count: 0,
            segment_count: 0,
            scratch: frame_scratch,
            segments: []
          }

          {[frame | state.stack], budget}
        end

      {:ok, finish,
       %{
         state
         | stack: stack,
           tags: [tag | state.tags],
           tag_count: state.tag_count + 1,
           budget: budget
       }}
    end
  end

  defp depth_limit(%{stack: stack}, %{depth: limit}) do
    if length(stack) >= limit, do: {:error, {:limit, :xml_depth}}, else: :ok
  end

  defp namespace_size(%{stack: [frame | _rest]}, _namespaces), do: map_size(frame.namespaces)
  defp namespace_size(_state, namespaces), do: map_size(namespaces)

  defp inherited_namespaces(%{stack: [frame | _rest]}, _namespaces, _attrs),
    do: frame.namespaces

  defp inherited_namespaces(state, namespaces, attrs) do
    declared? =
      Enum.any?(
        attrs,
        &(&1.qualified_name == "xmlns" or
            String.starts_with?(&1.qualified_name, "xmlns:"))
      )

    if declared?, do: namespaces, else: Map.put(namespaces, "", state.default_namespace)
  end

  defp in_template?(stack) do
    Enum.any?(stack, &(&1.tag.name == "template" and &1.tag.namespace_uri == @html))
  end

  defp closing(body, offset, %{stack: [frame | rest]} = state) do
    with budget <- charge!(state.budget, Budget.cost(:tag) + Budget.cost(:list_cell), facts: 1),
         {:ok, qualified, after_name, budget} <- name(body, offset + 2, budget),
         true <- qualified == frame.qualified_name,
         finish <- skip_space(body, after_name),
         true <- starts?(body, finish, ">") do
      state =
        if frame.document != nil and frame.document.bounded?,
          do: summarize_scalar(state, offset - frame.content_start),
          else: state

      close = %{
        frame.tag
        | closing?: true,
          span: {offset, finish + 1 - offset},
          source: binary_part(body, offset, finish + 1 - offset),
          attributes: [],
          xml_base: nil
      }

      {close, budget} = closing_marker(close, frame.document, budget)

      {contents, budget, content_count} =
        if frame.capture? do
          scratch =
            binary_bytes(frame.text_size) +
              Budget.cost(
                :list_cell,
                frame.text_count + frame.segment_count
              ) + Budget.cost(:map_entry, state.content_count)

          budget = budget |> charge!(content_bytes(1)) |> reserve!(scratch)
          content = frame.text |> Enum.reverse() |> IO.iodata_to_binary()
          segments = Enum.reverse(frame.segments)

          payload = %{
            content_span: {frame.content_start, offset - frame.content_start},
            content: content,
            content_segments: segments
          }

          payload =
            if frame.document != nil and frame.document.capture?,
              do: Map.put(payload, :content_scalar?, frame.document.scalar?),
              else: payload

          contents = Map.put(state.contents, elem(frame.tag.span, 0), payload)

          budget =
            budget
            |> settle!(scratch, binary_bytes(frame.text_size))
            |> refund!(
              frame.text_size + Budget.cost(:binary, frame.text_count) +
                Budget.cost(:list_cell, frame.text_count)
            )

          {contents, budget, state.content_count + 1}
        else
          {state.contents, budget, state.content_count}
        end

      budget = budget |> release!(frame.scratch) |> refund!(binary_bytes(byte_size(qualified)))

      {:ok, finish + 1,
       %{
         state
         | stack: rest,
           tags: [close | state.tags],
           contents: contents,
           tag_count: state.tag_count + 1,
           content_count: content_count,
           budget: budget
       }}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_xml}
    end
  end

  defp closing(_body, _offset, _state), do: {:error, :invalid_xml}

  defp instruction(body, offset, state, limits) do
    with {:ok, target, after_name, budget} <- name(body, offset + 2, state.budget, @ncname),
         {finish, 2} <- match(body, after_name, "?>") do
      if target == "xml-stylesheet" do
        budget = charge!(budget, Budget.cost(:tag) + Budget.cost(:list_cell), facts: 1)

        case pseudo_attributes(body, after_name, finish, limits.attributes, budget) do
          {:ok, attrs, budget} ->
            state = summarize_attributes(state, attrs)

            {:ok, finish + 2,
             %{
               state
               | budget: budget,
                 instruction_count: state.instruction_count + 1,
                 instruction_bytes:
                   state.instruction_bytes + budget.retained - state.budget.retained,
                 instructions: [
                   %{
                     target: target,
                     attributes: attrs,
                     span: {offset, finish + 2 - offset},
                     in_template?: in_template?(state.stack)
                   }
                   | state.instructions
                 ]
             }}

          {:error, _reason} = error ->
            error
        end
      else
        {:ok, finish + 2, %{state | budget: refund!(budget, binary_bytes(byte_size(target)))}}
      end
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_xml}
    end
  end

  defp declaration(body, offset, _state, _quote, _depth) when offset >= byte_size(body),
    do: {:error, :invalid_xml}

  defp declaration(body, offset, state, quote, depth) do
    byte = :binary.at(body, offset)

    cond do
      quote != nil ->
        declaration(body, offset + 1, state, if(byte == quote, do: nil, else: quote), depth)

      byte in [?', ?"] ->
        declaration(body, offset + 1, state, byte, depth)

      byte == ?[ ->
        declaration(body, offset + 1, state, nil, depth + 1)

      byte == ?] and depth > 0 ->
        declaration(body, offset + 1, state, nil, depth - 1)

      byte == ?> and depth == 0 ->
        {:ok, offset + 1, state}

      true ->
        declaration(body, offset + 1, state, nil, depth)
    end
  end

  defp name(body, offset, budget, pattern \\ @name) do
    finish = name_end(body, offset)
    size = finish - offset
    scratch = 512 + size * 8
    budget = budget |> charge!(binary_bytes(size)) |> reserve!(scratch)
    value = binary_part(body, offset, size)

    if String.valid?(value) and Regex.match?(pattern, value),
      do: {:ok, value, finish, release!(budget, scratch)},
      else: {:error, :invalid_xml}
  end

  defp name_end(body, offset) when offset >= byte_size(body), do: offset

  defp name_end(body, offset) do
    if :binary.at(body, offset) in (@space ++ ~c"/=>?"),
      do: offset,
      else: name_end(body, offset + 1)
  end

  defp attributes(body, offset, limit, budget),
    do: attributes(body, offset, limit, [], MapSet.new(), budget, 0)

  defp attributes(body, offset, limit, attrs, seen, budget, count) do
    start = skip_space(body, offset)

    cond do
      starts?(body, start, "/>") ->
        {attrs, budget} = reverse(attrs, budget)
        {:ok, attrs, start + 2, true, release!(budget, Budget.cost(:map_entry, count))}

      starts?(body, start, ">") ->
        {attrs, budget} = reverse(attrs, budget)
        {:ok, attrs, start + 1, false, release!(budget, Budget.cost(:map_entry, count))}

      start == offset ->
        {:error, :invalid_xml}

      limit == 0 ->
        {:error, {:limit, :xml_attributes}}

      true ->
        with {:ok, attr, next, budget} <- attribute(body, start, offset, budget),
             false <- MapSet.member?(seen, attr.qualified_name),
             budget <- reserve!(budget, Budget.cost(:map_entry)) do
          attributes(
            body,
            next,
            limit - 1,
            [attr | attrs],
            MapSet.put(seen, attr.qualified_name),
            budget,
            count + 1
          )
        else
          {:error, _reason} = error -> error
          _other -> {:error, :invalid_xml}
        end
    end
  end

  defp attribute(body, start, span_start, budget, boundary \\ nil) do
    boundary = boundary || byte_size(body)

    with budget <- charge!(budget, Budget.cost(:attribute) + Budget.cost(:list_cell), facts: 1),
         {:ok, qualified, after_name, budget} <- name(body, start, budget),
         equal <- skip_space(body, after_name),
         true <- starts?(body, equal, "="),
         quote_at <- skip_space(body, equal + 1),
         true <- quote_at < boundary,
         quote when quote in [?', ?"] <- :binary.at(body, quote_at),
         {finish, 1} <-
           :binary.match(body, <<quote>>, scope: {quote_at + 1, boundary - quote_at - 1}),
         value <- binary_part(body, quote_at + 1, finish - quote_at - 1),
         false <- String.contains?(value, "<"),
         {:ok, decoded, segments, budget} <-
           decode_with_spans_result(value, quote_at + 1, :attribute, budget) do
      {:ok,
       %{
         name: qualified,
         qualified_name: qualified,
         value: value,
         decoded: decoded,
         span: {span_start, finish + 1 - span_start},
         value_span: {quote_at + 1, finish - quote_at - 1},
         segments: segments,
         terminal_slash?: false
       }, finish + 1, budget}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_xml}
    end
  end

  defp pseudo_attributes(body, offset, finish, limit, budget),
    do: pseudo_attributes(body, offset, finish, limit, [], budget)

  defp pseudo_attributes(body, offset, finish, limit, attrs, budget) do
    start = skip_space(body, offset)

    cond do
      start == finish ->
        {attrs, budget} = reverse(attrs, budget)
        {:ok, attrs, budget}

      start > finish or start == offset ->
        {:error, :invalid_xml}

      limit == 0 ->
        {:error, {:limit, :xml_attributes}}

      true ->
        with {:ok, attr, next, budget} when next <= finish <-
               attribute(body, start, offset, budget, finish) do
          pseudo_attributes(body, next, finish, limit - 1, [attr | attrs], budget)
        else
          {:error, _reason} = error -> error
          _other -> {:error, :invalid_xml}
        end
    end
  end

  defp bindings(attrs, namespaces) do
    Enum.reduce_while(attrs, {:ok, namespaces}, fn attr, {:ok, namespaces} ->
      case String.split(attr.qualified_name, ":", parts: 2) do
        ["xmlns"] -> put_binding(namespaces, "", attr.decoded)
        ["xmlns", prefix] -> put_binding(namespaces, prefix, attr.decoded)
        _other -> {:cont, {:ok, namespaces}}
      end
    end)
  end

  defp put_binding(namespaces, prefix, uri) do
    if (prefix == "xml" and uri != @xml) or prefix == "xmlns" or uri == @xmlns or
         (uri == @xml and prefix != "xml") or (prefix != "" and uri == "") do
      {:halt, {:error, :invalid_xml}}
    else
      {:cont, {:ok, Map.put(namespaces, prefix, if(uri == "", do: nil, else: uri))}}
    end
  end

  defp expanded_name(qualified, namespaces, element?) do
    case String.split(qualified, ":", parts: 2) do
      [local] ->
        {:ok, if(element?, do: namespaces[""], else: nil), local}

      [prefix, local] ->
        case namespaces[prefix] do
          nil -> {:error, :invalid_xml}
          uri -> {:ok, uri, local}
        end
    end
  end

  defp expand_attributes(attrs, namespaces, budget) do
    scratch =
      (Budget.cost(:attribute) + Budget.cost(:map_entry) + Budget.cost(:list_cell, 2)) *
        length(attrs)

    budget = reserve!(budget, scratch)

    result =
      Enum.reduce_while(attrs, {:ok, [], MapSet.new()}, fn attr, {:ok, acc, seen} ->
        expanded =
          if attr.qualified_name == "xmlns" or String.starts_with?(attr.qualified_name, "xmlns:"),
            do: {:ok, @xmlns, attr.qualified_name |> String.split(":") |> List.last()},
            else: expanded_name(attr.qualified_name, namespaces, false)

        case expanded do
          {:ok, uri, local} ->
            key = {uri, local}

            if MapSet.member?(seen, key) do
              {:halt, {:error, :invalid_xml}}
            else
              attr = Map.merge(attr, %{name: local, namespace_uri: uri})
              {:cont, {:ok, [attr | acc], MapSet.put(seen, key)}}
            end

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)

    case result do
      {:ok, attrs, _seen} -> {:ok, Enum.reverse(attrs), release!(budget, scratch)}
      {:error, _reason} = error -> error
    end
  end

  defp vocabulary(@html), do: :html
  defp vocabulary(@svg), do: :svg
  defp vocabulary(@math), do: :math
  defp vocabulary(_uri), do: :xml

  defp xml_base(attrs) do
    Enum.find_value(attrs, fn attr ->
      if attr.namespace_uri == @xml and attr.name == "base", do: attr.decoded
    end)
  end

  defp merge_base(nil, base, budget), do: {base, budget}

  defp merge_base(value, base, budget) do
    size = byte_size(value) + if(is_binary(base), do: byte_size(base), else: 0)
    # URI.merge builds path segments while both inputs and the final URI overlap.
    scratch = 4_096 + size * 256
    budget = reserve!(budget, scratch)
    {result, copied?} = merge_base(value, base)

    if copied? do
      {result, settle!(budget, scratch, binary_bytes(byte_size(result)))}
    else
      {result, release!(budget, scratch)}
    end
  end

  defp merge_base(value, base) do
    with %URI{} = reference <- URI.parse(value),
         false <- Regex.match?(~r/[\x00-\x20]/, value) do
      if is_binary(base),
        do: {base |> URI.merge(reference) |> URI.to_string(), true},
        else: {value, false}
    else
      _other -> {base, false}
    end
  rescue
    ArgumentError -> {base, false}
  end

  defp decode_parts(
         value,
         offset,
         source_offset,
         decoded_at,
         parts,
         segments,
         context,
         budget,
         work,
         count
       ) do
    case match(value, offset, "&") do
      :nomatch ->
        {parts, segments, decoded_at, budget, work, count} =
          literal(
            value,
            offset,
            byte_size(value),
            source_offset,
            decoded_at,
            parts,
            segments,
            context,
            budget,
            work,
            count
          )

        finish_decoding(parts, segments, decoded_at, budget, work, count)

      {start, 1} ->
        {parts, segments, decoded_at, budget, work, count} =
          literal(
            value,
            offset,
            start,
            source_offset,
            decoded_at,
            parts,
            segments,
            context,
            budget,
            work,
            count
          )

        decode_entity(
          value,
          start,
          source_offset,
          decoded_at,
          parts,
          segments,
          context,
          budget,
          work,
          count
        )
    end
  end

  defp decode_entity(
         value,
         start,
         source_offset,
         decoded_at,
         parts,
         segments,
         context,
         budget,
         work,
         count
       ) do
    case match(value, start + 1, ";") do
      {finish, 1} ->
        size = finish - start - 1
        scratch = 512 + size * 16
        budget = budget |> charge!(segment_bytes(1), facts: 1) |> reserve!(scratch)
        decoded = entity(binary_part(value, start + 1, size))

        if is_binary(decoded) do
          {parts, segments, decoded_at, budget, work, count} =
            decoded_part(
              decoded,
              source_offset + start,
              finish + 1 - start,
              decoded_at,
              parts,
              segments,
              budget,
              work,
              count,
              true
            )

          budget = release!(budget, scratch)

          decode_parts(
            value,
            finish + 1,
            source_offset,
            decoded_at,
            parts,
            segments,
            context,
            budget,
            work,
            count
          )
        else
          {:error, :invalid_xml}
        end

      :nomatch ->
        {:error, :invalid_xml}
    end
  end

  defp decode_literal(value, source_offset, budget) do
    {parts, segments, size, budget, work, count} =
      literal(value, 0, byte_size(value), source_offset, 0, [], [], :text, budget, 0, 0)

    finish_decoding(parts, segments, size, budget, work, count)
  end

  defp literal(
         value,
         start,
         finish,
         source_offset,
         decoded_at,
         parts,
         segments,
         context,
         budget,
         work,
         count
       ) do
    patterns = if context == :attribute, do: ["\r", "\n", "\t"], else: ["\r"]

    case :binary.match(value, patterns, scope: {start, finish - start}) do
      :nomatch ->
        literal_part(
          value,
          start,
          finish - start,
          source_offset,
          decoded_at,
          parts,
          segments,
          budget,
          work,
          count
        )

      {at, 1} ->
        {parts, segments, decoded_at, budget, work, count} =
          literal_part(
            value,
            start,
            at - start,
            source_offset,
            decoded_at,
            parts,
            segments,
            budget,
            work,
            count
          )

        size =
          if :binary.at(value, at) == ?\r and at + 1 < finish and
               :binary.at(value, at + 1) == ?\n,
             do: 2,
             else: 1

        replacement = if context == :attribute, do: " ", else: "\n"

        {parts, segments, decoded_at, budget, work, count} =
          decoded_part(
            replacement,
            source_offset + at,
            size,
            decoded_at,
            parts,
            segments,
            budget,
            work,
            count
          )

        literal(
          value,
          at + size,
          finish,
          source_offset,
          decoded_at,
          parts,
          segments,
          context,
          budget,
          work,
          count
        )
    end
  end

  defp literal_part(
         _value,
         _start,
         0,
         _source_offset,
         decoded_at,
         parts,
         segments,
         budget,
         work,
         count
       ),
       do: {parts, segments, decoded_at, budget, work, count}

  defp literal_part(
         value,
         start,
         size,
         source_offset,
         decoded_at,
         parts,
         segments,
         budget,
         work,
         count
       ) do
    budget = charge!(budget, segment_bytes(1), facts: 1)
    scratch = binary_bytes(size) + Budget.cost(:list_cell)
    budget = reserve!(budget, scratch)
    part = binary_part(value, start, size)

    {[part | parts], [{decoded_at, size, source_offset + start, size} | segments],
     decoded_at + size, budget, work + scratch, count + 1}
  end

  defp decoded_part(
         part,
         source_at,
         source_size,
         decoded_at,
         parts,
         segments,
         budget,
         work,
         count,
         charged? \\ false
       ) do
    budget = if charged?, do: budget, else: charge!(budget, segment_bytes(1), facts: 1)
    scratch = binary_bytes(byte_size(part)) + Budget.cost(:list_cell)
    budget = reserve!(budget, scratch)

    {[part | parts], [{decoded_at, byte_size(part), source_at, source_size} | segments],
     decoded_at + byte_size(part), budget, work + scratch, count + 1}
  end

  defp finish_decoding(parts, segments, size, budget, work, count) do
    scratch = binary_bytes(size) + Budget.cost(:list_cell, count * 2)
    budget = reserve!(budget, scratch)
    text = IO.iodata_to_binary(Enum.reverse(parts))
    segments = Enum.reverse(segments)
    budget = budget |> settle!(scratch, binary_bytes(size)) |> release!(work)
    {:ok, text, segments, budget}
  end

  defp segment_bytes(count), do: Budget.cost(:segment, count) + Budget.cost(:list_cell, count)
  defp binary_bytes(size), do: Budget.cost(:binary) + size

  defp content_bytes(count), do: (Budget.cost(:frame) + Budget.cost(:map_entry)) * count

  defp reverse(list, budget) do
    scratch = Budget.cost(:list_cell, length(list))
    budget = reserve!(budget, scratch)
    list = Enum.reverse(list)
    {list, release!(budget, scratch)}
  end

  defp charge!(budget, bytes, counters \\ []), do: budget!(Budget.charge(budget, bytes, counters))
  defp reserve!(budget, bytes), do: budget!(Budget.reserve(budget, bytes))
  defp release!(budget, bytes), do: budget!(Budget.release(budget, bytes))
  defp settle!(budget, reserved, retained), do: budget!(Budget.settle(budget, reserved, retained))
  defp refund!(budget, bytes), do: budget!(Budget.refund(budget, bytes))
  defp budget!({:ok, budget}), do: budget
  defp budget!({:error, reason}), do: throw({:xml_budget_error, reason})

  defp entity("#x" <> digits), do: codepoint(digits, 16)
  defp entity("#" <> digits), do: codepoint(digits, 10)
  defp entity(name), do: @entities[name]

  defp codepoint(digits, base) do
    valid? =
      if base == 16,
        do: Regex.match?(~r/\A[0-9a-fA-F]+\z/, digits),
        else: Regex.match?(~r/\A[0-9]+\z/, digits)

    significant = String.trim_leading(digits, "0")
    number = if significant == "", do: "0", else: significant
    parsed = if valid? and byte_size(number) <= 7, do: Integer.parse(number, base)

    case parsed do
      {point, ""}
      when point in [9, 10, 13] or point in 0x20..0xD7FF or
             point in 0xE000..0xFFFD or point in 0x10000..0x10FFFF ->
        <<point::utf8>>

      _other ->
        nil
    end
  end

  defp skip_space(body, offset) when offset >= byte_size(body), do: offset

  defp skip_space(body, offset) do
    if :binary.at(body, offset) in @space, do: skip_space(body, offset + 1), else: offset
  end

  defp starts?(body, offset, prefix) do
    size = byte_size(prefix)
    offset + size <= byte_size(body) and binary_part(body, offset, size) == prefix
  end

  defp match(body, offset, pattern),
    do: :binary.match(body, pattern, scope: {offset, byte_size(body) - offset})
end
