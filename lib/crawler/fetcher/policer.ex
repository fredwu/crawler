defmodule Crawler.Fetcher.Policer do
  @moduledoc """
  Checks a series of conditions to determine whether it is okay to continue.
  """

  alias Crawler.Store

  @uri_schemes       ["http", "https"]
  @asset_extra_depth 2

  @doc """
  Checks a series of conditions to determine whether it is okay to continue,
  i.e. to allow `Crawler.Fetcher.fetch/1` to begin its tasks.

  ## Examples

      iex> Policer.police([
      iex>   depth: 1,
      iex>   max_depths: 2,
      iex>   url: "http://policer/",
      iex>   url_filter: UrlFilter
      iex> ])
      {:ok, [depth: 1, max_depths: 2, url: "http://policer/", url_filter: UrlFilter]}

      iex> Policer.police([
      iex>   depth: 2,
      iex>   max_depths: 2,
      iex>   html_tag: "a"
      iex> ])
      {:error, "Fetch failed 'within_fetch_depth?', with opts: [depth: 2, max_depths: 2, html_tag: \\\"a\\\"]."}

      iex> Policer.police([
      iex>   depth: 3,
      iex>   max_depths: 2,
      iex>   html_tag: "img",
      iex>   url: "http://policer/hi.jpg",
      iex>   url_filter: UrlFilter
      iex> ])
      {:ok, [depth: 3, max_depths: 2, html_tag: "img", url: "http://policer/hi.jpg", url_filter: UrlFilter]}

      iex> Policer.police([
      iex>   depth: 1,
      iex>   max_depths: 2,
      iex>   url: "ftp://hello.world"
      iex> ])
      {:error, "Fetch failed 'acceptable_uri_scheme?', with opts: [depth: 1, max_depths: 2, url: \\\"ftp://hello.world\\\"]."}

      iex> Crawler.Store.add("http://policer/exist/")
      iex> Policer.police([
      iex>   depth: 1,
      iex>   max_depths: 2,
      iex>   url: "http://policer/exist/"
      iex> ])
      {:error, "Fetch failed 'not_fetched_yet?', with opts: [depth: 1, max_depths: 2, url: \\\"http://policer/exist/\\\"]."}
  """
  def police(opts) do
    with {_, true} <- within_fetch_depth?(opts),
         {_, true} <- acceptable_uri_scheme?(opts),
         {_, true} <- not_fetched_yet?(opts),
         {_, true} <- perform_url_filtering(opts)
    do
      {:ok, opts}
    else
      {fail_type, _} ->
        police_error(fail_type, opts)
    end
  end

  defp within_fetch_depth?(opts) do
    max_depths =
      case opts[:html_tag] do
        "a" -> opts[:max_depths]
        _   -> opts[:max_depths] + @asset_extra_depth
      end

    {:within_fetch_depth?, opts[:depth] < max_depths}
  end

  defp acceptable_uri_scheme?(opts) do
    scheme = opts[:url]
    |> String.split("://", parts: 2)
    |> Kernel.hd()

    {:acceptable_uri_scheme?, Enum.member?(@uri_schemes, scheme)}
  end

  defp not_fetched_yet?(opts) do
    {:not_fetched_yet?, !Store.find(opts[:url])}
  end

  defp perform_url_filtering(opts) do
    {:ok, pass_through?} = opts[:url_filter].filter(opts[:url], opts)

    {:perform_url_filtering, pass_through?}
  end

  defp police_error(fail_type, opts) do
    {:error, "Fetch failed '#{fail_type}', with opts: #{Kernel.inspect(opts)}."}
  end
end
