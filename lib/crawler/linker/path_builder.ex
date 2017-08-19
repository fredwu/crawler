defmodule Crawler.Linker.PathBuilder do
  @moduledoc """
  Builds a path for a link (can be a URL itself or a relative link) based on
  the input string which is a URL with or without its protocol.
  """

  alias Crawler.Linker.PathFinder

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

  def build_path(input, link = "../" <> _, safe) do
    input      = PathFinder.find_path(input, safe)
    {:ok, cwd} = File.cwd

    link
    |> Path.expand(input)
    |> Path.relative_to(cwd)
  end

  def build_path(input, link, safe) do
    link
    |> String.split("://", parts: 2)
    |> Enum.count
    |> normalise_link(link, input)
    |> PathFinder.find_path(safe)
  end

  defp normalise_link(2, link, _input), do: link
  defp normalise_link(1, link, input),  do: Path.join(input, link)
end
