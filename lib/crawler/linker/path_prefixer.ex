defmodule Crawler.Linker.PathPrefixer do
  @moduledoc """
  Returns prefixes (`../`s) according to the given URL's structure.
  """

  alias Crawler.Linker.{PathFinder, PathOffliner}

  @doc """
  Returns prefixes (`../`s) according to the given URL's structure.

  ## Examples

      iex> PathPrefixer.prefix("https://hello.world/")
      "../"

      iex> PathPrefixer.prefix("https://hello.world/page.html")
      "../"

      iex> PathPrefixer.prefix("https://hello.world/page")
      "../../"

      iex> PathPrefixer.prefix("https://hello.world/dir/page.html")
      "../../"

      iex> PathPrefixer.prefix("https://hello.world/dir/page")
      "../../../"
  """
  def prefix(current_url) do
    current_url
    |> PathFinder.find_path()
    |> PathOffliner.transform()
    |> count_depth()
    |> make_prefix()
  end

  defp count_depth(string, token \\ "/") do
    (
      string
      |> String.split(token)
      |> Enum.count()
    ) - 1
  end

  defp make_prefix(depth) do
    String.duplicate("../", depth)
  end
end
