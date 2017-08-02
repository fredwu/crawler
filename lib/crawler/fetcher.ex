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
        with {:ok, _} <- Recorder.store_page(url, body),
             {:ok, _} <- snap_page(body, opts)
        do
          return_page(body, opts)
        end

      {:ok, %HTTPoison.Response{status_code: status_code}} ->
        {:error, "Failed to fetch #{url}, status code: #{status_code}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, "Failed to fetch #{url}, reason: #{reason}"}

    end
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
