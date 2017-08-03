defmodule Crawler.Parser do
  alias Crawler.{Dispatcher, Store, Store.Page}

  @doc """
  ## Examples

      iex> Parser.parse(%{page: %Page{body: "Body"}, opts: []})
      %Page{body: "Body"}

      iex> Parser.parse(%{page: %Page{
      iex>   body: "<a href='http://parser/1'>Link</a>"
      iex> }, opts: []})
      %Page{body: "<a href='http://parser/1'>Link</a>"}

      iex> Parser.parse(%{page: %Page{
      iex>   body: "<a href='http://parser/2' target='_blank'>Link</a>"
      iex> }, opts: []})
      %Page{body: "<a href='http://parser/2' target='_blank'>Link</a>"}
  """
  def parse(page, link_handler \\ &Dispatcher.dispatch(&1, &2))

  def parse(%{page: page, opts: opts}, link_handler) do
    parse_links(page.body, opts, link_handler)

    page
  end

  def parse(_, _), do: nil

  def parse_links(body, opts, link_handler) do
    body
    |> Floki.find("a")
    |> Enum.map(&parse_link(&1, opts, link_handler))
  end

  def mark_processed(%Page{url: url}) do
    Store.processed(url)
  end

  def mark_processed(_), do: nil

  defp parse_link({"a", attrs, _}, opts, link_handler) do
    attrs
    |> detect_link
    |> link_handler.(opts)
  end

  defp detect_link(attrs) do
    Enum.find(attrs, fn(attr) ->
      Kernel.match?({"href", _}, attr)
    end)
  end
end
