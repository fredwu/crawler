defmodule Crawler.Linker do
  @moduledoc """
  Resolves online HTTP and HTTPS URLs with url/2.

  Managed exports allocate response-aware artifact paths from successful resource
  records. Standalone saves return their acknowledged artifact path. A URL alone
  does not identify a saved artifact.

  The URL-derived offline_url/2 and offline_link/2 APIs and the Snapshot,
  PathOffliner, and PathFinder helpers have been removed. There is no legacy
  naming mode.
  """

  alias Crawler.URL

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
end
