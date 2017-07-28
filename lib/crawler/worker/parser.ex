defmodule Crawler.Worker.Parser do
  alias Crawler.{Store, Store.Page}

  @doc """
  ## Examples

      iex> Parser.parse(%Crawler.Store.Page{body: "Body"})
      %Crawler.Store.Page{body: "Body"}

      iex> Parser.parse(%Crawler.Store.Page{
      iex>   body: "<a href='http://localhost/'>Link</a>"}
      iex> )
      %Crawler.Store.Page{body: "<a href='http://localhost/'>Link</a>"}

      iex> Parser.parse(%Crawler.Store.Page{
      iex>   body: "<a href='http://localhost/' target='_blank'>Link</a>"}
      iex> )
      %Crawler.Store.Page{body: "<a href='http://localhost/' target='_blank'>Link</a>"}
  """
  def parse(%Page{body: body, url: url}) do
    body
    |> Floki.find("a")
    |> Enum.each(&parse_link/1)

    %Page{body: body, url: url}
  end

  def parse(_), do: nil

  def mark_processed(%Page{url: url}) do
    Store.processed(url)
  end

  def mark_processed(_) do; false end

  defp parse_link({"a", attrs, _}) do
    match = Enum.find(attrs, fn(attr) ->
      Kernel.match?({"href", _}, attr)
    end)

    case match do
      {_, url} -> Crawler.crawl(url)
      _        -> false
    end
  end
end
