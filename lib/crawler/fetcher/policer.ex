defmodule Crawler.Fetcher.Policer do
  alias Crawler.Store

  @doc """
  ## Examples

      iex> Policer.police([depth: 1, max_depths: 2, url: "http://policer/"])
      {:ok, [depth: 1, max_depths: 2, url: "http://policer/"]}

      iex> Crawler.Store.add("http://policer/exist/")
      iex> Policer.police([depth: 1, max_depths: 2, url: "http://policer/exist/"])
      {:error, "Not allowed to fetch with opts: [depth: 1, max_depths: 2, url: \\\"http://policer/exist/\\\"]."}

      iex> Policer.police([depth: 2, max_depths: 2])
      {:error, "Not allowed to fetch with opts: [depth: 2, max_depths: 2]."}
  """
  def police(opts) do
    with true <- within_fetch_depth?(opts),
         true <- not_fetched_yet?(opts)
    do
      {:ok, opts}
    else
      _ -> police_error(opts)
    end
  end

  defp within_fetch_depth?(opts) do
    opts[:depth] < opts[:max_depths]
  end

  defp not_fetched_yet?(opts) do
    !Store.find(opts[:url])
  end

  defp police_error(opts) do
    {:error, "Not allowed to fetch with opts: #{Kernel.inspect(opts)}."}
  end
end
