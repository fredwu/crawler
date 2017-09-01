defmodule Crawler.Linker.PathFinder do
  @moduledoc """
  Finds different components of a given URL, e.g. its domain name, directory
  path, or full path.

  The `safe` option in some the functions indicates whether the return value
  should be transformed in order to be safely used as folder and file names.
  """

  @doc """
  Finds the URL scheme (e.g. `https://`).

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
      |> Kernel.hd()
    ) <> "://"
  end

  @doc """
  Finds the domain name with port number (e.g. `example.org:8080`).

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
    |> Kernel.hd()
  end

  @doc """
  Finds the base path of a given page.

  ## Examples

      iex> PathFinder.find_base_path("http://hi.hello")
      "hi.hello"

      iex> PathFinder.find_base_path("https://hi.hello:8888/dir/world")
      "hi.hello-8888/dir"

      iex> PathFinder.find_base_path("https://hi.hello:8888/dir/world", false)
      "hi.hello:8888/dir"
  """
  def find_base_path(url, safe \\ true) do
    url
    |> find_path(safe)
    |> String.split("/")
    |> base_path
  end

  defp base_path([path]), do: path

  defp base_path(list) do
    [_head | tail] = Enum.reverse(list)

    tail
    |> Enum.reverse()
    |> Path.join()
  end

  @doc """
  Finds the full path of a given page.

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
