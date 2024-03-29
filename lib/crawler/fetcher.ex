defmodule Crawler.Fetcher do
  @moduledoc """
  Fetches pages and perform tasks on them.
  """

  require Logger

  alias Crawler.Fetcher.HeaderPreparer
  alias Crawler.Fetcher.Policer
  alias Crawler.Fetcher.Recorder
  alias Crawler.Fetcher.Requester
  alias Crawler.Snapper
  alias Crawler.Store.Page

  @doc """
  Fetches a URL by:

  - verifying whether the URL needs fetching through `Crawler.Fetcher.Policer.police/1`
  - recording data for internal use through `Crawler.Fetcher.Recorder.record/1`
  - fetching the URL
  - performing retries upon failed fetches through `Crawler.Fetcher.Retrier.perform/2`
  """
  def fetch(opts) do
    with {:ok, opts} <- Policer.police(opts),
         {:ok, opts} <- Recorder.record(opts) do
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
    with opts <- HeaderPreparer.prepare(headers, opts),
         {:ok, _} <- Recorder.maybe_store_page(body, opts),
         {:ok, opts} <- record_referrer_url(opts),
         {:ok, _} <- snap_page(body, opts) do
      Logger.debug("Fetched #{opts[:url]}")

      %Page{url: opts[:url], body: body, opts: opts}
    end
  end

  defp fetch_url_non_200(status_code, opts) do
    msg = "Failed to fetch #{opts[:url]}, status code: #{status_code}"

    Logger.debug(msg)

    {:warn, msg}
  end

  defp fetch_url_failed(reason, opts) do
    msg = "Failed to fetch #{opts[:url]}, reason: #{inspect(reason)}"

    Logger.debug(msg)

    {:warn, msg}
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
