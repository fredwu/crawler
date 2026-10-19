defmodule Crawler.Sitemap do
  @moduledoc false

  alias Crawler.Charset
  alias Crawler.Charset.Encoding
  alias Crawler.Charset.Labels
  alias Crawler.Fetcher.Policer
  alias Crawler.Fetcher.Requester
  alias Crawler.Fetcher.Retrier
  alias Crawler.HTMLReferences
  alias Crawler.HTTP
  alias Crawler.MediaType
  alias Crawler.Robots
  alias Crawler.Site
  alias Crawler.Store
  alias Crawler.URL

  @text_elements ["loc", "link", "thumbnail_loc", "content_loc", "guid"]
  @image_elements ["thumbnail_loc", "content_loc"]
  @prose_elements ["title", "description", "summary", "subtitle", "caption", "keywords"]
  @catalog_roots ["urlset", "sitemapindex", "rss", "feed", "rdf"]

  def follow(opts, origin, rules) when is_map(rules) do
    rules
    |> Map.get(:sitemaps, [])
    |> Enum.reduce(document_state(opts), fn url, state ->
      fetch_document(opts, origin <> "/", url, state)
    end)

    :ok
  end

  def follow(_opts, _origin, _rules), do: :ok

  # A fetched RSS, Atom, RSS 1.0, or sitemap document contributes its pages and
  # does not take a page slot. Ordinary text, and XML that is not one of those
  # documents, returns false so the caller keeps it as a normal file.
  def ingest(opts, body) when is_map(opts) and is_binary(body) do
    case catalog_body(opts, body) do
      {:ok, text} ->
        base = catalog_base(opts)
        {urls, children} = xml_entries(text)
        state = document_state(opts)
        state = enqueue_urls(opts, urls, base, state)
        reduce_children(state, opts, base, children)

        true

      :skip ->
        false
    end
  end

  def ingest(_opts, _body), do: false

  @doc false
  def locations(body) when is_binary(body) do
    {urls, children} = entries(body)
    {page_urls(urls), child_urls(children)}
  end

  # `:ops` counts finished pages. Another worker can finish a URL this walk has
  # already reserved, so adding the live count to that reservation counts the
  # page twice and stops the index early. The in-flight seed is not in `:ops`
  # yet; counting it here would leave no room for a small `max_pages`.
  defp fetch_document(opts, base, url, state) do
    if room?(opts, state), do: fetch_unseen(opts, base, url, state), else: state
  end

  defp fetch_child(opts, base, {url, bases}, state) do
    case resolve_chain(url, base, bases) do
      {:ok, absolute} -> fetch_resolved(opts, absolute, state)
      :skip -> state
    end
  end

  defp fetch_resolved(opts, absolute, state) do
    if room?(opts, state), do: remember(opts, absolute, state), else: state
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
    if sitemap_allowed?(opts, url), do: read_sitemap(opts, url, state), else: state
  end

  defp read_sitemap(opts, url, state) do
    case fetch_text(opts, url) do
      {:ok, body, final} ->
        {urls, children} = entries(body)
        state = enqueue_urls(opts, urls, final, state)

        Enum.reduce(children, state, &fetch_child(opts, final, &1, &2))

      :skip ->
        state
    end
  end

  defp sitemap_allowed?(opts, url) do
    Robots.permitted?(sitemap_opts(opts, url))
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
    |> Map.put(:cookie_site, document_site(opts))
    |> Map.put(:url, url)
    |> Map.put(:sitemap_fetch, true)
    |> Map.put(:cookie_navigation, false)
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
    enqueue_located(opts, :page, loc, [], base, state)
  end

  defp enqueue_url(opts, {:page, loc, bases}, base, state) do
    enqueue_located(opts, :page, loc, bases, base, state)
  end

  defp enqueue_url(opts, {:image, loc, bases}, base, state) do
    enqueue_located(opts, :image, loc, bases, base, state)
  end

  defp enqueue_located(opts, :page, loc, bases, base, state) do
    case resolve_chain(loc, base, bases) do
      {:ok, url} -> reserve_page(opts, url, state)
      :skip -> state
    end
  end

  defp enqueue_located(opts, :image, loc, bases, base, state) do
    if HTMLReferences.enabled?(opts, "images") do
      case resolve_chain(loc, base, bases) do
        {:ok, url} -> reserve_image(opts, url, state)
        :skip -> state
      end
    else
      state
    end
  end

  # xml:base values are raw and outermost first. Each one is resolved against
  # the base above it, then the address is resolved against the last base.
  defp resolve_chain(loc, document_url, bases) do
    URL.resolve(loc, Enum.reduce(bases, document_url, &resolve_base/2))
  end

  defp resolve_base(base, parent) do
    case URL.resolve(base, parent) do
      {:ok, absolute} -> absolute
      :skip -> parent
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

  # A URL this crawl will not fetch does not finish a page, so it must not take
  # a budget slot. Depth and the URL filter are decided here, before the queue
  # runs. Another host's robots.txt is read only to answer this check.
  defp reserve_fetch(opts, url, opts_fun, state) do
    key = URL.canonical(url)
    crawl_opts = opts |> opts_fun.() |> Map.put(:url, url)

    cond do
      MapSet.member?(state.pages, key) -> state
      stored?(opts, url) -> remember_page(state, key)
      not fetchable?(crawl_opts) -> remember_page(state, key)
      not fetch_allowed?(crawl_opts) -> remember_page(state, key)
      true -> admit(opts, url, opts_fun, remember_page(state, key))
    end
  end

  defp fetchable?(opts), do: match?({:ok, _}, Policer.police(opts))

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

  defp fetch_allowed?(opts), do: Robots.permitted?(opts)

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
    |> Map.put(:cookie_site, document_site(opts))
  end

  defp image_opts(opts) do
    opts
    |> shared_opts()
    |> Map.put(:html_tag, "img")
    |> Map.put(:reference_tag, "img")
    |> Map.put(:cookie_site, document_site(opts))
  end

  # Capture the page before :url becomes the sitemap or image address.
  defp document_site(opts), do: opts[:cookie_site] || opts[:url]

  defp shared_opts(opts) do
    opts
    |> Map.drop([
      :alias_candidate,
      :alias_created,
      :alias_url,
      :before_publish,
      :content_type,
      :headers,
      :cookie_navigation,
      :reference_tag,
      :referrer_url,
      :robots_fetch,
      :robots_nofollow,
      :count_page,
      :fetch_kind,
      :sitemap_fetch,
      :url
    ])
    |> Map.put(:depth, 1)
  end

  defp document_state(opts) do
    %{
      files: MapSet.new(),
      pages: seed_page(opts),
      reserved: 0,
      start_ops: Store.ops_count(opts[:scope])
    }
  end

  defp reduce_children(state, opts, base, children) do
    Enum.reduce(children, state, &fetch_child(opts, base, &1, &2))
  end

  defp catalog_base(opts) do
    case opts[:referrer_url] || opts[:url] do
      url when is_binary(url) and url != "" -> url
      _ -> ""
    end
  end

  defp catalog_body(opts, body) do
    with true <- catalog_media?(opts[:content_type]),
         {:ok, inflated} <- inflate(body, max_body(opts)),
         text when is_binary(text) <- decode_document(inflated),
         true <- catalog_document?(text) do
      {:ok, text}
    else
      _ -> :skip
    end
  end

  defp catalog_media?(type), do: MediaType.feed?(type) or MediaType.xml?(type)

  defp catalog_document?(text) do
    text
    |> String.trim_leading()
    |> skip_markup_prolog()
    |> root_local_name()
    |> Kernel.in(@catalog_roots)
  end

  defp skip_markup_prolog(<<"<?", rest::binary>>) do
    rest |> skip_until("?>") |> String.trim_leading() |> skip_markup_prolog()
  end

  defp skip_markup_prolog(<<"<!--", rest::binary>>) do
    rest |> skip_until("-->") |> String.trim_leading() |> skip_markup_prolog()
  end

  defp skip_markup_prolog(<<"<!", rest::binary>>) do
    rest |> skip_until(">") |> String.trim_leading() |> skip_markup_prolog()
  end

  defp skip_markup_prolog(text), do: text

  defp root_local_name(<<"<", rest::binary>>) do
    {name, _rest} = take_name(rest)
    local_name(name)
  end

  defp root_local_name(_text), do: ""

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
    Enum.flat_map(urls, fn
      {:page, url, _bases} -> [url]
      {:page, url} -> [url]
      _other -> []
    end)
  end

  defp child_urls(children) do
    Enum.map(children, fn {url, _bases} -> url end)
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
    bases = element_bases(stack, attrs)

    cond do
      prose?(local, attrs) and not self_closing? ->
        acc = add_entry(acc, local, parent, attrs, "", bases)
        scan(skip_prose(rest, local), stack, acc)

      text_element?(local) and not self_closing? ->
        {text, rest} = read_text(rest)
        rest = drop_end_tag(rest)
        scan(rest, stack, add_entry(acc, local, parent, attrs, text, bases))

      true ->
        acc = add_entry(acc, local, parent, attrs, "", bases)
        scan(rest, push_stack(stack, local, bases, self_closing?), acc)
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

  defp parent_name([{local, _bases} | _rest]), do: local
  defp parent_name(_stack), do: ""

  defp parent_bases([{_local, bases} | _rest]), do: bases
  defp parent_bases(_stack), do: []

  defp element_bases(stack, attrs) do
    case blank(Map.get(attrs, "xml:base")) do
      nil -> parent_bases(stack)
      base -> parent_bases(stack) ++ [base]
    end
  end

  defp text_element?(local), do: local in @text_elements

  # A content element with a url attribute is Media RSS, so its children stay.
  defp prose?(local, attrs) do
    local in @prose_elements or (local == "content" and blank(Map.get(attrs, "url")) == nil)
  end

  defp push_stack(stack, "", _bases, _self_closing?), do: stack
  defp push_stack(stack, _local, _bases, true), do: stack
  defp push_stack(stack, local, bases, false), do: [{local, bases} | stack]

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

  # Prose can contain markup or a raw "<". Reading those bytes as elements
  # drops the address after the field. A "<" or "</" is a tag only when a
  # quote-aware scan finds its ">" before an unquoted "<" and before the
  # field end tag. Otherwise it is text. A field end tag is its name, optional
  # whitespace, then ">" or "<". An unfinished end tag of the open field
  # returns the following bytes to the scanner. Inside a nested field it closes
  # only that field, so the outer address stays. An open quote stops at that
  # end tag, so a later quote does not consume the address. An unclosed "<?",
  # comment, or CDATA is text. A "<?" ... "?>" is skipped, so a tag inside it
  # does not change depth; a field end tag with no "?>" leaves the instruction
  # open. A closed comment or CDATA is skipped through its terminator, so an
  # end-tag string inside it does not close the field. A nested tag of the
  # same name does not close the outer field either.
  defp skip_prose(rest, local), do: skip_prose(rest, local, 1)
  defp skip_prose(rest, _local, 0), do: rest
  defp skip_prose(<<>>, _local, _depth), do: <<>>

  defp skip_prose(<<"<![CDATA[", rest::binary>>, local, depth) do
    skip_marked(rest, "]]>", local, depth)
  end

  defp skip_prose(<<"<!--", rest::binary>>, local, depth) do
    skip_marked(rest, "-->", local, depth)
  end

  defp skip_prose(<<"<?", rest::binary>>, local, depth) do
    case take_instruction(rest, local) do
      {:closed, tail} -> skip_prose(tail, local, depth)
      :open -> skip_prose(rest, local, depth)
    end
  end

  defp skip_prose(<<"</", rest::binary>>, local, depth) do
    case tag_boundary(rest, local) do
      {:tag, name, tail, _self_closing?} ->
        depth = if local_name(name) == local, do: depth - 1, else: depth
        skip_prose(tail, local, depth)

      :text ->
        close_open_field(rest, local, depth)
    end
  end

  defp skip_prose(<<"<", rest::binary>>, local, depth) do
    case tag_boundary(rest, local) do
      {:tag, name, tail, self_closing?} ->
        depth = if local_name(name) == local and not self_closing?, do: depth + 1, else: depth
        skip_prose(tail, local, depth)

      :text ->
        skip_prose(rest, local, depth)
    end
  end

  defp skip_prose(<<_byte, rest::binary>>, local, depth), do: skip_prose(rest, local, depth)

  defp close_open_field(rest, local, depth) do
    if field_end?(rest, local) do
      release_field(rest, local, depth)
    else
      skip_prose(rest, local, depth)
    end
  end

  defp release_field(rest, _local, 1), do: rest
  defp release_field(rest, local, depth), do: skip_prose(rest, local, depth - 1)

  defp skip_marked(rest, marker, local, depth) do
    case take_marker(rest, marker) do
      {_inner, rest} -> skip_prose(rest, local, depth)
      :missing -> skip_prose(rest, local, depth)
    end
  end

  defp take_instruction(rest, local), do: take_instruction(rest, local, :text)
  defp take_instruction(<<"?>", rest::binary>>, _local, :text), do: {:closed, rest}

  defp take_instruction(<<"</", rest::binary>>, local, :text) do
    if field_end?(rest, local) do
      :open
    else
      take_instruction(rest, local, :text)
    end
  end

  defp take_instruction(<<"</", _rest::binary>> = rest, local, quote) when quote != :text do
    if quote_crosses_field?(rest, local, quote) do
      :open
    else
      <<_byte, rest::binary>> = rest
      take_instruction(rest, local, quote)
    end
  end

  defp take_instruction(<<"\"", rest::binary>>, local, :text),
    do: take_instruction(rest, local, :double)

  defp take_instruction(<<"'", rest::binary>>, local, :text),
    do: take_instruction(rest, local, :single)

  defp take_instruction(<<"\"", rest::binary>>, local, :double),
    do: take_instruction(rest, local, :text)

  defp take_instruction(<<"'", rest::binary>>, local, :single),
    do: take_instruction(rest, local, :text)

  defp take_instruction(<<_byte, rest::binary>>, local, quote),
    do: take_instruction(rest, local, quote)

  defp take_instruction(<<>>, _local, _quote), do: :open

  defp field_end?(rest, local) do
    case field_mark(rest, local) do
      {:yes, _tail} -> true
      :no -> false
    end
  end

  defp field_mark(rest, local) do
    {name, tail} = take_name(rest)

    if name != "" and local_name(name) == local do
      mark_tail(tail)
    else
      :no
    end
  end

  # Whitespace may separate the name from ">". An unfinished tag ends at the
  # next "<"; that "<" stays in the tail so a still-open quote can see it.
  defp mark_tail(<<">", rest::binary>>), do: {:yes, rest}
  defp mark_tail(<<"<", _rest::binary>> = rest), do: {:yes, rest}
  defp mark_tail(<<byte, rest::binary>>) when byte in [?\s, ?\t, ?\n, ?\r], do: mark_tail(rest)
  defp mark_tail(_rest), do: :no

  defp tag_boundary(rest, local) do
    if name_start?(rest) do
      case scan_tag(rest, :text, false, local) do
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

  defp name_start?(<<char, _::binary>>)
       when char in ?A..?Z or char in ?a..?z or char in [?_, ?:],
       do: true

  defp name_start?(_rest), do: false

  defp scan_tag(<<">", rest::binary>>, :text, slash, _local), do: {:tag, rest, slash}
  defp scan_tag(<<"<", _rest::binary>>, :text, _slash, _local), do: :text

  defp scan_tag(<<"\"", rest::binary>>, :text, _slash, local),
    do: scan_tag(rest, :double, false, local)

  defp scan_tag(<<"'", rest::binary>>, :text, _slash, local),
    do: scan_tag(rest, :single, false, local)

  defp scan_tag(<<"/", rest::binary>>, :text, _slash, local),
    do: scan_tag(rest, :text, true, local)

  defp scan_tag(<<byte, rest::binary>>, :text, slash, local) when byte in [?\s, ?\t, ?\n, ?\r] do
    scan_tag(rest, :text, slash, local)
  end

  defp scan_tag(<<_byte, rest::binary>>, :text, _slash, local),
    do: scan_tag(rest, :text, false, local)

  defp scan_tag(<<"</", _rest::binary>> = rest, quote, _slash, local) when quote != :text do
    if quote_crosses_field?(rest, local, quote) do
      :text
    else
      <<_byte, rest::binary>> = rest
      scan_tag(rest, quote, false, local)
    end
  end

  defp scan_tag(<<"\"", rest::binary>>, :double, _slash, local),
    do: scan_tag(rest, :text, false, local)

  defp scan_tag(<<"'", rest::binary>>, :single, _slash, local),
    do: scan_tag(rest, :text, false, local)

  defp scan_tag(<<_byte, rest::binary>>, quote, _slash, local) when quote != :text do
    scan_tag(rest, quote, false, local)
  end

  defp scan_tag(<<>>, _quote, _slash, _local), do: :text

  defp quote_crosses_field?(<<"</", rest::binary>>, local, quote) do
    case field_mark(rest, local) do
      {:yes, tail} -> not quote_closes_first?(tail, quote)
      :no -> false
    end
  end

  defp quote_closes_first?(<<"<", _rest::binary>>, _quote), do: false
  defp quote_closes_first?(<<"\"", _rest::binary>>, :double), do: true
  defp quote_closes_first?(<<"'", _rest::binary>>, :single), do: true
  defp quote_closes_first?(<<_byte, rest::binary>>, quote), do: quote_closes_first?(rest, quote)
  defp quote_closes_first?(<<>>, _quote), do: false

  defp add_entry(acc, local, parent, attrs, text, bases) do
    case classify(local, parent, attrs, text) do
      {kind, url} -> [{kind, url, bases} | acc]
      :skip -> acc
    end
  end

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
      {:page, url, bases}, {urls, children} -> {[{:page, url, bases} | urls], children}
      {:image, url, bases}, {urls, children} -> {[{:image, url, bases} | urls], children}
      {:child, url, bases}, {urls, children} -> {urls, [{url, bases} | children]}
      _other, pair -> pair
    end)
  end
end
