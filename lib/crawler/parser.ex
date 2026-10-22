defmodule Crawler.Parser do
  @moduledoc """
  Parses pages and calls a link handler to handle the detected links.
  """

  alias Crawler.Dispatcher
  alias Crawler.HTMLReferences
  alias Crawler.HTMLSpans
  alias Crawler.HTTP.DocumentHeaders
  alias Crawler.ImportMap
  alias Crawler.MediaType
  alias Crawler.Parser.CssParser
  alias Crawler.Parser.CssParser.DocumentStyles
  alias Crawler.Parser.CssSheets
  alias Crawler.Parser.Guarder
  alias Crawler.Parser.HtmlParser
  alias Crawler.Parser.LinkParser
  alias Crawler.Parser.ScriptReferences
  alias Crawler.Parser.SourceMap
  alias Crawler.Parser.SpeculationRules
  alias Crawler.Parser.WebManifest
  alias Crawler.Robots
  alias Crawler.Sitemap
  alias Crawler.URL

  require Logger

  defmodule Spec do
    @moduledoc """
    Spec for defining a parser.
    """

    alias Crawler.Store.Page

    @type url :: String.t()
    @type body :: String.t()
    @type opts :: map
    @type page :: %Page{url: url, body: body, opts: opts}

    @callback parse(page) :: {:ok, page}
    @callback parse({:error, term}) :: :ok
  end

  @behaviour __MODULE__.Spec

  @doc """
  Parses the links and returns the page.

  Discovered links are sent to `Crawler.Dispatcher`. The scraper module in
  `page.opts[:scraper]` receives the page after link discovery. Its
  `scrape/1` result is returned.

  A custom parser can use `parse_links/3` with its own link handler. Crawled
  data is also available asynchronously; see the
  [README](https://github.com/fredwu/crawler#usage).

  ## Examples

      iex> {:ok, page} = Parser.parse(%Page{
      iex>   body: "Body",
      iex>   opts: %{scraper: Crawler.Scraper, html_tag: "a", content_type: "text/html"}
      iex> })
      iex> page.body
      "Body"

      iex> {:ok, page} = Parser.parse(%Page{
      iex>   body: "<a href='http://parser/1'>Link</a>",
      iex>   opts: %{scraper: Crawler.Scraper, html_tag: "a", content_type: "text/html"}
      iex> })
      iex> page.body
      "<a href='http://parser/1'>Link</a>"

      iex> {:ok, page} = Parser.parse(%Page{
      iex>   body: "<a name='hello'>Link</a>",
      iex>   opts: %{scraper: Crawler.Scraper, html_tag: "a", content_type: "text/html"}
      iex> })
      iex> page.body
      "<a name='hello'>Link</a>"

      iex> {:ok, page} = Parser.parse(%Page{
      iex>   body: "<a href='http://parser/2' target='_blank'>Link</a>",
      iex>   opts: %{scraper: Crawler.Scraper, html_tag: "a", content_type: "text/html"}
      iex> })
      iex> page.body
      "<a href='http://parser/2' target='_blank'>Link</a>"

      iex> {:ok, page} = Parser.parse(%Page{
      iex>   body: "<a href='parser/2'>Link</a>",
      iex>   opts: %{scraper: Crawler.Scraper, html_tag: "a", content_type: "text/html", referrer_url: "http://hello"}
      iex> })
      iex> page.body
      "<a href='parser/2'>Link</a>"

      iex> {:ok, page} = Parser.parse(%Page{
      iex>   body: "<a href='../parser/2'>Link</a>",
      iex>   opts: %{scraper: Crawler.Scraper, html_tag: "a", content_type: "text/html", referrer_url: "http://hello"}
      iex> })
      iex> page.body
      "<a href='../parser/2'>Link</a>"

      iex> {:ok, page} = Parser.parse(%Page{
      iex>   body: image_file(),
      iex>   opts: %{scraper: Crawler.Scraper, html_tag: "img", content_type: "image/png"}
      iex> })
      iex> page.body
      "\#{image_file()}"
  """
  def parse(input)

  def parse({:warn, reason}), do: Logger.debug(fn -> "#{inspect(reason)}" end)
  def parse({:error, _reason}), do: Logger.error("Crawl failed")

  def parse(%{body: body, opts: opts} = page) do
    parse_links(body, opts, &Dispatcher.dispatch(&1, &2))

    opts =
      if Sitemap.ingest(opts, body) do
        Map.put(opts, :count_page, false)
      else
        opts
      end

    {:ok, _page} = opts[:scraper].scrape(%{page | opts: opts})
  end

  @doc """
  Discovers links in `body` with the page options in `opts`.

  Calls `link_handler.(element, link_opts)` for each discovered link. An element
  is `{attribute, url}` when the URL is unchanged, or
  `{"link", original_link, attribute, resolved_url}` when it is resolved or
  normalized. The link options include its resource tag and any HTML base URL.

  Returns the handler results grouped by parsed element. Returns an empty list
  when the page cannot be parsed. This function does not call the scraper.
  """
  def parse_links(body, opts, link_handler) do
    cond do
      opts[:fetch_kind] == :manifest ->
        manifest_links(body, opts, link_handler)

      opts[:fetch_kind] == :speculation_rules ->
        speculation_file_links(body, opts, link_handler)

      opts[:fetch_kind] == :source_map ->
        source_map_links(body, opts, link_handler)

      true ->
        opts = put_base_href(body, remember_document_url(put_robots_nofollow(body, opts)))
        opts = assign_style_group(body, opts)

        opts
        |> Guarder.pass?()
        |> do_parse_links(body, opts, link_handler)
    end
  end

  @doc false
  def with_document_base(body, opts), do: put_base_href(body, opts)

  @doc false
  def assigned_style_group(body, opts), do: assign_style_group(body, opts)[:style_group]

  @doc false
  def document_styles(body, opts) do
    if is_nil(opts[:generation]) and document?(opts) do
      opts = put_base_href(body, opts)
      DocumentStyles.new(HtmlParser.references(body, opts), opts[:referrer_url] || opts[:url])
    end
  end

  defp put_robots_nofollow(body, opts) do
    cond do
      opts[:respect_robots] == false ->
        Map.delete(opts, :robots_nofollow)

      Robots.header_nofollow?(opts[:headers], opts[:user_agent]) ->
        Map.put(opts, :robots_nofollow, true)

      html?(opts) and Robots.meta_nofollow?(body, opts[:user_agent]) ->
        Map.put(opts, :robots_nofollow, true)

      true ->
        Map.delete(opts, :robots_nofollow)
    end
  end

  defp remember_document_url(opts) do
    if document?(opts) and not present_url?(opts[:document_url]) do
      put_document_url(opts, opts[:referrer_url] || opts[:url])
    else
      opts
    end
  end

  defp present_url?(url) when is_binary(url) and url != "", do: true
  defp present_url?(_url), do: false

  defp put_document_url(opts, url) when is_binary(url) and url != "",
    do: Map.put(opts, :document_url, url)

  defp put_document_url(opts, _url), do: opts

  defp assign_style_group(body, %{srcdoc: true} = opts) do
    Map.put(opts, :style_group, srcdoc_group(opts, body))
  end

  defp assign_style_group(_body, opts) do
    cond do
      MediaType.css?(opts[:content_type]) -> keep_or_assign_group(opts)
      document?(opts) -> document_group(opts)
      true -> keep_or_assign_group(opts)
    end
  end

  defp document_group(%{url: url} = opts) when is_binary(url) and url != "",
    do: Map.put(opts, :style_group, url)

  defp document_group(opts), do: keep_or_assign_group(opts)

  defp keep_or_assign_group(%{style_group: group} = opts) when is_binary(group) and group != "",
    do: opts

  defp keep_or_assign_group(%{url: url} = opts) when is_binary(url) and url != "",
    do: Map.put(opts, :style_group, url)

  defp keep_or_assign_group(opts), do: opts

  defp srcdoc_group(opts, body) do
    base = if present_url?(opts[:url]), do: opts[:url], else: ""
    base <> " srcdoc " <> Integer.to_string(:erlang.phash2(body))
  end

  defp put_base_href(body, opts) when is_binary(body) do
    if html?(opts) do
      case base_href(body) do
        nil -> opts
        href -> Map.put(opts, :referrer_url, merge_base(href, opts))
      end
    else
      opts
    end
  end

  defp put_base_href(_body, opts), do: opts

  defp html?(opts), do: MediaType.html?(opts[:content_type])

  defp base_href(body) do
    case HTMLSpans.base_tags(body) do
      [tag | _] -> HTMLSpans.value(tag, "href")
      [] -> nil
    end
  end

  defp merge_base(href, opts) do
    base = opts[:referrer_url] || opts[:url] || ""

    case URL.resolve(href, base) do
      {:ok, url} -> restore_directory(href, url)
      :skip -> base
    end
  end

  defp restore_directory(href, url) do
    if directory_ref?(href), do: slash_directory(url), else: url
  end

  defp directory_ref?(href) when is_binary(href) do
    case href |> URL.sanitize() |> URI.parse() do
      %URI{path: path} when is_binary(path) -> String.ends_with?(path, "/")
      _ -> false
    end
  end

  defp directory_ref?(_href), do: false

  defp slash_directory(url) do
    case String.split(url, "?", parts: 2) do
      [bare, query] -> bare_slash(bare) <> "?" <> query
      [bare] -> bare_slash(bare)
    end
  end

  defp bare_slash(bare) do
    if String.ends_with?(bare, "/"), do: bare, else: bare <> "/"
  end

  defp do_parse_links(false, _body, _opts, _link_handler), do: []

  defp do_parse_links(true, body, opts, link_handler) do
    elements =
      body
      |> parse_file(opts)
      |> prepend_document_headers(opts)

    if document?(opts) do
      base = opts[:referrer_url] || opts[:url]

      styles =
        opts[:document_styles] ||
          if(is_nil(opts[:generation]), do: DocumentStyles.new(elements, base))

      opts = Map.put(opts, :document_styles, styles)
      walk_document(elements, Map.put(opts, :document_base, base), link_handler)
    else
      Enum.map(elements, &LinkParser.parse(&1, opts, link_handler))
    end
  end

  defp document?(opts) do
    MediaType.html?(opts[:content_type]) or MediaType.svg?(opts[:content_type])
  end

  defp walk_document(elements, opts, link_handler) do
    handler = fn link, link_opts ->
      link_handler.(link, Map.drop(link_opts, [:document_styles, :document_style_id]))
    end

    {results, _state} =
      Enum.map_reduce(elements, %{map: ImportMap.empty(), manifest: false}, fn element, state ->
        opts =
          opts
          |> Map.put(:import_map, state.map)
          |> Map.put(:document_style_id, document_style_id(element))

        {result, manifest} = parse_document_element(element, opts, handler, state.manifest)

        {result, %{map: register_import_map(element, state.map, opts), manifest: manifest}}
      end)

    results
  end

  defp document_style_id(%{span: span}), do: span
  defp document_style_id(_element), do: nil

  defp parse_document_element(element, opts, link_handler, manifest_seen) do
    if manifest_candidate?(element) and manifest_seen do
      {nil, true}
    else
      {LinkParser.parse(element, opts, link_handler),
       manifest_seen or manifest_candidate?(element)}
    end
  end

  defp manifest_candidate?(%{name: "link", namespace: :html, attributes: attrs}) do
    match?(%{fetch_kind: :manifest}, HTMLReferences.link_choice(attrs))
  end

  defp manifest_candidate?(_element), do: false

  defp manifest_links(body, opts, handler) do
    body
    |> WebManifest.entries(manifest_base(opts))
    |> Enum.map(&emit_manifest(&1, opts, handler))
  end

  # referrer_url is the response. url remains the request that was redirected.
  defp manifest_base(%{referrer_url: url}) when is_binary(url) and url != "", do: url
  defp manifest_base(%{url: url}) when is_binary(url), do: url
  defp manifest_base(_opts), do: ""

  defp emit_manifest({:page, raw, url, start, length}, opts, handler) do
    handler.(linked(raw, url), with_span(page_opts(opts), start, length))
  end

  defp emit_manifest({:image, raw, url, start, length}, opts, handler) do
    if HTMLReferences.enabled?(opts, "images") do
      handler.(linked(raw, url), with_span(child_opts(opts, "img", "img"), start, length))
    end
  end

  defp source_map_links(body, opts, handler) do
    body
    |> SourceMap.entries(opts)
    |> Enum.map(fn entry ->
      handler.(linked(entry.raw, entry.url), map_child_opts(opts, entry))
    end)
  end

  defp map_child_opts(opts, entry) do
    opts
    |> Map.drop([
      :cookie_navigation,
      :credentials,
      :document_base,
      :document_url,
      :fetch_kind,
      :import_map,
      :javascript_goal,
      :json_span,
      :link_html_tag,
      :page_open,
      :worker_base
    ])
    |> Map.put(:html_tag, "link")
    |> Map.put(:reference_tag, "link")
    |> put_fetch_kind(entry.fetch_kind)
    |> put_json_span(entry.json_span)
  end

  defp put_fetch_kind(opts, :source_map), do: Map.put(opts, :fetch_kind, :source_map)
  defp put_fetch_kind(opts, _kind), do: opts

  defp put_json_span(opts, {start, length}), do: with_span(opts, start, length)
  defp put_json_span(opts, _span), do: opts

  defp speculation_file_links(body, opts, handler) do
    body
    |> SpeculationRules.entries(opts)
    |> Enum.map(fn {raw, url, start, length, action} ->
      handler.(linked(raw, url), with_span(speculation_opts(opts, action), start, length))
    end)
  end

  defp linked(raw, url) when raw == url, do: {"href", url}
  defp linked(raw, url), do: {"link", raw, "href", url}

  defp child_opts(opts, html_tag, reference_tag) do
    opts
    |> Map.drop([
      :fetch_kind,
      :document_base,
      :document_url,
      :json_span,
      :credentials,
      :page_open
    ])
    |> Map.put(:html_tag, html_tag)
    |> Map.put(:reference_tag, reference_tag)
  end

  defp speculation_opts(opts, :prefetch) do
    opts
    |> page_opts()
    |> Map.put(:credentials, :same_site)
    |> Map.put(:page_open, false)
  end

  defp speculation_opts(opts, _action), do: page_opts(opts)

  # Recorder has already counted this file. Its pages belong with the document's links.
  defp page_opts(opts) do
    opts = child_opts(opts, "a", "a")

    case opts[:depth] do
      depth when is_integer(depth) -> Map.put(opts, :depth, max(depth - 1, 0))
      _depth -> opts
    end
  end

  defp with_span(opts, start, length), do: Map.put(opts, :json_span, {start, length})

  defp register_import_map(
         %{name: "script", namespace: :html, in_shadow_root?: false} = tag,
         map,
         opts
       ) do
    if import_map_element?(tag.attributes, opts) do
      ImportMap.merge_source(raw_text(tag.children), map, opts[:document_base] || "")
    else
      map
    end
  end

  defp register_import_map(_element, map, _opts), do: map

  defp import_map_element?(attrs, opts) do
    HTMLReferences.enabled?(opts, "js") and HTMLReferences.import_map?(attrs)
  end

  defp raw_text(children) do
    Enum.map_join(children, fn
      text when is_binary(text) -> text
      _child -> ""
    end)
  end

  defp prepend_document_headers(elements, opts) do
    if html?(opts) do
      header_elements(opts) ++ elements
    else
      elements
    end
  end

  defp header_elements(opts) do
    links = Enum.map(DocumentHeaders.elements(opts[:headers]), &mark_header_element/1)
    links ++ speculation_header_elements(opts)
  end

  defp mark_header_element({"link", attrs, children}) do
    {"link", attrs ++ [{"crawler-from-header", "true"}], children}
  end

  defp mark_header_element(element), do: element

  defp speculation_header_elements(opts) do
    opts[:headers]
    |> SpeculationRules.header_urls()
    |> Enum.map(fn url ->
      {"link",
       [
         {"href", url},
         {"crawler-speculation-rules", "true"},
         {"crawler-from-header", "true"}
       ], []}
    end)
  end

  defp parse_file(body, opts) do
    type = opts[:content_type]

    cond do
      MediaType.css?(type) ->
        css_elements(body, opts) ++ SourceMap.element_refs(body, opts, :css)

      MediaType.javascript?(type) ->
        ScriptReferences.elements(body, opts)

      true ->
        xml_stylesheets(body, opts) ++ HtmlParser.references(body, opts)
    end
  end

  defp css_elements(body, opts) when is_binary(body) do
    tokens =
      body
      |> CssParser.spans(opts)
      |> Enum.uniq_by(& &1.value)

    extras =
      opts
      |> CssSheets.take_urls(body, tokens)
      |> Enum.map(&{:css, &1, :url})

    tokens
    |> Enum.map(&css_link/1)
    |> Kernel.++(extras)
    |> Enum.uniq_by(fn {:css, value, _kind} -> value end)
  end

  defp css_elements(_body, _opts), do: []

  defp css_link(token), do: {:css, token.value, span_kind(token)}

  defp span_kind(%{kind: kind}) when kind in [:font, :import, :url], do: kind
  defp span_kind(_span), do: :url

  defp xml_stylesheets(body, opts) do
    if MediaType.svg?(opts[:content_type]) do
      Enum.map(HTMLSpans.css_xml_stylesheets(body), fn sheet ->
        {"link", [{"rel", "stylesheet"}, {"href", sheet.href}, {"type", sheet.type}], []}
      end)
    else
      []
    end
  end
end
