defmodule Crawler.Linker.Prefixer do
  @moduledoc """
  Returns prefixes ("../") according to the given URL's structure.
  """

  alias Crawler.Linker.{PathFinder, PathOffliner}

  @doc """
  ## Examples

      iex> Prefixer.prefix("https://hello.world/")
      "../"

      iex> Prefixer.prefix("https://hello.world/page.html")
      "../"

      iex> Prefixer.prefix("https://hello.world/page")
      "../../"

      iex> Prefixer.prefix("https://hello.world/dir/page.html")
      "../../"

      iex> Prefixer.prefix("https://hello.world/dir/page")
      "../../../"
  """
  def prefix(current_url) do
    current_url
    |> PathFinder.find_path
    |> PathOffliner.transform
    |> count_depth
    |> make_prefix
  end

  defp count_depth(string, token \\ "/") do
    (
      string
      |> String.split(token)
      |> Enum.count
    ) - 1
  end

  defp make_prefix(depth) do
    String.duplicate("../", depth)
  end
end
