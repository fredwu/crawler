defmodule Crawler.Replacer.Pathfinder do
  alias Crawler.{Snapper, Replacer.Normaliser}

  @doc """
  ## Examples

      iex> Pathfinder.find_path(
      iex>   "https://hello.world:8888/remote/dir",
      iex>   "https://cool.beans:7777/dir"
      iex> )
      "hello.world-8888/remote/dir"

      iex> Pathfinder.find_path(
      iex>   "local/dir",
      iex>   "https://cool.beans:7777/dir"
      iex> )
      "cool.beans-7777/local/dir"
  """
  def find_path(link, current_url) do
    current_url
    |> Snapper.snap_domain
    |> Normaliser.normalise(link)
  end
end
