defmodule Crawler.Parser do
  @moduledoc """
  Parses pages and calls a link handler to handle the detected links.
  """

  require Logger

  alias __MODULE__.{Guarder, CssParser, HtmlParser, LinkParser}
  alias Crawler.Dispatcher

  defmodule Spec do
    @moduledoc """
    Spec for defining a parser.
    """

    alias Crawler.Store.Page

    @type element :: {String.t, String.t} | {String.t, String.t, String.t, String.t}
    @type opts    :: map
    @type page    :: %Page{body: String.t}
    @type input   :: %{page: page, opts: opts}

    @callback parse(input) :: page
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

      iex> Parser.parse(%Page{
      iex>   body: "Body",
      iex>   opts: %{html_tag: "a", content_type: "text/html"}
      iex> }).body
      "Body"

      iex> Parser.parse(%Page{
      iex>   body: "<a href='http://parser/1'>Link</a>",
      iex>   opts: %{html_tag: "a", content_type: "text/html"}
      iex> }).body
      "<a href='http://parser/1'>Link</a>"

      iex> Parser.parse(%Page{
      iex>   body: "<a name='hello'>Link</a>",
      iex>   opts: %{html_tag: "a", content_type: "text/html"}
      iex> }).body
      "<a name='hello'>Link</a>"

      iex> Parser.parse(%Page{
      iex>   body: "<a href='http://parser/2' target='_blank'>Link</a>",
      iex>   opts: %{html_tag: "a", content_type: "text/html"}
      iex> }).body
      "<a href='http://parser/2' target='_blank'>Link</a>"

      iex> Parser.parse(%Page{
      iex>   body: "<a href='parser/2'>Link</a>",
      iex>   opts: %{html_tag: "a", content_type: "text/html", referrer_url: "http://hello"}
      iex> }).body
      "<a href='parser/2'>Link</a>"

      iex> Parser.parse(%Page{
      iex>   body: "<a href='../parser/2'>Link</a>",
      iex>   opts: %{html_tag: "a", content_type: "text/html", referrer_url: "http://hello"}
      iex> }).body
      "<a href='../parser/2'>Link</a>"

      iex> Parser.parse(%Page{
      iex>   body: image_file(),
      iex>   opts: %{html_tag: "img", content_type: "image/png"}
      iex> }).body
      "\#{image_file()}"
  """
  def parse(input)

  def parse({:error, reason}), do: Logger.debug(reason)
  def parse(%{body: body, opts: opts} = page) do
    parse_links(body, opts, &Dispatcher.dispatch(&1, &2))
    page
  end

  def parse_links(body, opts, link_handler) do
    opts
    |> Guarder.pass?
    |> do_parse_links(body, opts, link_handler)
  end

  defp do_parse_links(false, _body, _opts, _link_handler), do: []
  defp do_parse_links(true, body, opts, link_handler) do
    Enum.map(
      parse_file(body, opts),
      &LinkParser.parse(&1, opts, link_handler)
    )
  end

  defp parse_file(body, %{content_type: "text/css"}), do: CssParser.parse(body)
  defp parse_file(body, opts),                        do: HtmlParser.parse(body, opts)
end
