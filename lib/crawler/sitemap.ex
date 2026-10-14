defmodule Crawler.Sitemap do
  @moduledoc false

  alias Crawler.Charset.Encoding
  alias Crawler.Fetcher.Requester
  alias Crawler.Fetcher.Retrier
  alias Crawler.HTMLReferences
  alias Crawler.HTTP
  alias Crawler.Robots
  alias Crawler.Site
  alias Crawler.Store
  alias Crawler.URL

  @text_elements ["loc", "link", "thumbnail_loc", "content_loc"]
  @image_elements ["thumbnail_loc", "content_loc"]

  def follow(opts, origin, rules) when is_map(rules) do
    state = %{
      origin: origin,
      rules: rules,
      files: MapSet.new(),
      pages: seed_page(opts),
      reserved: 0,
      start_ops: Store.ops_count(opts[:scope])
    }

    rules
    |> Map.get(:sitemaps, [])
    |> Enum.reduce(state, fn url, state -> fetch_document(opts, origin <> "/", url, state) end)

    :ok
  end

  def follow(_opts, _origin, _rules), do: :ok

  @doc false
  def locations(body) when is_binary(body) do
    {urls, children} = entries(body)
    {page_urls(urls), children}
  end

  # `:ops` counts finished pages. Another worker can finish a URL this walk has
  # already reserved, so adding the live count to that reservation counts the
  # page twice and stops the index early. The in-flight seed is not in `:ops`
  # yet; counting it here would leave no room for a small `max_pages`.
  defp fetch_document(opts, base, url, state) do
    if room?(opts, state), do: fetch_unseen(opts, base, url, state), else: state
  end

  defp room?(opts, %{start_ops: start_ops, reserved: reserved}) do
    case opts[:max_pages] do
      max when is_integer(max) ->
        start_ops + reserved < max and Store.ops_count(opts[:scope]) < max

      _ ->
        true
    end
  end

  defp fetch_unseen(opts, base, url, state) do
    case URL.resolve(url, base) do
      {:ok, absolute} -> remember(opts, absolute, state)
      :skip -> state
    end
  end

  defp remember(opts, absolute, state) do
    key = URL.normalize(absolute)

    if MapSet.member?(state.files, key) do
      state
    else
      fetch_new(opts, absolute, %{state | files: MapSet.put(state.files, key)})
    end
  end

  defp fetch_new(opts, url, state) do
    case fetch_text(opts, url) do
      {:ok, body, final} ->
        {urls, children} = entries(body)
        state = enqueue_urls(opts, urls, final, state)

        Enum.reduce(children, state, fn child, state ->
          fetch_document(opts, final, child, state)
        end)

      :skip ->
        state
    end
  end

  defp fetch_text(opts, url) do
    retrier = opts[:retrier] || Retrier

    case retrier.perform(fn -> attempt(sitemap_opts(opts, url), url) end, opts) do
      {:ok, _text, _final} = ok -> ok
      _other -> :skip
    end
  end

  defp sitemap_opts(opts, url) do
    opts
    |> Map.put(:url, url)
    |> Map.put(:sitemap_fetch, true)
    |> Map.delete(:reference_tag)
  end

  # The retrier retries `:error` and `{:error, _}`. A permanent failure has to
  # be `{:warn, _}`, or a 404 and an oversized body are fetched again.
  defp attempt(opts, url) do
    case Requester.make(opts) do
      {:ok, %{status: status, body: body} = response}
      when status in 200..299 and is_binary(body) ->
        accept_body(body, response, url, opts)

      {:ok, %{status: status}} when status in [408, 429] or status >= 500 ->
        {:error, status}

      {:ok, %{status: status}} ->
        {:warn, status}

      {:error, %HTTP.BodyTooLarge{}} ->
        {:warn, :body_too_large}

      {:error, %HTTP.UnsupportedEncoding{}} ->
        {:warn, :unsupported_encoding}

      {:error, %HTTP.RedirectRejected{}} ->
        {:warn, :redirect_rejected}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, reason}

      {:error, %Req.TooManyRedirectsError{} = exception} ->
        {:error, Exception.message(exception)}

      {:error, %{__exception__: true} = exception} ->
        {:error, exception.__struct__}
    end
  end

  defp accept_body(body, response, url, opts) do
    case inflate(body, max_body(opts)) do
      {:ok, text} -> {:ok, text, final_url(response, url)}
      :error -> {:warn, :inflate}
    end
  end

  defp max_body(opts) do
    case opts[:max_body] do
      max when is_integer(max) and max >= 0 -> max
      _ -> 10_485_760
    end
  end

  defp inflate(<<31, 139, _rest::binary>> = body, max) do
    zlib = :zlib.open()

    try do
      :zlib.inflateInit(zlib, 16 + 15)

      case inflate_limited(zlib, body, max, 0, []) do
        {:ok, chunks} ->
          if trailer_ok?(zlib), do: {:ok, IO.iodata_to_binary(chunks)}, else: :error

        :error ->
          :error
      end
    rescue
      ErlangError -> :error
    after
      close_zlib(zlib)
    end
  end

  defp inflate(body, _max), do: {:ok, body}

  # `:finished` means this input was consumed. An empty continue must stop so a
  # truncated member cannot loop, and the output stays inside `max_body`.
  defp inflate_limited(zlib, data, max, size, chunks) do
    case safe_inflate(zlib, data) do
      {:finished, output} ->
        case take_output(output, max, size, chunks) do
          {:ok, _size, chunks} -> {:ok, chunks}
          :error -> :error
        end

      {:continue, output} ->
        case take_output(output, max, size, chunks) do
          {:ok, size, chunks} ->
            if IO.iodata_length(output) > 0 or data != <<>> do
              inflate_limited(zlib, <<>>, max, size, chunks)
            else
              :error
            end

          :error ->
            :error
        end

      :error ->
        :error
    end
  end

  defp take_output(output, max, size, chunks) do
    size = size + IO.iodata_length(output)

    if size > max, do: :error, else: {:ok, size, [chunks, output]}
  end

  defp safe_inflate(zlib, data) do
    try do
      case :zlib.safeInflate(zlib, data) do
        {status, output} when status in [:finished, :continue] -> {status, output}
        _other -> :error
      end
    rescue
      ErlangError -> :error
    end
  end

  defp trailer_ok?(zlib) do
    try do
      :zlib.inflateEnd(zlib)
      true
    rescue
      ErlangError -> false
    end
  end

  defp close_zlib(zlib) do
    try do
      :zlib.close(zlib)
    rescue
      ErlangError -> :ok
    end
  end

  defp final_url(response, fallback) do
    case Req.Response.get_private(response, :crawler_url) do
      url when is_binary(url) and url != "" -> url
      _ -> fallback
    end
  end

  defp enqueue_urls(opts, urls, base, state) do
    Enum.reduce(urls, state, &enqueue_url(opts, &1, base, &2))
  end

  defp enqueue_url(opts, {:page, loc}, base, state) do
    case URL.resolve(loc, base) do
      {:ok, url} -> reserve_page(opts, url, state)
      :skip -> state
    end
  end

  defp enqueue_url(opts, {:image, loc}, base, state) do
    if HTMLReferences.enabled?(opts, "images") do
      case URL.resolve(loc, base) do
        {:ok, url} -> reserve_image(opts, url, state)
        :skip -> state
      end
    else
      state
    end
  end

  defp reserve_page(opts, url, state) do
    if page_in_scope?(opts, url), do: reserve_fetch(opts, url, &page_opts/1, state), else: state
  end

  # A missing reference tag is navigation, so another host is rejected.
  # The same-site check would also drop a CDN file. Media stays an image.
  defp reserve_image(opts, url, state) do
    if http_url?(url), do: reserve_fetch(opts, url, &image_opts/1, state), else: state
  end

  # A robots rejection or a repeated URL does not finish a new page, so it must
  # not take a budget slot. Rules for this origin are already stored.
  # `permitted?/1` on another host would fetch that host and walk its sitemaps.
  defp reserve_fetch(opts, url, opts_fun, state) do
    key = URL.canonical(url)

    cond do
      MapSet.member?(state.pages, key) -> state
      stored?(opts, url) -> remember_page(state, key)
      not fetch_allowed?(opts, state, url) -> remember_page(state, key)
      true -> admit(opts, url, opts_fun, remember_page(state, key))
    end
  end

  defp admit(opts, url, opts_fun, state) do
    if budget_open?(opts) do
      Crawler.crawl(url, opts_fun.(opts))
      %{state | reserved: state.reserved + 1}
    else
      state
    end
  end

  defp budget_open?(%{max_pages: max, scope: scope}) when is_integer(max) do
    Store.ops_count(scope) < max
  end

  defp budget_open?(_opts), do: true

  defp remember_page(state, key), do: %{state | pages: MapSet.put(state.pages, key)}

  defp stored?(opts, url), do: Store.find({url, opts[:scope]}) != nil

  defp fetch_allowed?(%{respect_robots: false}, _state, _url), do: true

  defp fetch_allowed?(opts, %{origin: origin, rules: rules}, url) do
    Site.origin(url) != origin or Robots.allowed?(rules, url, opts[:user_agent])
  end

  defp seed_page(%{url: url}) when is_binary(url), do: MapSet.new([URL.canonical(url)])
  defp seed_page(_opts), do: MapSet.new()

  defp page_in_scope?(opts, url) do
    case opts[:site] do
      site when is_binary(site) -> Site.same_site?(site, url)
      _ -> http_url?(url)
    end
  end

  defp http_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp page_opts(opts) do
    opts
    |> shared_opts()
    |> Map.put(:html_tag, "a")
  end

  defp image_opts(opts) do
    opts
    |> shared_opts()
    |> Map.put(:html_tag, "img")
    |> Map.put(:reference_tag, "img")
  end

  defp shared_opts(opts) do
    opts
    |> Map.drop([
      :alias_candidate,
      :alias_created,
      :alias_url,
      :before_publish,
      :content_type,
      :headers,
      :reference_tag,
      :referrer_url,
      :robots_fetch,
      :robots_nofollow,
      :sitemap_fetch,
      :url
    ])
    |> Map.put(:depth, 1)
  end

  defp entries(body) do
    case decode_document(body) do
      text when is_binary(text) -> classify_document(text)
      :error -> {[], []}
    end
  end

  defp decode_document(body) do
    case Encoding.bom(body) do
      {:utf8, rest} -> Encoding.to_utf8(rest)
      {:utf16, endian, rest} -> Encoding.to_utf16(rest, endian)
      :none -> if(String.valid?(body), do: body, else: :error)
    end
  end

  # A trimmed body that starts with `<` is XML. Anything else is one absolute
  # URL per line. A relative text line is not resolved against the sitemap.
  defp classify_document(text) do
    if xml?(text), do: xml_entries(text), else: text_pages(text)
  end

  defp xml?(text) do
    text |> String.trim_leading() |> String.starts_with?("<")
  end

  defp text_pages(text) do
    pages =
      text
      |> String.split(~r/\r\n|\n|\r/)
      |> Enum.flat_map(&text_page/1)

    {pages, []}
  end

  defp text_page(line) do
    line = String.trim(line)
    if absolute_http?(line), do: [{:page, line}], else: []
  end

  defp absolute_http?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        String.downcase(scheme, :ascii) in ["http", "https"]

      _ ->
        false
    end
  end

  defp xml_entries(text) do
    text
    |> scan([], [])
    |> split_entries()
  end

  defp page_urls(urls) do
    for {:page, url} <- urls, do: url
  end

  defp scan(<<"<!--", rest::binary>>, stack, acc), do: scan(skip_until(rest, "-->"), stack, acc)

  defp scan(<<"<![CDATA[", rest::binary>>, stack, acc) do
    scan(skip_until(rest, "]]>"), stack, acc)
  end

  defp scan(<<"<?", rest::binary>>, stack, acc), do: scan(skip_until(rest, "?>"), stack, acc)

  defp scan(<<"</", rest::binary>>, stack, acc),
    do: scan(skip_until(rest, ">"), tl_stack(stack), acc)

  defp scan(<<"<!", rest::binary>>, stack, acc), do: scan(skip_until(rest, ">"), stack, acc)

  defp scan(<<"<", rest::binary>>, stack, acc) do
    {local, attrs, rest, self_closing?} = read_element(rest)
    parent = parent_name(stack)

    if text_element?(local) and not self_closing? do
      {text, rest} = read_text(rest)
      rest = drop_end_tag(rest)
      scan(rest, stack, add_entry(acc, local, parent, attrs, text))
    else
      acc = if self_closing?, do: add_entry(acc, local, parent, attrs, ""), else: acc
      scan(rest, push_stack(stack, local, self_closing?), acc)
    end
  end

  defp scan(<<_byte, rest::binary>>, stack, acc), do: scan(rest, stack, acc)
  defp scan(<<>>, _stack, acc), do: acc

  defp read_element(rest) do
    {name, rest} = take_name(rest)
    {attrs, rest, self_closing?} = read_attrs(rest, [])
    {local_name(name), attrs, rest, self_closing?}
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

  defp read_attrs(rest, attrs), do: read_attrs(skip_space(rest), attrs, :tag)

  defp read_attrs(<<"/>", rest::binary>>, attrs, :tag), do: {Map.new(attrs), rest, true}
  defp read_attrs(<<">", rest::binary>>, attrs, :tag), do: {Map.new(attrs), rest, false}
  defp read_attrs(<<>>, attrs, :tag), do: {Map.new(attrs), <<>>, false}

  defp read_attrs(rest, attrs, :tag) do
    {name, rest} = take_name(rest)
    read_named_attr(name, rest, attrs)
  end

  defp read_named_attr("", <<_byte, rest::binary>>, attrs), do: read_attrs(rest, attrs)

  defp read_named_attr(name, rest, attrs) do
    {value, rest} = read_value(rest)
    read_attrs(rest, [{String.downcase(name, :ascii), value} | attrs])
  end

  defp read_value(rest) do
    case skip_space(rest) do
      <<"=", rest::binary>> ->
        {raw, rest} = quoted(skip_space(rest))
        {decode_entities(raw), rest}

      rest ->
        {"", rest}
    end
  end

  defp quoted(<<"\"", rest::binary>>), do: split_marker(rest, "\"")
  defp quoted(<<"'", rest::binary>>), do: split_marker(rest, "'")
  defp quoted(rest), do: unquoted(rest, [])

  defp unquoted(<<byte, rest::binary>>, acc) when byte not in [?\s, ?\t, ?\n, ?\r, ?>, ?/] do
    unquoted(rest, [acc, byte])
  end

  defp unquoted(rest, acc), do: {IO.iodata_to_binary(acc), rest}

  defp skip_space(<<byte, rest::binary>>) when byte in [?\s, ?\t, ?\n, ?\r], do: skip_space(rest)
  defp skip_space(rest), do: rest

  defp local_name(name) do
    name
    |> String.split(":", parts: 2)
    |> List.last()
    |> String.downcase(:ascii)
  end

  defp parent_name([parent | _rest]), do: parent
  defp parent_name([]), do: ""

  defp text_element?(local), do: local in @text_elements

  defp push_stack(stack, "", _self_closing?), do: stack
  defp push_stack(stack, _local, true), do: stack
  defp push_stack(stack, local, false), do: [local | stack]

  defp tl_stack([]), do: []
  defp tl_stack([_head | tail]), do: tail

  # Character data is entity-decoded. A CDATA section is kept literal, so `&`
  # inside it stays `&`.
  defp read_text(rest), do: read_text(rest, [])

  defp read_text(<<"<![CDATA[", rest::binary>>, parts) do
    case take_marker(rest, "]]>") do
      {inner, rest} -> read_text(rest, [{:raw, inner} | parts])
      :missing -> {join_text([{:raw, rest} | parts]), ""}
    end
  end

  defp read_text(<<"<!--", rest::binary>>, parts) do
    case take_marker(rest, "-->") do
      {_comment, rest} -> read_text(rest, parts)
      :missing -> {join_text(parts), ""}
    end
  end

  defp read_text(<<"</", _rest::binary>> = rest, parts), do: {join_text(parts), rest}
  defp read_text(<<>>, parts), do: {join_text(parts), ""}
  defp read_text(<<"<", rest::binary>>, parts), do: read_text(rest, [{:text, "<"} | parts])

  defp read_text(rest, parts) do
    size = plain_size(rest, 0)
    <<chunk::binary-size(size), rest::binary>> = rest
    read_text(rest, [{:text, chunk} | parts])
  end

  defp plain_size(<<"<", _rest::binary>>, size), do: size
  defp plain_size(<<_byte, rest::binary>>, size), do: plain_size(rest, size + 1)
  defp plain_size(<<>>, size), do: size

  defp join_text(parts) do
    parts
    |> Enum.reverse()
    |> Enum.map_join(fn
      {:raw, text} -> text
      {:text, text} -> decode_entities(text)
    end)
    |> String.trim()
  end

  defp drop_end_tag(<<"</", rest::binary>>), do: skip_until(rest, ">")
  defp drop_end_tag(rest), do: rest

  defp add_entry(acc, local, parent, attrs, text) do
    case classify(local, parent, attrs, text) do
      {kind, url} -> [{kind, url} | acc]
      :skip -> acc
    end
  end

  defp classify(local, parent, attrs, text) do
    href = blank(Map.get(attrs, "href"))
    rel = Map.get(attrs, "rel")

    cond do
      local == "loc" and parent == "url" -> tagged(:page, text)
      local == "loc" and parent == "sitemap" -> tagged(:child, text)
      local == "loc" and parent == "image" -> tagged(:image, text)
      local in @image_elements -> tagged(:image, text)
      local == "link" and parent == "item" -> tagged(:page, text)
      local == "link" and parent == "entry" and entry_page?(rel) -> tagged(:page, href)
      local == "link" and parent == "url" and alternate?(rel) -> tagged(:page, href)
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

  defp alternate?(rel) when is_binary(rel) do
    rel
    |> String.split(~r/[\t\n\f\r ]+/, trim: true)
    |> Enum.any?(&(String.downcase(&1, :ascii) == "alternate"))
  end

  defp alternate?(_rel), do: false

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
      _match, decimal, "" -> codepoint_char(String.to_integer(decimal))
      _match, "", hex -> codepoint_char(String.to_integer(hex, 16))
    end)
  end

  defp codepoint_char(codepoint) do
    if codepoint?(codepoint), do: <<codepoint::utf8>>, else: ""
  end

  defp codepoint?(codepoint) when codepoint in 0..0xD7FF, do: true
  defp codepoint?(codepoint) when codepoint in 0xE000..0x10FFFF, do: true
  defp codepoint?(_codepoint), do: false

  defp skip_until(binary, marker) do
    {_before, rest} = split_marker(binary, marker)
    rest
  end

  defp take_marker(binary, marker) do
    case :binary.split(binary, marker) do
      [before, rest] -> {before, rest}
      [_before] -> :missing
    end
  end

  defp split_marker(binary, marker) do
    case :binary.split(binary, marker) do
      [before, rest] -> {before, rest}
      [before] -> {before, ""}
    end
  end

  defp split_entries(acc) do
    Enum.reduce(acc, {[], []}, fn
      {:page, url}, {urls, children} -> {[{:page, url} | urls], children}
      {:image, url}, {urls, children} -> {[{:image, url} | urls], children}
      {:child, url}, {urls, children} -> {urls, [url | children]}
      _other, acc -> acc
    end)
  end
end
