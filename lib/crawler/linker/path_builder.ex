defmodule Crawler.Linker.PathBuilder do
  @moduledoc """
  Builds a path for a link (can be a URL itself or a relative link) based on
  the input string which is a URL with or without its protocol.
  """

  alias Crawler.Linker.PathFinder

  @doc """
  ## Examples

      iex> PathBuilder.build_path(
      iex>   "https://cool.beans:7777/dir/page1",
      iex>   "https://hello.world:8888/remote/page2"
      iex> )
      "hello.world-8888/remote/page2"

      iex> PathBuilder.build_path(
      iex>   "https://cool.beans:7777/dir/page1",
      iex>   "local/page2"
      iex> )
      "cool.beans-7777/dir/local/page2"

      iex> PathBuilder.build_path(
      iex>   "https://cool.beans:7777/dir/page1",
      iex>   "/local/page2"
      iex> )
      "cool.beans-7777/local/page2"

      iex> PathBuilder.build_path(
      iex>   "https://cool.beans:7777/parent/dir/page1",
      iex>   "../local/page2"
      iex> )
      "cool.beans-7777/parent/local/page2"

      iex> PathBuilder.build_path(
      iex>   "https://cool.beans:7777/parent/dir/page1",
      iex>   "../../local/page2"
      iex> )
      "cool.beans-7777/local/page2"
  """
  def build_path(current_url, link, safe \\ true) do
    current_url
    |> prefix_path(link, safe)
    |> build(link, safe)
  end

  defp prefix_path(url, "/" <> _link, safe), do: PathFinder.find_domain(url, safe)
  defp prefix_path(url, _link, safe),        do: PathFinder.find_base_path(url, safe)

  defp build(input, link = "../" <> _, safe) do
    input      = PathFinder.find_path(input, safe)
    {:ok, cwd} = File.cwd

    link
    |> Path.expand(input)
    |> Path.relative_to(cwd)
  end

  defp build(input, link, safe) do
    link
    |> String.split("://", parts: 2)
    |> Enum.count
    |> normalise_link(link, input)
    |> PathFinder.find_path(safe)
  end

  defp normalise_link(2, link, _input), do: link
  defp normalise_link(1, link, input),  do: Path.join(input, link)
end
