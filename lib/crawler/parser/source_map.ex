defmodule Crawler.Parser.SourceMap do
  @moduledoc """
  Discovers and interprets source-map references and located source entries.

  The former rewrite_css/2 and rewrite_text/5 APIs have been removed. Bind
  occurrences and render through Crawler.Analysis to preserve source contexts.
  """

  alias Crawler.Analysis.Budget
  alias Crawler.HTTP.DocumentHeaders
  alias Crawler.ImportMap.JSON
  alias Crawler.MediaType
  alias Crawler.Parser.CssParser
  alias Crawler.Parser.JsParser
  alias Crawler.URL

  @mapping ~r/\A[@#]\s*sourceMappingURL=(\S*?)\s*\z/
  @source_url ~r/\A[@#]\s*sourceURL=(\S*?)\s*\z/
  @scheme ~r/\A[A-Za-z][A-Za-z0-9+.-]*:/

  def javascript(body, opts) when is_binary(body), do: choose(body, opts, :javascript)
  def javascript(_body, _opts), do: nil

  def javascript(body, opts, {_masked, _strings, comments}) when is_binary(body),
    do:
      from_notes(
        body,
        opts,
        :javascript,
        Map.get_lazy(opts, :source_map_notes, fn -> annotations(comments, body) end)
      )

  def css(body, opts) when is_binary(body), do: choose(body, opts, :css)
  def css(_body, _opts), do: nil

  def css(body, opts, %{comments: comments}) when is_binary(body),
    do:
      from_notes(
        body,
        opts,
        :css,
        Map.get_lazy(opts, :source_map_notes, fn -> annotations(comments, body) end)
      )

  def annotation_ref(%{url: url} = note, source) when is_binary(source) do
    {at, len} = placed_span(note, source)

    url
    |> bare_ref(network_url(url), network_fetch(url))
    |> Map.merge(%{at: at, len: len, map_note: note})
  end

  def data_source_refs(note, opts) do
    case data_source_refs_result(note, opts, Budget.unlimited()) do
      {:ok, refs, _budget} -> refs
      {:error, _reason} -> []
    end
  end

  def link_refs(body, opts, kind) when is_binary(body) and kind in [:javascript, :css] do
    case choose(body, opts, kind) do
      nil ->
        []

      note ->
        sources = data_source_refs(note, opts)
        ref = annotation_ref(note, body)
        if is_binary(ref.url), do: [ref | sources], else: sources
    end
  end

  def link_refs(_body, _opts, _kind), do: []

  def element_refs(body, opts, kind) do
    Enum.map(link_refs(body, opts, kind), &{:ref, &1})
  end

  def entries(body, opts) when is_binary(body) do
    case JSON.decode_located(body) do
      {:ok, decoded} -> entries_located(decoded, opts)
      :error -> []
    end
  end

  def entries(_body, _opts), do: []

  # A consumer prepends sourceRoot to a relative path. Offline paths are already
  # relative to the map, so a saved root must be empty once a source is rewritten.
  # A section map URL is not a source path and must leave sourceRoot in place.
  def root_clear_spans(body, opts) when is_binary(body) do
    case JSON.decode_located(body) do
      {:ok, decoded} ->
        root_clear_spans_located(decoded, opts)

      :error ->
        []
    end
  end

  def root_clear_spans(_body, _opts), do: []

  def entries_located(decoded, opts), do: map_entries(decoded, file_base(opts))

  def root_clear_spans_located(decoded, opts) do
    if source_rewritten?(decoded, file_base(opts)), do: root_clears(decoded), else: []
  end

  defp choose(body, opts, kind) do
    from_comments(body, opts, kind, comment_spans(body, kind, opts))
  end

  defp from_comments(body, opts, kind, comments) do
    from_notes(body, opts, kind, annotations(comments, body))
  end

  defp from_notes(body, opts, kind, notes) do
    {:ok, note, _budget} = from_notes_result(body, opts, kind, notes, Budget.unlimited())
    note
  end

  def javascript_result(body, opts, scan, budget),
    do: note_result(body, opts, :javascript, scan, budget)

  def css_result(body, opts, facts, budget), do: note_result(body, opts, :css, facts, budget)

  defp note_result(body, opts, kind, scan, budget) do
    result =
      case Map.fetch(opts, :source_map_notes) do
        {:ok, notes} -> {:ok, notes, budget}
        :error -> lexical_notes_result(body, scan, budget)
      end

    with {:ok, notes, budget} <- result, do: from_notes_result(body, opts, kind, notes, budget)
  end

  defp from_notes_result(_body, opts, kind, notes, budget) do
    mapping = last_note(notes, :mapping)

    with {:ok, header, budget} <- header_reference_result(opts, budget) do
      raw = header || if(mapping, do: mapping.raw)
      from_reference_result(raw, mapping, notes, opts, kind, budget)
    end
  end

  defp from_reference_result(raw, mapping, notes, opts, kind, budget) do
    capacity = if is_binary(raw), do: Budget.count(budget, :occurrences), else: {:ok, budget}

    with {:ok, _hypothetical} <- capacity,
         {:ok, base, budget} <- chosen_base_result(notes, opts, kind, budget) do
      if is_binary(raw) do
        result =
          if data_url?(raw), do: {:ok, raw, budget}, else: URL.resolve_result(raw, base, budget)

        case result do
          {:ok, url, budget} ->
            with {:ok, budget} <- Budget.charge(budget, Budget.cost(:token)) do
              {at, len} = note_span(mapping)
              {:ok, %{url: url, at: at, len: len, base: base}, budget}
            end

          {:skip, budget} ->
            {:ok, nil, budget}

          error ->
            error
        end
      else
        {:ok, nil, budget}
      end
    end
  end

  defp chosen_base_result(notes, opts, kind, budget) do
    base = if external?(opts), do: file_base(opts), else: page_base(opts)
    source = if kind == :javascript and not external?(opts), do: last_note(notes, :source)

    case source do
      nil ->
        {:ok, base, budget}

      %{raw: raw} ->
        case URL.resolve_result(raw, base, budget) do
          {:ok, url, budget} -> {:ok, url, budget}
          {:skip, budget} -> {:ok, base, budget}
          error -> error
        end
    end
  end

  defp note_span(nil), do: {nil, 0}
  defp note_span(%{at: at, len: len}), do: {at, len}

  defp placed_span(%{at: at, len: len}, _source) when is_integer(at), do: {at, len}
  defp placed_span(_note, source), do: {byte_size(source), 0}

  defp comment_spans(body, :javascript, opts) do
    {_masked, _strings, comments} = JsParser.Scanner.scan(body, script_goal(opts))
    comments
  end

  defp comment_spans(body, :css, _opts), do: CssParser.Scanner.comment_spans(body)

  defp script_goal(%{javascript_goal: :script}), do: :script
  defp script_goal(_opts), do: :module

  defp annotations(spans, source) do
    Enum.flat_map(spans, &annotation(source, &1))
  end

  defp annotation(source, {at, len}) do
    body = comment_body(source, at, len)

    case classify(body) do
      {kind, {start, capture_len}} ->
        [
          %{
            kind: kind,
            at: at + 2 + start,
            len: capture_len,
            raw: binary_part(body, start, capture_len)
          }
        ]

      _other ->
        []
    end
  end

  defp comment_body(source, at, len) when len >= 2 do
    text = binary_part(source, at, len)

    cond do
      String.starts_with?(text, "//") ->
        binary_part(text, 2, len - 2)

      String.starts_with?(text, "/*") ->
        text |> binary_part(2, len - 2) |> String.replace_suffix("*/", "")

      true ->
        ""
    end
  end

  defp comment_body(_source, _at, _len), do: ""

  defp classify(body) do
    cond do
      span = capture(@mapping, body) -> {:mapping, span}
      span = capture(@source_url, body) -> {:source, span}
      true -> nil
    end
  end

  defp capture(regex, body) do
    case Regex.run(regex, body, return: :index) do
      [_whole, {start, len}] when len > 0 -> {start, len}
      _other -> nil
    end
  end

  defp last_note(notes, kind) do
    notes
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.sort_by(& &1.at)
    |> List.last()
  end

  def header_reference_result(opts, budget) do
    headers = opts[:headers]

    if external?(opts) and is_list(headers) do
      with {:ok, value, budget} <- first_header_result(headers, "sourcemap", budget) do
        if value,
          do: {:ok, value, budget},
          else: first_header_result(headers, "x-sourcemap", budget)
      end
    else
      {:ok, nil, budget}
    end
  end

  defp first_header_result(headers, name, budget) do
    Enum.reduce_while(headers, {:ok, nil, budget}, fn
      {key, value}, {:ok, nil, budget} when is_binary(value) ->
        with {:ok, matches?, budget} <- DocumentHeaders.name_matches_result(key, name, budget),
             {:ok, value, budget} <-
               if(matches?, do: header_value_result(value, budget), else: {:ok, nil, budget}) do
          if value, do: {:halt, {:ok, value, budget}}, else: {:cont, {:ok, nil, budget}}
        else
          error -> {:halt, error}
        end

      _header, result ->
        {:cont, result}
    end)
  end

  defp header_value_result(value, budget) do
    hold = 2 * byte_size(value) + Budget.cost(:binary, 2)

    with {:ok, budget} <- Budget.reserve(budget, hold) do
      value = String.trim(value)

      if value == "" do
        with {:ok, budget} <- Budget.release(budget, hold), do: {:ok, nil, budget}
      else
        value = :binary.copy(value)

        with {:ok, budget} <-
               Budget.settle(budget, hold, byte_size(value) + Budget.cost(:binary)),
             do: {:ok, value, budget}
      end
    end
  end

  defp external?(opts) do
    opts[:inline_source] != true and
      (MediaType.javascript?(opts[:content_type]) or MediaType.css?(opts[:content_type]))
  end

  defp file_base(opts) do
    cond do
      present?(opts[:referrer_url]) -> opts[:referrer_url]
      present?(opts[:url]) -> opts[:url]
      true -> ""
    end
  end

  defp page_base(opts) do
    cond do
      present?(opts[:referrer_url]) -> opts[:referrer_url]
      present?(opts[:document_base]) -> opts[:document_base]
      present?(opts[:url]) -> opts[:url]
      true -> ""
    end
  end

  defp present?(value) when is_binary(value) and value != "", do: true
  defp present?(_value), do: false

  defp network_url(url) do
    if data_url?(url), do: nil, else: url
  end

  defp network_fetch(url) do
    if data_url?(url), do: nil, else: :source_map
  end

  defp data_url?(url) when is_binary(url) do
    url = String.trim_leading(url)
    size = byte_size("data:")

    byte_size(url) >= size and
      String.downcase(binary_part(url, 0, size), :ascii) == "data:"
  end

  defp data_url?(_url), do: false

  defp map_entries(decoded, base) do
    {:ok, entries, _budget} =
      reduce_located(decoded, %{url: base}, Budget.unlimited(), [], fn entry, acc, budget ->
        {:ok, [entry | acc], budget}
      end)

    Enum.reverse(entries)
  end

  def reduce_located(decoded, opts, budget, acc, emit) do
    reduce_map(decoded, file_base(opts), budget, acc, emit)
  end

  defp reduce_map(decoded, base, budget, acc, emit) do
    reduce_maps(
      decoded,
      budget,
      acc,
      fn object, _parents, acc, budget -> reduce_sources(object, base, budget, acc, emit) end,
      fn object, acc, budget ->
        resolve_entry(field(object, "url"), "", base, :source_map, budget, acc, emit)
      end,
      nil
    )
  end

  defp reduce_maps(decoded, budget, acc, leaf, external, parents) do
    case pairs(decoded) do
      nil ->
        {:ok, acc, budget}

      object ->
        if version3?(object) do
          reduce_sections(object, budget, acc, leaf, external, parents)
        else
          {:ok, acc, budget}
        end
    end
  end

  defp reduce_sections(object, budget, acc, leaf, external, parents) do
    case fetch_field(object, "sections") do
      :missing ->
        leaf.(object, parents, acc, budget)

      {:ok, sections} when is_list(sections) ->
        with {:ok, parents, budget} <- root_parent(object, parents, budget) do
          each(sections, budget, acc, fn section, acc, budget ->
            reduce_section(pairs(section), budget, acc, leaf, external, parents)
          end)
        end

      {:ok, _sections} ->
        {:ok, acc, budget}
    end
  end

  defp reduce_section(nil, budget, acc, _leaf, _external, _parents), do: {:ok, acc, budget}

  defp reduce_section(object, budget, acc, leaf, external, parents) do
    with {:ok, budget} <- Budget.reserve(budget, Budget.cost(:frame)) do
      result =
        case field(object, "map") do
          {:object, _pairs} = embedded ->
            reduce_maps(embedded, budget, acc, leaf, external, parents)

          _other ->
            external.(object, acc, budget)
        end

      with {:ok, acc, budget} <- result,
           {:ok, budget} <- Budget.release(budget, Budget.cost(:frame)),
           do: {:ok, acc, budget}
    end
  end

  defp reduce_sources(object, base, budget, acc, emit) do
    root = string_field(object, "sourceRoot") || ""
    scratch = byte_size(root) + 1 + Budget.cost(:binary)

    with {:ok, budget} <- Budget.reserve(budget, scratch) do
      prefix = if root == "", do: "", else: append_slash(root)
      contents = list_field(object, "sourcesContent")

      result =
        list_field(object, "sources")
        |> Enum.reduce_while({:ok, acc, budget, 0}, fn value, {:ok, acc, budget, index} ->
          if match?({:str, _value, _at, _len}, Enum.at(contents, index)) do
            {:cont, {:ok, acc, budget, index + 1}}
          else
            source_result(resolve_entry(value, prefix, base, nil, budget, acc, emit), index)
          end
        end)

      with {:ok, acc, budget, _index} <- result,
           {:ok, budget} <- Budget.release(budget, scratch),
           do: {:ok, acc, budget}
    end
  end

  defp source_result({:ok, acc, budget}, index), do: {:cont, {:ok, acc, budget, index + 1}}
  defp source_result(error, _index), do: {:halt, error}

  defp resolve_entry({:str, raw, at, len}, prefix, base, kind, budget, acc, emit) do
    scratch = byte_size(prefix) + byte_size(raw) + Budget.cost(:binary)

    with {:ok, _hypothetical} <- Budget.count(budget, :occurrences),
         {:ok, budget} <- Budget.reserve(budget, scratch) do
      joined =
        if Regex.match?(@scheme, raw) or String.starts_with?(raw, "/"),
          do: raw,
          else: prefix <> raw

      case URL.resolve_result(joined, base, budget) do
        {:ok, url, budget} ->
          with {:ok, budget} <- Budget.release(budget, scratch),
               {:ok, budget} <- Budget.charge(budget, Budget.cost(:token)),
               do: emit.(entry(raw, url, kind, {at, len}), acc, budget)

        {:skip, budget} ->
          with {:ok, budget} <- Budget.release(budget, scratch), do: {:ok, acc, budget}

        error ->
          error
      end
    end
  end

  defp resolve_entry(_value, _prefix, _base, _kind, budget, acc, _emit), do: {:ok, acc, budget}

  defp each(items, budget, acc, fun) do
    Enum.reduce_while(items, {:ok, acc, budget}, fn item, {:ok, acc, budget} ->
      case fun.(item, acc, budget) do
        {:ok, acc, budget} -> {:cont, {:ok, acc, budget}}
        error -> {:halt, error}
      end
    end)
  end

  defp version3?(object), do: field(object, "version") === 3

  defp source_rewritten?(decoded, base),
    do: Enum.any?(map_entries(decoded, base), &(&1.fetch_kind == nil))

  def root_owners_result(decoded, budget) do
    reduce_maps(
      decoded,
      budget,
      [],
      &root_owner/4,
      fn _object, acc, budget -> {:ok, acc, budget} end,
      []
    )
  end

  defp root_parent(_object, nil, budget), do: {:ok, nil, budget}

  defp root_parent(object, parents, budget) do
    case field(object, "sourceRoot") do
      {:str, value, at, len} when value != "" ->
        with {:ok, budget} <-
               Budget.charge(budget, Budget.cost(:context) + Budget.cost(:list_cell)),
             do: {:ok, [{at, len} | parents], budget}

      _value ->
        {:ok, parents, budget}
    end
  end

  defp root_owner(object, parents, acc, budget) do
    root = field(object, "sourceRoot")
    root? = match?({:str, value, _at, _len} when value != "", root)

    if root? or parents != [] do
      with {:ok, budget} <- Budget.charge(budget, Budget.cost(:context) + Budget.cost(:list_cell)) do
        span =
          case root do
            {:str, value, at, len} when value != "" -> {at, len}
            _value -> nil
          end

        {:ok, [{span, parents, list_field(object, "sources")} | acc], budget}
      end
    else
      {:ok, acc, budget}
    end
  end

  defp root_clears({:object, pairs}) do
    Enum.flat_map(pairs, fn
      {"sourceRoot", {:str, value, start, length}} when value != "" ->
        [{start, length, ""}]

      {_key, value} ->
        root_clears(value)
    end)
  end

  defp root_clears(list) when is_list(list), do: Enum.flat_map(list, &root_clears/1)
  defp root_clears(_decoded), do: []

  defp append_slash(root) do
    if String.ends_with?(root, "/"), do: root, else: root <> "/"
  end

  defp entry(raw, url, fetch_kind, span) do
    %{raw: raw, url: url, fetch_kind: fetch_kind, json_span: span}
  end

  defp bare_ref(spec, url, fetch_kind) do
    %{
      spec: spec,
      url: url,
      goal: nil,
      html_tag: "link",
      reference_tag: "link",
      import_map: nil,
      document_base: nil,
      worker_base: nil,
      fetch_kind: fetch_kind
    }
  end

  def lexical_notes_result(source, {_masked, _strings, comments}, budget),
    do: notes_result(comments, source, budget)

  def lexical_notes_result(source, %{comments: comments}, budget),
    do: notes_result(comments, source, budget)

  defp notes_result(comments, source, budget) do
    with {:ok, notes, budget} <-
           each(comments, budget, [], fn {_at, len} = span, acc, budget ->
             scratch = len + Budget.cost(:token)

             with {:ok, budget} <- Budget.reserve(budget, scratch) do
               case annotation(source, span) do
                 [] ->
                   with {:ok, budget} <- Budget.release(budget, scratch), do: {:ok, acc, budget}

                 [note] ->
                   with {:ok, budget} <- Budget.charge(budget, Budget.cost(:token), facts: 1),
                        {:ok, budget} <- Budget.release(budget, scratch),
                        do: {:ok, [note | acc], budget}
               end
             end
           end),
         do: {:ok, Enum.reverse(notes), budget}
  end

  def annotation_ref_result(note, source, budget) do
    with {:ok, budget} <- Budget.charge(budget, Budget.cost(:token)),
         do: {:ok, annotation_ref(note, source), budget}
  end

  def data_source_refs_result(note, opts, budget) do
    with {:ok, refs, budget} <-
           reduce_data_source_refs(note, opts, budget, [], fn ref, acc, budget ->
             {:ok, [ref | acc], budget}
           end),
         do: {:ok, Enum.reverse(refs), budget}
  end

  def reduce_data_source_refs(%{url: url, base: base}, opts, budget, acc, emit)
      when is_binary(base) do
    if Map.has_key?(Map.get(opts, :source_map_regions, %{}), url) do
      {:ok, acc, budget}
    else
      capacity = if data_url?(url), do: Budget.count(budget, :occurrences), else: {:ok, budget}

      with {:ok, _hypothetical} <- capacity do
        case data_source_refs_attempt(url, base, budget, acc, emit) do
          {:error, :invalid_json, latest} ->
            with {:ok, latest} <- Budget.refund(latest, latest.retained - budget.retained),
                 do: {:ok, acc, latest}

          {:error, {:limit, key}, _latest}
          when key in [
                 :max_input_bytes,
                 :max_depth,
                 :max_tokens,
                 :max_string_bytes,
                 :max_number_bytes
               ] ->
            {:error, {:limit, {:json, key}}}

          {:error, reason, _latest} ->
            {:error, reason}

          result ->
            result
        end
      end
    end
  end

  def reduce_data_source_refs(_note, _opts, budget, acc, _emit), do: {:ok, acc, budget}

  defp data_source_refs_attempt(url, base, budget, acc, emit) do
    case decode_data_result(url, budget) do
      {:ok, payload, _meta, _encoding, budget} ->
        reduce_data_payload(payload, base, budget, acc, emit)

      {:skip, budget} ->
        {:ok, acc, budget}

      error ->
        error
    end
  end

  defp reduce_data_payload(payload, base, budget, acc, emit) do
    case JSON.decode_located_result(payload, budget) do
      {:ok, ast, budget} ->
        reduce_located(ast, %{url: base}, budget, acc, fn entry, acc, budget ->
          with {:ok, budget} <- Budget.charge(budget, Budget.cost(:token)),
               do: emit.(bare_ref(entry.raw, entry.url, entry.fetch_kind), acc, budget)
        end)

      error ->
        error
    end
  end

  def decode_data_result(url, budget) do
    if data_url?(url) do
      hold = 8 * byte_size(url) + Budget.cost(:binary, 4)

      with {:ok, budget} <- Budget.reserve(budget, hold) do
        case decode_data(url) do
          {:ok, payload, meta, encoding} ->
            with {:ok, budget} <-
                   Budget.settle(budget, hold, byte_size(payload) + Budget.cost(:binary)),
                 do: {:ok, payload, meta, encoding, budget}

          _other ->
            with {:ok, budget} <- Budget.release(budget, hold), do: {:skip, budget}
        end
      end
    else
      {:skip, budget}
    end
  end

  def lexical_notes(source, scan) do
    {:ok, notes, _budget} = lexical_notes_result(source, scan, Budget.unlimited())
    notes
  end

  def header_reference(opts) do
    case header_reference_result(opts, Budget.unlimited()) do
      {:ok, value, _budget} -> value
      {:error, _reason} -> nil
    end
  end

  def encode_data(payload, meta, encoding), do: meta <> "," <> encode_payload(payload, encoding)

  def decode_data(url) do
    case String.split(url, ",", parts: 2) do
      [meta, payload] ->
        if data_url?(meta), do: decode_payload(meta, payload)

      _split ->
        nil
    end
  end

  defp decode_payload(meta, payload) do
    if base64?(meta) do
      case Base.decode64(payload, ignore: :whitespace) do
        {:ok, decoded} -> {:ok, decoded, meta, :base64}
        :error -> nil
      end
    else
      decode_percent(payload, meta)
    end
  end

  defp decode_percent(payload, meta) do
    {:ok, URI.decode(payload), meta, :percent}
  rescue
    ArgumentError -> nil
  end

  defp base64?(meta) do
    meta |> String.downcase(:ascii) |> String.contains?(";base64")
  end

  defp encode_payload(payload, :base64), do: Base.encode64(payload)

  # URI.encode/1 leaves "#", which ends a data URL before the payload does.
  defp encode_payload(payload, :percent), do: URI.encode(payload, &URI.char_unreserved?/1)

  defp pairs({:object, pairs}) when is_list(pairs), do: pairs
  defp pairs(_decoded), do: nil

  defp field(pairs, name) do
    Enum.find_value(pairs, fn
      {^name, value} -> value
      _pair -> nil
    end)
  end

  defp fetch_field(pairs, name) do
    Enum.find_value(pairs, :missing, fn
      {^name, value} -> {:ok, value}
      _pair -> nil
    end)
  end

  defp string_field(pairs, name) do
    case field(pairs, name) do
      {:str, value, _start, _length} -> value
      _other -> nil
    end
  end

  defp list_field(pairs, name) do
    case field(pairs, name) do
      list when is_list(list) -> list
      _other -> []
    end
  end
end
