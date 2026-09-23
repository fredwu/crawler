defmodule Crawler.Parser do
  @moduledoc """
  Parses pages and calls a link handler to handle the detected links.
  """

  alias Crawler.Dispatcher
  alias Crawler.Parser.CssParser
  alias Crawler.Parser.Guarder
  alias Crawler.Parser.HtmlParser
  alias Crawler.Parser.LinkParser
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

  There are two hooks:

  - `link_handler` is useful when a custom parser calls this default parser and
  utilises a different link handler for processing links.
  - `scraper` is useful for scraping content immediately as the parser parses
  the page, alternatively you can simply access the crawled data
  asynchronously, refer to the [README](https://github.com/fredwu/crawler#usage)

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
  def parse({:error, reason}), do: Logger.error(fn -> "#{inspect(reason)}" end)

  def parse(%{body: body, opts: opts} = page) do
    parse_links(body, opts, &Dispatcher.dispatch(&1, &2))

    {:ok, _page} = opts[:scraper].scrape(page)
  end

  def parse_links(body, opts, link_handler) do
    opts = put_base_href(body, opts)

    opts
    |> Guarder.pass?()
    |> do_parse_links(body, opts, link_handler)
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

  defp html?(opts) do
    case opts[:content_type] do
      "text/html" <> _ -> true
      nil -> true
      _ -> false
    end
  end

  defp base_href(body) do
    with {:ok, document} <- Floki.parse_document(body),
         [href | _] <- Floki.attribute(document, "base", "href") do
      href
    else
      _ -> nil
    end
  end

  defp merge_base(href, opts) do
    base = opts[:referrer_url] || opts[:url] || ""

    case URL.resolve(href, base) do
      {:ok, url} -> url
      :skip -> base
    end
  end

  defp do_parse_links(false, _body, _opts, _link_handler), do: []

  defp do_parse_links(true, body, opts, link_handler) do
    Enum.map(
      parse_file(body, opts),
      &LinkParser.parse(&1, opts, link_handler)
    )
  end

  defp parse_file(body, %{content_type: "text/css"}), do: CssParser.parse(body)
  defp parse_file(body, opts), do: HtmlParser.parse(body, opts)
end
