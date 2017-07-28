defmodule Crawler.Worker.Parser do
  alias Crawler.{Store, Store.Page}

  @doc """
  ## Examples

      iex> Parser.parse(%Crawler.Store.Page{
      iex>   body: "<a href='http://example.com/'>Example</a>"}
      iex> )
      %Crawler.Store.Page{body: "<a href='http://example.com/'>Example</a>"}

      iex> Parser.parse(%Crawler.Store.Page{body: "Example"})
      %Crawler.Store.Page{body: "Example"}
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

  defp parse_link({"a", [{"href", url}], _}) do
    Crawler.crawl(url)
  end
end
