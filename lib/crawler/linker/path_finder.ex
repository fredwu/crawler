defmodule Crawler.Linker.PathFinder do
  @moduledoc """
  Finds different components of a given URL, e.g. its domain name, directory
  path, or full path.

  The `safe` option indicates whether the return value should be transformed
  in order to be safely used as folder and file names.
  """

  alias Crawler.Linker.PathBuilder

  @doc """
  ## Examples

      iex> PathFinder.find_full_path(
      iex>   "https://cool.beans:7777/dir/page1",
      iex>   "https://hello.world:8888/remote/page2"
      iex> )
      "hello.world-8888/remote/page2"

      iex> PathFinder.find_full_path(
      iex>   "https://cool.beans:7777/dir/page1",
      iex>   "local/page2"
      iex> )
      "cool.beans-7777/dir/local/page2"

      iex> PathFinder.find_full_path(
      iex>   "https://cool.beans:7777/dir/page1",
      iex>   "/local/page2"
      iex> )
      "cool.beans-7777/local/page2"

      iex> PathFinder.find_full_path(
      iex>   "https://cool.beans:7777/parent/dir/page1",
      iex>   "../local/page2"
      iex> )
      "cool.beans-7777/parent/local/page2"

      iex> PathFinder.find_full_path(
      iex>   "https://cool.beans:7777/parent/dir/page1",
      iex>   "../../local/page2"
      iex> )
      "cool.beans-7777/local/page2"
  """
  def find_full_path(current_url, link, safe \\ true) do
    current_url
    |> path_prefix(link, safe)
    |> PathBuilder.build_path(link, safe)
  end

  defp path_prefix(url, "/" <> _link, safe), do: find_domain(url, safe)
  defp path_prefix(url, _link, safe),        do: find_dir_path(url, safe)

  @doc """
  ## Examples

      iex> PathFinder.find_scheme("http://hi.hello")
      "http://"

      iex> PathFinder.find_scheme("https://hi.hello:8888/")
      "https://"
  """
  def find_scheme(url) do
    (
      url
      |> String.split("://", part: 2)
      |> Kernel.hd
    ) <> "://"
  end

  @doc """
  ## Examples

      iex> PathFinder.find_domain("http://hi.hello")
      "hi.hello"

      iex> PathFinder.find_domain("https://hi.hello:8888/world")
      "hi.hello-8888"

      iex> PathFinder.find_domain("https://hi.hello:8888/world", false)
      "hi.hello:8888"
  """
  def find_domain(url, safe \\ true) do
    url
    |> find_path(safe)
    |> String.split("/", parts: 2)
    |> Kernel.hd
  end

  @doc """
  ## Examples

      iex> PathFinder.find_dir_path("http://hi.hello")
      "hi.hello"

      iex> PathFinder.find_dir_path("https://hi.hello:8888/dir/world")
      "hi.hello-8888/dir"

      iex> PathFinder.find_dir_path("https://hi.hello:8888/dir/world", false)
      "hi.hello:8888/dir"
  """
  def find_dir_path(url, safe \\ true) do
    url
    |> find_path(safe)
    |> String.split("/")
    |> return_dir_path
  end

  defp return_dir_path([path]), do: path

  defp return_dir_path(list) do
    [_head | tail] = Enum.reverse(list)

    tail
    |> Enum.reverse
    |> Path.join
  end

  @doc """
  ## Examples

      iex> PathFinder.find_path("http://hi.hello")
      "hi.hello"

      iex> PathFinder.find_path("https://hi.hello:8888/world")
      "hi.hello-8888/world"

      iex> PathFinder.find_path("https://hi.hello:8888/world", false)
      "hi.hello:8888/world"
  """
  def find_path(url, safe \\ true)

  def find_path(url, false) do
    url
    |> String.split("://", parts: 2)
    |> Enum.at(-1)
  end

  def find_path(url, true) do
    url
    |> find_path(false)
    |> String.replace(":", "-")
  end
end
