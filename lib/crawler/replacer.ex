defmodule Crawler.Replacer do
  alias Crawler.Replacer.{Prefixer, Pathfinder}
  alias Crawler.Parser

  @doc """
  ## Examples

      iex> Replacer.replace_links(
      iex>   "<a href='http://another.domain/page'></a>",
      iex>   url: "http://main.domain/dir/page",
      iex>   depth: 1,
      iex>   max_depths: 2,
      iex> )
      {:ok, "<a href='../../another.domain/page'></a>"}

      iex> Replacer.replace_links(
      iex>   "<a href='http://another.domain/dir/page'></a>",
      iex>   url: "http://main.domain/page",
      iex>   depth: 1,
      iex>   max_depths: 2,
      iex> )
      {:ok, "<a href='../another.domain/dir/page'></a>"}

      iex> Replacer.replace_links(
      iex>   "<a href='http://another.domain/dir/page'></a>",
      iex>   url: "http://main.domain/dir/page",
      iex>   depth: 1,
      iex>   max_depths: 2,
      iex> )
      {:ok, "<a href='../../another.domain/dir/page'></a>"}

      iex> Replacer.replace_links(
      iex>   "<a href='/dir/page2'></a>",
      iex>   url: "http://main.domain/dir/page",
      iex>   depth: 1,
      iex>   max_depths: 2,
      iex> )
      {:ok, "<a href='../../main.domain/dir/page2'></a>"}
  """
  def replace_links(body, opts) do
    links = Parser.parse_links(body, opts, &get_link/2)
    body  = Enum.reduce(links, body, &modify_body(&2, &1, opts[:url]))

    {:ok, body}
  end

  defp get_link({_, link}, _opts), do: link

  defp modify_body(body, link, current_url) do
    String.replace(body, link, modify_link(link, current_url))
  end

  defp modify_link(link, current_url) do
    Prefixer.prefix(current_url) <> Pathfinder.find_path(link, current_url)
  end
end
