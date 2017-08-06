defmodule Crawler.Linker do
  alias Crawler.Linker.{Prefixer, PathFinder, PathBuilder, PathLocaliser}

  @doc """
  ## Examples

      iex> Linker.localised_url(
      iex>   "http://hello.world/dir/page",
      iex>   "page1"
      iex> )
      "http://hello.world/dir/page1/index.html"

      iex> Linker.localised_url(
      iex>   "http://hello.world/dir/page",
      iex>   "page1.html"
      iex> )
      "http://hello.world/dir/page1.html"

      iex> Linker.localised_url(
      iex>   "http://hello.world/dir/page",
      iex>   "../page1"
      iex> )
      "http://hello.world/page1/index.html"

      iex> Linker.localised_url(
      iex>   "http://hello.world/dir/page",
      iex>   "../page1.html"
      iex> )
      "http://hello.world/page1.html"

      iex> Linker.localised_url(
      iex>   "http://hello.world/dir/page",
      iex>   "http://thank.you/page1"
      iex> )
      "http://thank.you/page1/index.html"

      iex> Linker.localised_url(
      iex>   "http://hello.world/dir/page",
      iex>   "http://thank.you/page1.html"
      iex> )
      "http://thank.you/page1.html"

      iex> Linker.localised_url(
      iex>   "http://hello.world/dir/page",
      iex>   "http://thank.you/"
      iex> )
      "http://thank.you/index.html"
  """
  def localised_url(current_url, link) do
    current_url
    |> url(link)
    |> PathLocaliser.localise
  end

  @doc """
  ## Examples

      iex> Linker.localised_link(
      iex>   "http://hello.world/dir/page",
      iex>   "page1"
      iex> )
      "../../hello.world/dir/page1/index.html"

      iex> Linker.localised_link(
      iex>   "http://hello.world/dir/page",
      iex>   "page1.html"
      iex> )
      "../../hello.world/dir/page1.html"

      iex> Linker.localised_link(
      iex>   "http://hello.world/dir/page",
      iex>   "../page1"
      iex> )
      "../../../hello.world/page1/index.html"

      iex> Linker.localised_link(
      iex>   "http://hello.world/dir/page",
      iex>   "../page1.html"
      iex> )
      "../../../hello.world/page1.html"

      iex> Linker.localised_link(
      iex>   "http://hello.world/dir/page",
      iex>   "http://thank.you/page1"
      iex> )
      "../../thank.you/page1/index.html"

      iex> Linker.localised_link(
      iex>   "http://hello.world/dir/page",
      iex>   "http://thank.you/page1.html"
      iex> )
      "../../thank.you/page1.html"
  """
  def localised_link(current_url, link) do
    with link        <- PathLocaliser.prep_link(current_url, link),
         current_url <- PathLocaliser.prep_url(current_url, link),
         current_url <- link(current_url, link)
    do
      PathLocaliser.localise(current_url)
    end
  end

  @doc """
  ## Examples

      iex> Linker.url(
      iex>   "http://another.domain:8888/page",
      iex>   "/dir/page2"
      iex> )
      "http://another.domain:8888/dir/page2"

      iex> Linker.url(
      iex>   "http://another.domain:8888/parent/page",
      iex>   "dir/page2"
      iex> )
      "http://another.domain:8888/parent/dir/page2"
  """
  def url(current_url, link) do
    Path.join(
      find_protocol(current_url),
      find_full_path(current_url, link, false)
    )
  end

  @doc """
  ## Examples

      iex> Linker.link(
      iex>   "http://another.domain/page",
      iex>   "/dir/page2"
      iex> )
      "../another.domain/dir/page2"

      iex> Linker.link(
      iex>   "http://another.domain/parent/page",
      iex>   "dir/page2"
      iex> )
      "../../another.domain/parent/dir/page2"

      iex> Linker.link(
      iex>   "http://another.domain/parent/page",
      iex>   "../dir/page2"
      iex> )
      "../../another.domain/dir/page2"
  """
  def link(current_url, link) do
    Path.join(
      Prefixer.prefix(current_url),
      find_full_path(current_url, link)
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
    |> PathBuilder.build_path(link, safe)
  end

  @doc """
  ## Examples

      iex> Linker.path_prefix("https://hello:8888/dir/world", "/page", true)
      "hello-8888"

      iex> Linker.path_prefix("https://hello:8888/dir/world", "page", false)
      "hello:8888/dir"
  """
  def path_prefix(url, "/" <> _link, safe), do: PathFinder.find_domain(url, safe)
  def path_prefix(url, _link, safe),        do: PathFinder.find_dir_path(url, safe)

  defp find_protocol(url) do
    (
      url
      |> String.split("://", part: 2)
      |> Kernel.hd
    ) <> "://"
  end
end
