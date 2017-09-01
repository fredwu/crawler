defmodule Crawler.Linker do
  @moduledoc """
  A set of high level functions for making online and offline URLs and links.
  """

  alias __MODULE__.{PathPrefixer, PathBuilder, PathFinder, PathOffliner}

  @doc """
  Given the `current_link`, it works out what the offline URL should be for
  `link`.

  ## Examples

      iex> Linker.offline_url(
      iex>   "http://hello.world/dir/page",
      iex>   "page1"
      iex> )
      "http://hello.world/dir/page1/index.html"

      iex> Linker.offline_url(
      iex>   "http://hello.world/dir/page",
      iex>   "page1.html"
      iex> )
      "http://hello.world/dir/page1.html"

      iex> Linker.offline_url(
      iex>   "http://hello.world/dir/page",
      iex>   "../page1"
      iex> )
      "http://hello.world/page1/index.html"

      iex> Linker.offline_url(
      iex>   "http://hello.world/dir/page",
      iex>   "../page1.html"
      iex> )
      "http://hello.world/page1.html"

      iex> Linker.offline_url(
      iex>   "http://hello.world/dir/page",
      iex>   "http://thank.you/page1"
      iex> )
      "http://thank.you/page1/index.html"

      iex> Linker.offline_url(
      iex>   "http://hello.world/dir/page",
      iex>   "http://thank.you/page1.html"
      iex> )
      "http://thank.you/page1.html"

      iex> Linker.offline_url(
      iex>   "http://hello.world/dir/page",
      iex>   "http://thank.you/"
      iex> )
      "http://thank.you/index.html"
  """
  def offline_url(current_url, link) do
    current_url
    |> url(link)
    |> PathOffliner.transform()
  end

  @doc """
  Given the `current_link`, it works out what the relative
  offline link should be for `link`.

  ## Examples

      iex> Linker.offline_link(
      iex>   "http://hello.world/dir/page",
      iex>   "page1"
      iex> )
      "../../../hello.world/dir/page1/index.html"

      iex> Linker.offline_link(
      iex>   "http://hello.world/dir/page",
      iex>   "page1.html"
      iex> )
      "../../../hello.world/dir/page1.html"

      iex> Linker.offline_link(
      iex>   "http://hello.world/dir/page",
      iex>   "../page1"
      iex> )
      "../../../hello.world/page1/index.html"

      iex> Linker.offline_link(
      iex>   "http://hello.world/dir/page",
      iex>   "../page1.html"
      iex> )
      "../../../hello.world/page1.html"

      iex> Linker.offline_link(
      iex>   "http://hello.world/dir/page",
      iex>   "http://thank.you/page1"
      iex> )
      "../../../thank.you/page1/index.html"

      iex> Linker.offline_link(
      iex>   "http://hello.world/dir/page",
      iex>   "http://thank.you/page1.html"
      iex> )
      "../../../thank.you/page1.html"
  """
  def offline_link(current_url, link) do
    current_url
    |> link(link)
    |> PathOffliner.transform()
  end

  @doc """
  Given the `current_link`, it works out what the URL should be for `link`.

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
      PathFinder.find_scheme(current_url),
      PathBuilder.build_path(current_url, link, false)
    )
  end

  @doc """
  Given the `current_link`, it works out what the relative link should be for
  `link`.

  ## Examples

      iex> Linker.link(
      iex>   "http://another.domain/page.html",
      iex>   "/dir/page2"
      iex> )
      "../another.domain/dir/page2"

      iex> Linker.link(
      iex>   "http://another.domain/page",
      iex>   "/dir/page2"
      iex> )
      "../../another.domain/dir/page2"

      iex> Linker.link(
      iex>   "http://another.domain/parent/page",
      iex>   "dir/page2"
      iex> )
      "../../../another.domain/parent/dir/page2"

      iex> Linker.link(
      iex>   "http://another.domain/parent/page",
      iex>   "../dir/page2"
      iex> )
      "../../../another.domain/dir/page2"
  """
  def link(current_url, link) do
    Path.join(
      PathPrefixer.prefix(current_url),
      PathBuilder.build_path(current_url, link)
    )
  end
end
