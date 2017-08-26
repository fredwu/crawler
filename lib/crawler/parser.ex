defmodule Crawler.Parser do
  @moduledoc """
  Parses pages and calls a link handler to handle the detected links.
  """

  require Logger

  alias __MODULE__.{CssParser, HtmlParser, LinkParser}
  alias Crawler.{Worker, Dispatcher}

  defmodule Spec do
    @moduledoc """
    Spec for defining a parser.
    """

    alias Crawler.Store.Page

    @type element      :: {String.t, String.t} | {String.t, String.t, String.t, String.t}
    @type opts         :: map
    @type page         :: %Page{body: String.t}
    @type input        :: %{page: page, opts: opts}
    @type link_handler :: (element, opts -> term)

    @callback parse(input, link_handler) :: page
    @callback parse({:error, term}, link_handler) :: :ok
  end

  @behaviour __MODULE__.Spec

  @doc """
  ## Examples

      iex> Parser.parse(%{page: %Page{
      iex>   body: "Body"
      iex> }, opts: %{html_tag: "a"}})
      %Page{body: "Body"}

      iex> Parser.parse(%{page: %Page{
      iex>   body: "<a href='http://parser/1'>Link</a>"
      iex> }, opts: %{html_tag: "a"}})
      %Page{body: "<a href='http://parser/1'>Link</a>"}

      iex> Parser.parse(%{page: %Page{
      iex>   body: "<a name='hello'>Link</a>"
      iex> }, opts: %{html_tag: "a"}})
      %Page{body: "<a name='hello'>Link</a>"}

      iex> Parser.parse(%{page: %Page{
      iex>   body: "<a href='http://parser/2' target='_blank'>Link</a>"
      iex> }, opts: %{html_tag: "a"}})
      %Page{body: "<a href='http://parser/2' target='_blank'>Link</a>"}

      iex> Parser.parse(%{page: %Page{
      iex>   body: "<a href='parser/2'>Link</a>"
      iex> }, opts: %{html_tag: "a", referrer_url: "http://hello"}})
      %Page{body: "<a href='parser/2'>Link</a>"}

      iex> Parser.parse(%{page: %Page{
      iex>   body: "<a href='../parser/2'>Link</a>"
      iex> }, opts: %{html_tag: "a", referrer_url: "http://hello"}})
      %Page{body: "<a href='../parser/2'>Link</a>"}

      iex> Parser.parse(%{page: %Page{
      iex>   body: image_file()
      iex> }, opts: %{html_tag: "img"}})
      %Page{body: "\#{image_file()}"}
  """
  def parse(input, link_handler \\ &Dispatcher.dispatch(&1, &2))

  def parse(%{page: page, opts: opts}, link_handler) do
    if Worker.actionable?(opts) do
      parse_links(page.body, opts, link_handler)
    end

    page
  end

  def parse({:error, reason}, _), do: Logger.debug(reason)

  def parse_links(body, opts, link_handler) do
    Enum.map(
      parse_file(body, opts),
      &LinkParser.parse(&1, opts, link_handler)
    )
  end

  defp parse_file(body, %{file_type: "css"}), do: CssParser.parse(body)
  defp parse_file(body, opts),                do: HtmlParser.parse(body, opts)
end
