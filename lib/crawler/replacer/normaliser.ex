defmodule Crawler.Replacer.Normaliser do
  alias Crawler.Snapper

  @doc """
  ## Examples

      iex> Normaliser.normalise(
      iex>   "hello.world",
      iex>   "https://hello.world/dir/page"
      iex> )
      "hello.world/dir/page"

      iex> Normaliser.normalise(
      iex>   "cool.beans",
      iex>   "https://hello.world/dir/page"
      iex> )
      "hello.world/dir/page"

      iex> Normaliser.normalise(
      iex>   "hello.world",
      iex>   "/dir/page"
      iex> )
      "hello.world/dir/page"
  """
  def normalise(domain, url) do
    url
    |> String.split("://", parts: 2)
    |> Enum.count
    |> normalised_url(url, domain)
    |> Snapper.snap_path
  end

  defp normalised_url(2, url, _domain), do: url
  defp normalised_url(1, url, domain),  do: Path.join(domain, url)
end
