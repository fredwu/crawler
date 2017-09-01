defmodule Crawler.Linker.PathOffliner do
  @moduledoc """
  Transforms a link to be storeable and linkable offline.
  """

  alias Crawler.Linker.PathFinder

  @doc """
  Transforms a given link so that it can be stored and linked to by other pages.

  When a page does not have a file extension (e.g. html) it is treated as the
  index page for a directory, therefore `index.html` is appended to the link.

  ## Examples

      iex> PathOffliner.transform("http://hello.world")
      "http://hello.world/index.html"

      iex> PathOffliner.transform("hello.world")
      "hello.world/index.html"

      iex> PathOffliner.transform("hello.world/")
      "hello.world/index.html"

      iex> PathOffliner.transform("hello/world")
      "hello/world/index.html"

      iex> PathOffliner.transform("hello/world.html")
      "hello/world.html"
  """
  def transform(link) do
    link
    |> PathFinder.find_path()
    |> String.split("/", trim: true)
    |> Enum.count()
    |> last_segment(link)
  end

  defp last_segment(1, link) do
    transform_link(false, link)
  end

  defp last_segment(_count, link) do
    link
    |> String.split("/")
    |> Enum.take(-1)
    |> Kernel.hd()
    |> transform_segment(link)
  end

  defp transform_segment(segment, link) do
    segment
    |> String.contains?(".")
    |> transform_link(link)
  end

  defp transform_link(true,  link), do: link
  defp transform_link(false, link), do: Path.join(link, "index.html")
end
