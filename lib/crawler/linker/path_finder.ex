defmodule Crawler.Linker.PathFinder do
  @doc """
  ## Examples

      iex> PathFinder.find_domain("http://hello")
      "hello"

      iex> PathFinder.find_domain("https://hello:8888/world")
      "hello-8888"
  """
  def find_domain(url, safe \\ true) do
    url
    |> find_path(safe)
    |> String.split("/", parts: 2)
    |> Kernel.hd
  end

  @doc """
  ## Examples

      iex> PathFinder.find_dir_path("http://hello")
      "hello"

      iex> PathFinder.find_dir_path("https://hello:8888/dir/world")
      "hello-8888/dir"
  """
  def find_dir_path(url, safe \\ true) do
    url
    |> find_path(safe)
    |> String.reverse
    |> String.split("/", parts: 2)
    |> Enum.at(-1)
    |> String.reverse
  end

  @doc """
  ## Examples

      iex> PathFinder.find_path("http://hello")
      "hello"

      iex> PathFinder.find_path("https://hello:8888/world")
      "hello-8888/world"
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
