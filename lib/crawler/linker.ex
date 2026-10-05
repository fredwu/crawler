defmodule Crawler.Linker do
  @moduledoc """
  A set of high level functions for making online and offline URLs and links.
  """

  alias Crawler.Linker.PathBuilder
  alias Crawler.Linker.PathPrefixer
  alias Crawler.Linker.Snapshot
  alias Crawler.URL
  alias Crawler.URL.Percent

  @doc """
  Given the `current_link`, it works out what the offline URL should be for
  `link`.

  ## Examples

      iex> Linker.offline_url(
      iex>   "http://hello.world/dir/page",
      iex>   "page1"
      iex> )
      "http://hello.world/dir/page1/__index.html"

      iex> Linker.offline_url(
      iex>   "http://hello.world/dir/page",
      iex>   "page1.html"
      iex> )
      "http://hello.world/dir/page1.html"

      iex> Linker.offline_url(
      iex>   "http://hello.world/dir/page",
      iex>   "../page1"
      iex> )
      "http://hello.world/page1/__index.html"

      iex> Linker.offline_url(
      iex>   "http://hello.world/dir/page",
      iex>   "../page1.html"
      iex> )
      "http://hello.world/page1.html"

      iex> Linker.offline_url(
      iex>   "http://hello.world/dir/page",
      iex>   "http://thank.you/page1"
      iex> )
      "http://thank.you/page1/__index.html"

      iex> Linker.offline_url(
      iex>   "http://hello.world/dir/page",
      iex>   "http://thank.you/page1.html"
      iex> )
      "http://thank.you/page1.html"

      iex> Linker.offline_url(
      iex>   "http://hello.world/dir/page",
      iex>   "http://thank.you/"
      iex> )
      "http://thank.you/__index.html"

      iex> Linker.offline_url(
      iex>   "http://host/dir/page",
      iex>   "http://host/search?q=foo/../bar"
      iex> )
      "http://host/search/__index__q_q%3Dfoo%252f..%252fbar.html"
  """
  def offline_url(current_url, link) when is_binary(link) do
    case URL.resolve(link, current_url) do
      {:ok, target} ->
        %URI{scheme: scheme} = URI.parse(target)
        scheme <> "://" <> Snapshot.url_path(target)

      :skip ->
        link
    end
  end

  def offline_url(_current_url, link), do: link

  @doc """
  Given the `current_link`, it works out what the relative
  offline link should be for `link`.

  ## Examples

      iex> Linker.offline_link(
      iex>   "http://hello.world/dir/page",
      iex>   "page1"
      iex> )
      "../../../hello.world/dir/page1/__index.html"

      iex> Linker.offline_link(
      iex>   "http://hello.world/dir/page",
      iex>   "page1.html"
      iex> )
      "../../../hello.world/dir/page1.html"

      iex> Linker.offline_link(
      iex>   "http://hello.world/dir/page",
      iex>   "../page1"
      iex> )
      "../../../hello.world/page1/__index.html"

      iex> Linker.offline_link(
      iex>   "http://hello.world/dir/page",
      iex>   "../page1.html"
      iex> )
      "../../../hello.world/page1.html"

      iex> Linker.offline_link(
      iex>   "http://hello.world/dir/page",
      iex>   "http://thank.you/page1"
      iex> )
      "../../../thank.you/page1/__index.html"

      iex> Linker.offline_link(
      iex>   "http://hello.world/dir/page",
      iex>   "http://thank.you/page1.html"
      iex> )
      "../../../thank.you/page1.html"
  """
  def offline_link(current_url, link) when is_binary(link) do
    case URL.resolve(link, current_url) do
      {:ok, target} -> Snapshot.relative(current_url, target) <> fragment_suffix(link)
      :skip -> link
    end
  end

  def offline_link(_current_url, link), do: link

  defp fragment_suffix(link) do
    case String.split(URL.sanitize(link), "#", parts: 2) do
      [_base, fragment] -> "#" <> Percent.encode(fragment, :fragment)
      _ -> ""
    end
  end

  @doc """
  Resolves `link` against `current_url` and returns its normalized HTTP or HTTPS URL.
  Absolute targets keep their scheme. Relative and scheme-relative targets use
  the scheme of `current_url`.
  Returns unsupported or unresolved links unchanged.

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

      iex> Linker.url("http://another.domain/page", "https://other.domain/file")
      "https://other.domain/file"
  """
  def url(current_url, link) do
    case URL.resolve(link, current_url) do
      {:ok, target} -> target
      :skip -> link
    end
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
