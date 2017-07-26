defmodule Crawler.Worker.Parser do
  alias Crawler.{Worker.Fetcher, Store.Page}

  @doc """
  ## Examples

      iex> Parser.parse(%Crawler.Store.Page{
      iex>   body: "<a href='http://example.com/'>Example</a>"}
      iex> )
      :ok

      iex> Parser.parse(%Crawler.Store.Page{body: "Example"})
      :ok
  """
  def parse(%Page{body: body}) do
    body
    |> Floki.find("a")
    |> Enum.each(&parse_link/1)
  end

  def parse(_), do: nil

  defp parse_link({"a", [{"href", url}], _}) do
    Fetcher.fetch(url: url)
  end
end
