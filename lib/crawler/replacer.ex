defmodule Crawler.Replacer do
  alias Crawler.{Parser, Fetcher.Snapper}

  @doc """
  ## Examples

      iex> Replacer.replace_links(
      iex>   "<a href='http://another.domain/page'></a>",
      iex>   url: "http://main.domain/dir/page",
      iex>   level: 1,
      iex>   max_levels: 2,
      iex> )
      {:ok, "<a href='../another.domain/page'></a>"}

      iex> Replacer.replace_links(
      iex>   "<a href='http://another.domain/dir/page'></a>",
      iex>   url: "http://main.domain/page",
      iex>   level: 1,
      iex>   max_levels: 2,
      iex> )
      {:ok, "<a href='another.domain/dir/page'></a>"}

      iex> Replacer.replace_links(
      iex>   "<a href='http://another.domain/dir/page'></a>",
      iex>   url: "http://main.domain/dir/page",
      iex>   level: 1,
      iex>   max_levels: 2,
      iex> )
      {:ok, "<a href='../another.domain/dir/page'></a>"}
  """
  def replace_links(body, opts) do
    links = Parser.parse_links(body, opts, &get_link/2)
    body  = Enum.reduce(links, body, &modify_body(&2, &1, opts[:url]))

    {:ok, body}
  end

  defp get_link({_, url}, _opts) do
    url
  end

  defp modify_body(body, link, current_url) do
    String.replace(body, link, modify_link(link, current_url))
  end

  defp modify_link(link, current_url) do
    current_depth = current_url |> Snapper.snap_path |> count_depth

    prefix = String.duplicate("../", current_depth - 1)

    "#{prefix}#{Snapper.snap_path(link)}"
  end

  defp count_depth(string) do
    string
    |> String.graphemes
    |> Enum.filter(& &1 == "/")
    |> Enum.count
  end
end
