defmodule Crawler.Worker.Parser do
  alias Crawler.Worker.Fetcher

  @doc """
  ## Examples

      iex> Parser.parse(%CrawlerDB.Page{
      iex>   body: "<a href='http://example.com/'>Example</a>"
      iex> })
      :ok

      iex> Parser.parse(%CrawlerDB.Page{body: "Example"})
      :ok
  """
  def parse(%CrawlerDB.Page{body: body}) do
    body
    |> Floki.find("a")
    |> Enum.each(&parse_link/1)
  end

  def parse(_), do: nil

  defp parse_link({"a", [{"href", url}], _}) do
    Fetcher.fetch(url: url)
  end
end
