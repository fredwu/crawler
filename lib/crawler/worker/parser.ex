defmodule Crawler.Worker.Parser do
  alias Crawler.{Worker.Dispatcher, Store, Store.Page}

  @doc """
  ## Examples

      iex> Parser.parse(%{page: %Page{body: "Body"}, opts: []})
      %Page{body: "Body"}

      iex> Parser.parse(%{page: %Page{
      iex>   body: "<a href='http://localhost/'>Link</a>"
      iex> }, opts: []})
      %Page{body: "<a href='http://localhost/'>Link</a>"}

      iex> Parser.parse(%{page: %Page{
      iex>   body: "<a href='http://localhost/' target='_blank'>Link</a>"
      iex> }, opts: []})
      %Page{body: "<a href='http://localhost/' target='_blank'>Link</a>"}
  """
  def parse(%{page: page, opts: opts}) do
    page.body
    |> Floki.find("a")
    |> Enum.each(&parse_link(&1, opts))

    page
  end

  def parse(_), do: nil

  def mark_processed(%Page{url: url}) do
    Store.processed(url)
  end

  def mark_processed(_), do: nil

  defp parse_link({"a", attrs, _}, opts) do
    attrs
    |> detect_link
    |> Dispatcher.dispatch(opts)
  end

  defp detect_link(attrs) do
    Enum.find(attrs, fn(attr) ->
      Kernel.match?({"href", _}, attr)
    end)
  end
end
