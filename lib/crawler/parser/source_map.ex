defmodule Crawler.Parser.SourceMap do
  @moduledoc false

  alias Crawler.ImportMap.JSON
  alias Crawler.Linker
  alias Crawler.MediaType
  alias Crawler.Parser.CssParser
  alias Crawler.Parser.JsParser
  alias Crawler.Snapper.LinkReplacer.Json
  alias Crawler.URL

  @mapping ~r/\A[@#]\s*sourceMappingURL=(\S*?)\s*\z/
  @source_url ~r/\A[@#]\s*sourceURL=(\S*?)\s*\z/
  @scheme ~r/\A[A-Za-z][A-Za-z0-9+.-]*:/

  def javascript(body, opts) when is_binary(body), do: choose(body, opts, :javascript)
  def javascript(_body, _opts), do: nil

  def css(body, opts) when is_binary(body), do: choose(body, opts, :css)
  def css(_body, _opts), do: nil

  def annotation_ref(%{url: url} = note, source) when is_binary(source) do
    {at, len} = placed_span(note, source)

    url
    |> bare_ref(network_url(url), network_fetch(url))
    |> Map.merge(%{at: at, len: len, map_note: note})
  end

  def data_source_refs(%{url: url, base: base}, _opts) when is_binary(base) do
    Enum.map(decoded_entries(url, base), fn entry ->
      bare_ref(entry.raw, entry.url, entry.fetch_kind)
    end)
  end

  def data_source_refs(_note, _opts), do: []

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
      {:ok, decoded} -> map_entries(decoded, file_base(opts))
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
        if source_rewritten?(decoded, file_base(opts)), do: root_clears(decoded), else: []

      :error ->
        []
    end
  end

  def root_clear_spans(_body, _opts), do: []

  def rewrite_css(body, opts) when is_binary(body) do
    case css(body, opts) do
      nil -> body
      note -> apply_css(body, note, opts)
    end
  end

  def rewrite_css(body, _opts), do: body

  def rewrite_text(note, page, _opts, kind, newline?) do
    text = shown_url(note, page)

    if is_integer(note.at) do
      text
    else
      prefix(newline?) <> directive(text, kind)
    end
  end

  defp apply_css(body, note, opts) do
    page = opts[:url] || opts[:referrer_url]
    text = rewrite_text(note, page, opts, :css, String.ends_with?(body, "\n"))

    if is_integer(note.at) do
      splice(body, note.at, note.len, text)
    else
      body <> text
    end
  end

  defp choose(body, opts, kind) do
    notes = body |> comment_spans(kind, opts) |> annotations(body)
    mapping = last_note(notes, :mapping)
    base = chosen_base(notes, opts, kind)

    case header_map(opts) do
      raw when is_binary(raw) -> finish(raw, base, mapping)
      _none -> finish_comment(mapping, base)
    end
  end

  defp finish_comment(nil, _base), do: nil
  defp finish_comment(mapping, base), do: finish(mapping.raw, base, mapping)

  defp finish(raw, base, mapping) do
    case resolve_map(raw, base) do
      nil ->
        nil

      url ->
        {at, len} = note_span(mapping)
        %{url: url, at: at, len: len, base: base}
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

  defp header_map(opts) do
    headers = opts[:headers]

    if external?(opts) and is_list(headers) do
      first_header(headers, "sourcemap") || first_header(headers, "x-sourcemap")
    end
  end

  defp first_header(headers, name) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(value) ->
        if header_name?(key, name) and String.trim(value) != "", do: String.trim(value)

      _header ->
        nil
    end)
  end

  defp header_name?(key, name), do: key |> to_string() |> String.downcase() == name

  defp external?(opts) do
    opts[:inline_source] != true and
      (MediaType.javascript?(opts[:content_type]) or MediaType.css?(opts[:content_type]))
  end

  defp chosen_base(notes, opts, :javascript) do
    if external?(opts) do
      file_base(opts)
    else
      source_url_base(notes, page_base(opts))
    end
  end

  defp chosen_base(_notes, opts, :css) do
    if external?(opts), do: file_base(opts), else: page_base(opts)
  end

  defp source_url_base(notes, base) do
    case last_note(notes, :source) do
      nil -> base
      %{raw: raw} -> resolved_base(raw, base)
    end
  end

  defp resolved_base(raw, base) do
    case URL.resolve(raw, base) do
      {:ok, url} -> url
      :skip -> base
    end
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

  defp resolve_map(raw, base) do
    cond do
      not is_binary(raw) or raw == "" -> nil
      data_url?(raw) -> raw
      true -> http_url(raw, base)
    end
  end

  defp http_url(raw, base) do
    case URL.resolve(raw, base) do
      {:ok, url} -> url
      :skip -> nil
    end
  end

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

  defp decoded_entries(url, base) do
    if data_url?(url) do
      case decode_data(url) do
        {:ok, payload, _meta, _encoding} -> located_entries(payload, base)
        _error -> []
      end
    else
      []
    end
  end

  defp located_entries(payload, base) do
    case JSON.decode_located(payload) do
      {:ok, decoded} -> map_entries(decoded, base)
      :error -> []
    end
  end

  defp map_entries(decoded, base) do
    case pairs(decoded) do
      nil -> []
      object -> object_entries(object, base)
    end
  end

  defp object_entries(object, base) do
    if version3?(object) do
      case fetch_field(object, "sections") do
        :missing -> source_entries(object, base)
        {:ok, sections} when is_list(sections) -> Enum.flat_map(sections, &section(&1, base))
        {:ok, _sections} -> []
      end
    else
      []
    end
  end

  # 3.0 is a float. == would accept it.
  defp version3?(object), do: field(object, "version") === 3

  defp section(item, base) do
    case pairs(item) do
      nil -> []
      object -> section_map(object, base)
    end
  end

  defp section_map(object, base) do
    case field(object, "map") do
      {:object, _pairs} = embedded -> map_entries(embedded, base)
      _other -> section_url(field(object, "url"), base)
    end
  end

  defp section_url({:str, raw, start, length}, base) do
    case URL.resolve(raw, base) do
      {:ok, url} -> [entry(raw, url, :source_map, {start, length})]
      :skip -> []
    end
  end

  defp section_url(_raw, _base), do: []

  defp source_entries(object, base) do
    sources = list_field(object, "sources")
    contents = list_field(object, "sourcesContent")
    prefix = source_prefix(object)

    sources
    |> Enum.with_index()
    |> Enum.flat_map(&source_at(&1, contents, prefix, base))
  end

  defp source_at({{:str, raw, start, length}, index}, contents, prefix, base) do
    if embedded?(contents, index) do
      []
    else
      resolve_source(raw, prefix, base, {start, length})
    end
  end

  defp source_at(_item, _contents, _prefix, _base), do: []

  defp embedded?(contents, index) do
    match?({:str, _value, _start, _length}, Enum.at(contents, index))
  end

  defp resolve_source(raw, prefix, base, span) do
    case URL.resolve(join_source(raw, prefix), base) do
      {:ok, url} -> [entry(raw, url, nil, span)]
      :skip -> []
    end
  end

  defp join_source(raw, prefix) do
    cond do
      Regex.match?(@scheme, raw) -> raw
      String.starts_with?(raw, "/") -> raw
      true -> prefix <> raw
    end
  end

  defp source_rewritten?(decoded, base) do
    Enum.any?(map_entries(decoded, base), &(&1.fetch_kind == nil))
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

  defp source_prefix(object) do
    case string_field(object, "sourceRoot") do
      value when value in [nil, ""] -> ""
      root -> append_slash(root)
    end
  end

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

  defp shown_url(note, page) do
    if data_url?(note.url) do
      rewrite_data(note.url, page, note_base(note))
    else
      offline_path(page, note.url)
    end
  end

  defp note_base(%{base: base}) when is_binary(base), do: base
  defp note_base(_note), do: ""

  defp rewrite_data(url, page, base) do
    case decode_data(url) do
      {:ok, payload, meta, encoding} ->
        rewrite_payload(url, payload, meta, encoding, page, base)

      _error ->
        url
    end
  end

  defp rewrite_payload(url, payload, meta, encoding, page, base) do
    case JSON.decode_located(payload) do
      {:ok, decoded} ->
        spans = payload_spans(decoded, page, base)

        spans =
          if source_rewritten?(decoded, base), do: spans ++ root_clears(decoded), else: spans

        case spans do
          [] ->
            url

          spans ->
            rewritten = payload |> Json.replace_spans(spans) |> encode_payload(encoding)
            meta <> "," <> rewritten
        end

      :error ->
        url
    end
  end

  defp payload_spans(decoded, page, base) do
    for %{json_span: {start, length}, url: target} <- map_entries(decoded, base) do
      {start, length, offline_path(page, target)}
    end
  end

  defp decode_data(url) do
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

  defp offline_path(nil, url), do: url
  defp offline_path(page, url), do: Linker.offline_link(page, url)

  defp prefix(true), do: ""
  defp prefix(false), do: "\n"

  defp directive(text, :javascript), do: "//# sourceMappingURL=" <> text
  defp directive(text, :css), do: "/*# sourceMappingURL=" <> text <> " */"

  defp splice(source, at, len, replacement) do
    head = binary_part(source, 0, at)
    tail = binary_part(source, at + len, byte_size(source) - at - len)
    head <> replacement <> tail
  end

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
