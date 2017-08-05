defmodule Crawler.Linker.Normaliser do
  alias Crawler.Linker.Pathfinder

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

      iex> Normaliser.normalise(
      iex>   "https://cool.beans:7777/parent/dir",
      iex>   "../local/page2"
      iex> )
      "cool.beans-7777/parent/local/page2"

      iex> Normaliser.normalise(
      iex>   "cool.beans:7777/parent/dir",
      iex>   "../../local/page2"
      iex> )
      "cool.beans-7777/local/page2"
  """
  def normalise(domain, link, safe \\ true)

  def normalise(domain, "../" <> link, safe) do
    depth = Crawler.Linker.Prefixer.count_depth(link, "../")

    url = domain
    |> Pathfinder.find_dir_path(safe)
    |> String.split("/")
    |> Enum.drop(-depth)
    |> Path.join

    Path.join(
      url,
      String.replace_leading(link, "../", "")
    )
  end

  def normalise(domain, link, safe) do
    link
    |> String.split("://", parts: 2)
    |> Enum.count
    |> normalised_url(link, domain)
    |> Pathfinder.find_path(safe)
  end

  defp normalised_url(2, url, _domain), do: url
  defp normalised_url(1, url, domain),  do: Path.join(domain, url)
end
