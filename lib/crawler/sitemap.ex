defmodule Crawler.Sitemap do
  @moduledoc false

  alias Crawler.Fetcher.Requester
  alias Crawler.Site
  alias Crawler.URL

  # A sitemap index can point at more indexes. Stop after a fixed number of files.
  @max_documents 32

  def follow(opts, origin, rules) when is_map(rules) do
    base = origin <> "/"
    seen = MapSet.new()

    rules
    |> Map.get(:sitemaps, [])
    |> Enum.reduce({seen, 0}, fn url, acc -> fetch_document(opts, base, url, acc) end)

    :ok
  end

  def follow(_opts, _origin, _rules), do: :ok

  @doc false
  def locations(body) when is_binary(body) do
    if String.valid?(body) do
      body
      |> strip_bom()
      |> scan([], [])
      |> split_locs()
    else
      {[], []}
    end
  end

  defp fetch_document(_opts, _base, _url, {_seen, count} = acc) when count >= @max_documents do
    acc
  end

  defp fetch_document(opts, base, url, {seen, count}) do
    case URL.resolve(url, base) do
      {:ok, absolute} ->
        key = URL.normalize(absolute)

        if MapSet.member?(seen, key) do
          {seen, count}
        else
          fetch_new(opts, absolute, MapSet.put(seen, key), count)
        end

      :skip ->
        {seen, count}
    end
  end

  defp fetch_new(opts, url, seen, count) do
    case request(opts, url) do
      {:ok, body, final} ->
        {pages, children} = locations(body)
        enqueue_pages(opts, pages, final)

        Enum.reduce(children, {seen, count + 1}, fn child, acc ->
          fetch_document(opts, final, child, acc)
        end)

      :error ->
        {seen, count + 1}
    end
  end

  defp request(opts, url) do
    sitemap_opts =
      opts
      |> Map.put(:url, url)
      |> Map.put(:sitemap_fetch, true)
      |> Map.delete(:reference_tag)

    case Requester.make(sitemap_opts) do
      {:ok, %{status: status, body: body} = response}
      when status in 200..299 and is_binary(body) ->
        case inflate(body, max_body(opts)) do
          text when is_binary(text) -> {:ok, text, final_url(response, url)}
          :error -> :error
        end

      _ ->
        :error
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
          if trailer_ok?(zlib), do: IO.iodata_to_binary(chunks), else: :error

        :error ->
          :error
      end
    rescue
      ErlangError -> :error
    after
      close_zlib(zlib)
    end
  end

  defp inflate(body, _max), do: body

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

  defp enqueue_pages(opts, pages, base) do
    Enum.each(pages, fn loc ->
      case URL.resolve(loc, base) do
        {:ok, url} -> maybe_enqueue(opts, url)
        :skip -> :ok
      end
    end)
  end

  defp maybe_enqueue(opts, url) do
    if page_in_scope?(opts, url), do: Crawler.crawl(url, page_opts(opts))
  end

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
    |> Map.put(:html_tag, "a")
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(body), do: body

  defp scan(<<"<!--", rest::binary>>, stack, acc), do: scan(skip_until(rest, "-->"), stack, acc)

  defp scan(<<"<![CDATA[", rest::binary>>, stack, acc) do
    scan(skip_until(rest, "]]>"), stack, acc)
  end

  defp scan(<<"<?", rest::binary>>, stack, acc), do: scan(skip_until(rest, "?>"), stack, acc)

  defp scan(<<"</", rest::binary>>, stack, acc),
    do: scan(skip_until(rest, ">"), tl_stack(stack), acc)

  defp scan(<<"<!", rest::binary>>, stack, acc), do: scan(skip_until(rest, ">"), stack, acc)

  defp scan(<<"<", rest::binary>>, stack, acc) do
    {name, rest, self_closing?} = read_start(rest)
    {prefix, local} = split_name(name)
    parent = List.first(stack)

    if local == "loc" and prefix in ["", "sitemap"] and not self_closing? do
      {text, rest} = read_text(rest)
      rest = drop_end_tag(rest)
      scan(rest, stack, [classify(parent, text) | acc])
    else
      scan(rest, push_stack(stack, local, self_closing?), acc)
    end
  end

  defp scan(<<_byte, rest::binary>>, stack, acc), do: scan(rest, stack, acc)
  defp scan(<<>>, _stack, acc), do: acc

  defp read_start(rest) do
    {name, rest} = take_name(rest)
    {rest, self_closing?} = skip_attrs(rest)
    {name, rest, self_closing?}
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

  defp skip_attrs(binary), do: skip_attrs(binary, nil)
  defp skip_attrs(<<"\"", rest::binary>>, nil), do: skip_attrs(rest, ?")
  defp skip_attrs(<<"'", rest::binary>>, nil), do: skip_attrs(rest, ?')
  defp skip_attrs(<<quote, rest::binary>>, quote), do: skip_attrs(rest, nil)
  defp skip_attrs(<<"/>", rest::binary>>, nil), do: {rest, true}
  defp skip_attrs(<<">", rest::binary>>, nil), do: {rest, false}
  defp skip_attrs(<<_byte, rest::binary>>, quote), do: skip_attrs(rest, quote)
  defp skip_attrs(<<>>, _quote), do: {<<>>, false}

  defp split_name(name) do
    case String.split(name, ":", parts: 2) do
      [local] -> {"", String.downcase(local)}
      [prefix, local] -> {String.downcase(prefix), String.downcase(local)}
    end
  end

  defp push_stack(stack, "", _self_closing?), do: stack
  defp push_stack(stack, _local, true), do: stack
  defp push_stack(stack, local, false), do: [local | stack]

  defp tl_stack([]), do: []
  defp tl_stack([_head | tail]), do: tail

  defp read_text(rest) do
    case :binary.split(rest, "</") do
      [text, rest] -> {text, "</" <> rest}
      [text] -> {text, ""}
    end
  end

  defp drop_end_tag(<<"</", rest::binary>>), do: skip_until(rest, ">")
  defp drop_end_tag(rest), do: rest

  defp classify(parent, text) do
    text = text |> decode_entities() |> String.trim()

    cond do
      text == "" -> :skip
      parent == "url" -> {:page, text}
      parent == "sitemap" -> {:child, text}
      true -> :skip
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
    Regex.replace(~r/&#(x?[0-9A-Fa-f]+);/, text, fn _match, digits ->
      codepoint =
        case digits do
          <<mark, hex::binary>> when mark in [?x, ?X] -> String.to_integer(hex, 16)
          decimal -> String.to_integer(decimal)
        end

      if codepoint?(codepoint), do: <<codepoint::utf8>>, else: ""
    end)
  end

  defp codepoint?(codepoint) when codepoint in 0..0xD7FF, do: true
  defp codepoint?(codepoint) when codepoint in 0xE000..0x10FFFF, do: true
  defp codepoint?(_codepoint), do: false

  defp skip_until(binary, marker) do
    case :binary.split(binary, marker) do
      [_before, rest] -> rest
      [_before] -> <<>>
    end
  end

  defp split_locs(acc) do
    Enum.reduce(acc, {[], []}, fn
      {:page, url}, {pages, children} -> {[url | pages], children}
      {:child, url}, {pages, children} -> {pages, [url | children]}
      _other, acc -> acc
    end)
  end
end
