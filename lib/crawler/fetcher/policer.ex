defmodule Crawler.Fetcher.Policer do
  @moduledoc """
  Checks a series of conditions to determine whether it is okay to continue,
  i.e. to allow `Crawler.Fetcher.fetch/1` to begin its tasks.
  """

  alias Crawler.Store

  @uri_schemes ["http", "https"]

  @doc """
  ## Examples

      iex> Policer.police([depth: 1, max_depths: 2, url: "http://policer/"])
      {:ok, [depth: 1, max_depths: 2, url: "http://policer/"]}

      iex> Policer.police([depth: 2, max_depths: 2])
      {:error, "Fetch failed 'within_fetch_depth?', with opts: [depth: 2, max_depths: 2]."}

      iex> Policer.police([depth: 1, max_depths: 2, url: "ftp://hello.world"])
      {:error, "Fetch failed 'acceptable_uri_scheme?', with opts: [depth: 1, max_depths: 2, url: \\\"ftp://hello.world\\\"]."}

      iex> Crawler.Store.add("http://policer/exist/")
      iex> Policer.police([depth: 1, max_depths: 2, url: "http://policer/exist/"])
      {:error, "Fetch failed 'not_fetched_yet?', with opts: [depth: 1, max_depths: 2, url: \\\"http://policer/exist/\\\"]."}
  """
  def police(opts) do
    with {_, true} <- within_fetch_depth?(opts),
         {_, true} <- acceptable_uri_scheme?(opts),
         {_, true} <- not_fetched_yet?(opts)
    do
      {:ok, opts}
    else
      {fail_type, _} -> police_error(fail_type, opts)
    end
  end

  defp within_fetch_depth?(opts) do
    {:within_fetch_depth?, opts[:depth] < opts[:max_depths]}
  end

  defp acceptable_uri_scheme?(opts) do
    scheme = opts[:url]
    |> String.split("://", parts: 2)
    |> Kernel.hd

    {:acceptable_uri_scheme?, Enum.member?(@uri_schemes, scheme)}
  end

  defp not_fetched_yet?(opts) do
    {:not_fetched_yet?, !Store.find(opts[:url])}
  end

  defp police_error(fail_type, opts) do
    {:error, "Fetch failed '#{fail_type}', with opts: #{Kernel.inspect(opts)}."}
  end
end
