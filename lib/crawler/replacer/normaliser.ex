defmodule Crawler.Replacer.Normaliser do
  alias Crawler.Snapper

  @doc """
  ## Examples

      iex> Normaliser.normalise(
      iex>   "https://hello.world/dir/page",
      iex>   "hello.world"
      iex> )
      "hello.world/dir/page"

      iex> Normaliser.normalise(
      iex>   "https://hello.world/dir/page",
      iex>   "cool.beans"
      iex> )
      "hello.world/dir/page"

      iex> Normaliser.normalise(
      iex>   "/dir/page",
      iex>   "hello.world"
      iex> )
      "hello.world/dir/page"
  """
  def normalise(url, domain) do
    url
    |> String.split("://", parts: 2)
    |> Enum.count
    |> normalised_url(url, domain)
    |> Snapper.snap_path
  end

  defp normalised_url(2, url, _domain), do: url
  defp normalised_url(1, url, domain),  do: Path.join(domain, url)
end
