defmodule Crawler.Replacer do
  alias Crawler.{Parser, Snapper, Replacer.Normaliser}

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

  defp get_link({_, url}, _opts), do: url

  defp modify_body(body, url, current_url) do
    String.replace(body, url, modify_link(url, current_url))
  end

  defp modify_link(url, current_url) do
    link_prefix(current_url) <> link_path(url, current_url)
  end

  defp link_prefix(current_url) do
    current_url
    |> Snapper.snap_path
    |> count_depth
    |> make_prefix
  end

  defp count_depth(string) do
    string
    |> String.graphemes
    |> Enum.filter(& &1 == "/")
    |> Enum.count
  end

  defp make_prefix(depth) do
    String.duplicate("../", depth)
  end

  defp link_path(url, current_url) do
    current_url
    |> Snapper.snap_domain
    |> Normaliser.normalise(url)
  end
end
