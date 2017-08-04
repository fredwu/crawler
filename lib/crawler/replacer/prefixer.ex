defmodule Crawler.Replacer.Prefixer do
  alias Crawler.Snapper

  @doc """
  ## Examples

      iex> Prefixer.prefix("https://hello.world/")
      "../"

      iex> Prefixer.prefix("https://hello.world/page")
      "../"

      iex> Prefixer.prefix("https://hello.world/dir/page")
      "../../"
  """
  def prefix(current_url) do
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
end
