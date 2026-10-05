defmodule Crawler.Parser do
  @moduledoc """
  Parses pages and calls a link handler to handle the detected links.
  """

  alias Crawler.Dispatcher
  alias Crawler.HTMLSpans
  alias Crawler.MediaType
  alias Crawler.Parser.CssParser
  alias Crawler.Parser.Guarder
  alias Crawler.Parser.HtmlParser
  alias Crawler.Parser.JsParser
  alias Crawler.Parser.LinkParser
  alias Crawler.Robots
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

    {:ok, _page} = opts[:scraper].scrape(page)
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
    opts = put_base_href(body, put_robots_nofollow(body, opts))

    opts
    |> Guarder.pass?()
    |> do_parse_links(body, opts, link_handler)
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
    Enum.map(
      parse_file(body, opts),
      &LinkParser.parse(&1, opts, link_handler)
    )
  end

  defp parse_file(body, opts) do
    type = opts[:content_type]

    cond do
      MediaType.css?(type) ->
        CssParser.parse(body)

      MediaType.javascript?(type) ->
        JsParser.elements(body, Map.get(opts, :javascript_goal, :module))

      true ->
        HtmlParser.references(body, opts)
    end
  end
end
