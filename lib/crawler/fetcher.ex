defmodule Crawler.Fetcher do
  @moduledoc """
  Fetches pages and perform tasks on them.
  """

  alias __MODULE__.{Policer, Recorder, Requester, HeaderPreparer}
  alias Crawler.{Snapper, Store.Page}

  @doc """
  Fetches a URL by:

  - verifying whether the URL needs fetching through `Crawler.Fetcher.Policer.police/1`
  - recording data for internal use through `Crawler.Fetcher.Recorder.record/1`
  - fetching the URL
  - performing retries upon failed fetches through `Crawler.Fetcher.Retrier.perform/2`
  """
  def fetch(opts) do
    with {:ok, opts} <- Policer.police(opts),
         {:ok, opts} <- Recorder.record(opts)
    do
      opts[:retrier].perform(fn -> fetch_url(opts) end, opts)
    end
  end

  defp fetch_url(opts) do
    case Requester.make(opts) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body, headers: headers}} ->
        fetch_url_200(body, headers, opts)
      {:ok, %HTTPoison.Response{status_code: status_code}} ->
        fetch_url_non_200(status_code, opts)
      {:error, %HTTPoison.Error{reason: reason}} ->
        fetch_url_failed(reason, opts)
    end
  end

  defp fetch_url_200(body, headers, opts) do
    with opts        <- HeaderPreparer.prepare(headers, opts),
         {:ok, _}    <- Recorder.store_page(body, opts),
         {:ok, opts} <- record_referrer_url(opts),
         {:ok, _}    <- snap_page(body, opts)
    do
      %Page{url: opts[:url], body: body, opts: opts}
    end
  end

  defp fetch_url_non_200(status_code, opts) do
    {:error, "Failed to fetch #{opts[:url]}, status code: #{status_code}"}
  end

  defp fetch_url_failed(reason, opts) do
    {:error, "Failed to fetch #{opts[:url]}, reason: #{reason}"}
  end

  defp record_referrer_url(opts) do
    {:ok, Map.put(opts, :referrer_url, opts[:url])}
  end

  defp snap_page(body, opts) do
    if opts[:save_to] do
      Snapper.snap(body, opts)
    else
      {:ok, ""}
    end
  end
end
