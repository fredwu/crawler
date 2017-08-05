defmodule Crawler.Linker do
  alias Crawler.Linker.{Prefixer, Pathfinder, Normaliser}

  @doc """
  ## Examples

      iex> Linker.modify_link(
      iex>   "http://another.domain/page",
      iex>   "/dir/page2"
      iex> )
      "../another.domain/dir/page2"

      iex> Linker.modify_link(
      iex>   "http://another.domain/parent/page",
      iex>   "dir/page2"
      iex> )
      "../../another.domain/parent/dir/page2"

      iex> Linker.modify_link(
      iex>   "http://another.domain/parent/page",
      iex>   "../dir/page2"
      iex> )
      "../../another.domain/dir/page2"
  """
  def modify_link(current_url, link) do
    Path.join(
      Prefixer.prefix(current_url),
      find_full_path(current_url, link)
    )
  end

  @doc """
  ## Examples

      iex> Linker.modify_url(
      iex>   "http://another.domain:8888/page",
      iex>   "/dir/page2"
      iex> )
      "http://another.domain:8888/dir/page2"

      iex> Linker.modify_url(
      iex>   "http://another.domain:8888/parent/page",
      iex>   "dir/page2"
      iex> )
      "http://another.domain:8888/parent/dir/page2"
  """
  def modify_url(current_url, link) do
    Path.join(
      find_protocol(current_url),
      find_full_path(current_url, link, false)
    )
  end

  @doc """
  ## Examples

      iex> Linker.find_full_path(
      iex>   "https://cool.beans:7777/dir/page1",
      iex>   "https://hello.world:8888/remote/page2"
      iex> )
      "hello.world-8888/remote/page2"

      iex> Linker.find_full_path(
      iex>   "https://cool.beans:7777/dir/page1",
      iex>   "local/page2"
      iex> )
      "cool.beans-7777/dir/local/page2"

      iex> Linker.find_full_path(
      iex>   "https://cool.beans:7777/dir/page1",
      iex>   "/local/page2"
      iex> )
      "cool.beans-7777/local/page2"

      iex> Linker.find_full_path(
      iex>   "https://cool.beans:7777/parent/dir/page1",
      iex>   "../local/page2"
      iex> )
      "cool.beans-7777/parent/local/page2"

      iex> Linker.find_full_path(
      iex>   "https://cool.beans:7777/parent/dir/page1",
      iex>   "../../local/page2"
      iex> )
      "cool.beans-7777/local/page2"
  """
  def find_full_path(current_url, link, safe \\ true) do
    current_url
    |> path_prefix(link, safe)
    |> Normaliser.normalise(link, safe)
  end

  @doc """
  ## Examples

      iex> Linker.path_prefix("https://hello:8888/dir/world", "/page", true)
      "hello-8888"

      iex> Linker.path_prefix("https://hello:8888/dir/world", "page", false)
      "hello:8888/dir"
  """
  def path_prefix(url, "/" <> _link, safe), do: Pathfinder.find_domain(url, safe)
  def path_prefix(url, _link, safe),        do: Pathfinder.find_dir_path(url, safe)

  defp find_protocol(url) do
    (
      url
      |> String.split("://", part: 2)
      |> Kernel.hd
    ) <> "://"
  end
end
