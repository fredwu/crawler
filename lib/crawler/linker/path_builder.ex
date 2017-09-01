defmodule Crawler.Linker.PathBuilder do
  @moduledoc """
  Builds a path for a link (can be a URL itself or a relative link) based on
  the input string which is a URL with or without its protocol.
  """

  alias Crawler.Linker.{PathFinder, PathExpander}

  @doc """
  Builds a path for a link (can be a URL itself or a relative link) based on
  the input string which is a URL with or without its protocol.

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
    |> base_path(link, safe)
    |> build(link, safe)
  end

  defp base_path(url, "/" <> _link, safe), do: PathFinder.find_domain(url, safe)
  defp base_path(url, _link, safe),        do: PathFinder.find_base_path(url, safe)

  defp build(path, link, safe) do
    link
    |> normalise(path)
    |> PathFinder.find_path(safe)
    |> PathExpander.expand_dot()
  end

  defp normalise(link, path) do
    link
    |> String.split("://", parts: 2)
    |> Enum.count()
    |> join_path(link, path)
  end

  defp join_path(2, link, _path), do: link
  defp join_path(1, link, path),  do: Path.join(path, link)
end
