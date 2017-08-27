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

  def parse({:error, reason}, _), do: Logger.debug(reason)
  def parse(%{page: page, opts: opts}, link_handler) do
    parse_links(page.body, opts, link_handler)
    page
  end

  def parse_links(body, opts, link_handler) do
    do_parse_links(Guarder.pass?(opts), body, opts, link_handler)
  end

  defp do_parse_links(false, _body, _opts, _link_handler), do: []
  defp do_parse_links(true, body, opts, link_handler) do
    Enum.map(
      parse_file(body, opts),
      &LinkParser.parse(&1, opts, link_handler)
    )
  end

  defp parse_file(body, %{file_type: "css"}), do: CssParser.parse(body)
  defp parse_file(body, opts),                do: HtmlParser.parse(body, opts)
end
