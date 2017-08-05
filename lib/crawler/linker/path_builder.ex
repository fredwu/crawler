defmodule Crawler.Linker.PathBuilder do
  alias Crawler.Linker.{PathFinder, Prefixer}

  @doc """
  ## Examples

      iex> PathBuilder.build_path(
      iex>   "hello.world",
      iex>   "https://hello.world/dir/page"
      iex> )
      "hello.world/dir/page"

      iex> PathBuilder.build_path(
      iex>   "cool.beans",
      iex>   "https://hello.world/dir/page"
      iex> )
      "hello.world/dir/page"

      iex> PathBuilder.build_path(
      iex>   "hello.world",
      iex>   "/dir/page"
      iex> )
      "hello.world/dir/page"

      iex> PathBuilder.build_path(
      iex>   "https://cool.beans:7777/parent/dir",
      iex>   "../local/page2"
      iex> )
      "cool.beans-7777/parent/local/page2"

      iex> PathBuilder.build_path(
      iex>   "cool.beans:7777/parent/dir",
      iex>   "../../local/page2"
      iex> )
      "cool.beans-7777/local/page2"
  """
  def build_path(input, link, safe \\ true)

  def build_path(input, "../" <> link, safe) do
    input
    |> PathFinder.find_dir_path(safe)
    |> remove_relative_segments(link)
    |> join_link_path(link)
  end

  def build_path(input, link, safe) do
    link
    |> String.split("://", parts: 2)
    |> Enum.count
    |> normalise_link(link, input)
    |> PathFinder.find_path(safe)
  end

  defp remove_relative_segments(input, link) do
    depth = Prefixer.count_depth(link, "../")

    input
    |> String.split("/")
    |> Enum.drop(-depth)
    |> Path.join
  end

  defp join_link_path(url, link) do
    Path.join(url, String.replace_leading(link, "../", ""))
  end

  defp normalise_link(2, link, _input), do: link
  defp normalise_link(1, link, input),  do: Path.join(input, link)
end
