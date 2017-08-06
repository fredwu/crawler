defmodule Crawler.Linker.PathLocaliser do
  @moduledoc """
  Varies localisation methods to help tranform a link to be storeable and
  linkable offline.

  `prep_url/2` and `prep_link/2` are to be used together for constructing
  links that have been localised and therefore need an extra traversal depth.
  """

  alias Crawler.Linker.PathFinder

  @doc """
  Localises a given link so that it can be stored and linked to by other pages.

  When a page does not have a file extension (e.g. html) it is treated as the
  index page for a directory, therefore `index.html` is appended to the link.

  ## Examples

      iex> PathLocaliser.localise("http://hello.world")
      "http://hello.world/index.html"

      iex> PathLocaliser.localise("hello.world")
      "hello.world/index.html"

      iex> PathLocaliser.localise("hello.world/")
      "hello.world/index.html"

      iex> PathLocaliser.localise("hello/world")
      "hello/world/index.html"

      iex> PathLocaliser.localise("hello/world.html")
      "hello/world.html"
  """
  def localise(link) do
    link
    |> PathFinder.find_path
    |> String.split("/", trim: true)
    |> Enum.count
    |> last_segment(link)
  end

  @doc """
  Prepares a URL so that a depth is added (in this case, simply append
  "index.html" to it) when the URL needs localisation and the originating link
  traverses back to a parent depth.

  ## Examples

      iex> PathLocaliser.prep_url(
      iex>   "http://hello.world/dir/page",
      iex>   "page1"
      iex> )
      "http://hello.world/dir/page"

      iex> PathLocaliser.prep_url(
      iex>   "http://hello.world/dir/page",
      iex>   "../page1"
      iex> )
      "http://hello.world/dir/page/index.html"

      iex> PathLocaliser.prep_url(
      iex>   "http://hello.world/dir/page.html",
      iex>   "page1"
      iex> )
      "http://hello.world/dir/page.html"

      iex> PathLocaliser.prep_url(
      iex>   "http://hello.world/dir/page.html",
      iex>   "../page1"
      iex> )
      "http://hello.world/dir/page.html"
  """
  def prep_url(url, "../" <> _link), do: localise(url)
  def prep_url(url, _link),          do: url

  @doc """
  Prepares a link so that a "../" is prepended when the URL needs localisation
  and the link itself traverses back to a parent depth.

  ## Examples

      iex> PathLocaliser.prep_link(
      iex>   "http://hello.world/dir/page",
      iex> "page1"
      iex> )
      "page1"

      iex> PathLocaliser.prep_link(
      iex>   "http://hello.world/dir/page",
      iex>   "../page1"
      iex> )
      "../../page1"

      iex> PathLocaliser.prep_link(
      iex>   "http://hello.world/dir/page.html",
      iex>   "page1"
      iex> )
      "page1"

      iex> PathLocaliser.prep_link(
      iex>   "http://hello.world/dir/page.html",
      iex>   "../page1"
      iex> )
      "../page1"
  """
  def prep_link(url, link = "../" <> _) do
    url
    |> skip_localisation?
    |> preped_link(link)
  end

  def prep_link(_url, link), do: link

  defp skip_localisation?(url), do: localise(url) == url

  defp preped_link(true, link),  do: link
  defp preped_link(false, link), do: "../" <> link

  defp last_segment(1, link) do
    localise_link(false, link)
  end

  defp last_segment(_count, link) do
    link
    |> String.reverse
    |> String.split("/", parts: 2)
    |> Kernel.hd
    |> String.reverse
    |> localise_segment(link)
  end

  defp localise_segment(segment, link) do
    segment
    |> String.contains?(".")
    |> localise_link(link)
  end

  defp localise_link(true,  link), do: link
  defp localise_link(false, link), do: Path.join(link, "index.html")
end
