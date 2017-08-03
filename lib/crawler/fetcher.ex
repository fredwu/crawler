defmodule Crawler.Fetcher do
  alias Crawler.Fetcher.{Policer, Recorder, Snapper}
  alias Crawler.Store.Page

  @fetch_opts [
    follow_redirect: true,
    max_redirect:    5
  ]

  def fetch(opts) do
    with {:ok, opts} <- Policer.police(opts),
         {:ok, opts} <- Recorder.record(opts)
    do
      fetch_url(opts)
    end
  end

  defp fetch_url(opts) do
    url = opts[:url]

    case HTTPoison.get(url, [], fetch_opts(opts)) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        fetch_url_200(body, opts)
      {:ok, %HTTPoison.Response{status_code: status_code}} ->
        fetch_url_non_200(url, status_code)
      {:error, %HTTPoison.Error{reason: reason}} ->
        fetch_url_failed(url, reason)
    end
  end

  defp fetch_url_200(body, opts) do
    with {:ok, _} <- Recorder.store_page(opts[:url], body),
         {:ok, _} <- snap_page(body, opts)
    do
      return_page(body, opts)
    end
  end

  defp fetch_url_non_200(url, status_code) do
    {:error, "Failed to fetch #{url}, status code: #{status_code}"}
  end

  defp fetch_url_failed(url, reason) do
    {:error, "Failed to fetch #{url}, reason: #{reason}"}
  end

  defp snap_page(body, opts) do
    if opts[:save_to] do
      Snapper.snap(body, opts)
    else
      {:ok, ""}
    end
  end

  defp return_page(body, opts) do
    %{
      page: %Page{url: opts[:url], body: body},
      opts: opts
    }
  end

  defp fetch_opts(opts) do
    @fetch_opts ++ [
      recv_timeout: opts[:timeout]
    ]
  end
end
