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
  alias Crawler.Store
  alias Crawler.Store.Page
  alias Crawler.URL

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
      {:ok, %Req.Response{status: 200, body: body} = response} ->
        fetch_url_200(body, response, opts)

      {:ok, %Req.Response{status: status_code}}
      when status_code in [408, 429] or status_code >= 500 ->
        fetch_url_retryable(status_code, opts)

      {:ok, %Req.Response{status: status_code}} ->
        fetch_url_non_200(status_code, opts)

      {:error, %Req.TransportError{reason: reason}} ->
        fetch_url_failed(reason, opts)

      {:error, %{__exception__: true} = exception} ->
        fetch_url_failed(Exception.message(exception), opts)

      {:error, reason} ->
        fetch_url_failed(reason, opts)
    end
  end

  defp fetch_url_200(body, response, opts) do
    with opts <- HeaderPreparer.prepare(Req.get_headers_list(response), opts),
         {:ok, _} <- Recorder.maybe_store_page(body, opts),
         {:ok, opts} <- record_referrer_url(response, body, opts),
         {:ok, _} <- snap_page(body, opts) do
      Logger.debug("Fetched #{opts[:url]}")

      %Page{url: opts[:url], body: body, opts: opts}
    end
  end

  defp fetch_url_retryable(status_code, opts) do
    msg = "Failed to fetch #{opts[:url]}, status code: #{status_code}"

    Logger.debug(msg)

    {:error, msg}
  end

  defp fetch_url_non_200(status_code, opts) do
    msg = "Failed to fetch #{opts[:url]}, status code: #{status_code}"

    Logger.debug(msg)

    {:warn, msg}
  end

  defp fetch_url_failed(reason, opts) do
    msg = "Failed to fetch #{opts[:url]}, reason: #{format_reason(reason)}"

    Logger.debug(msg)

    {:error, msg}
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp record_referrer_url(response, body, opts) do
    final = final_url(response, opts[:url])
    opts = Map.put(opts, :referrer_url, final)

    {:ok, remember_alias(final, body, opts)}
  end

  defp remember_alias(final, body, %{url: url} = opts) when final != url do
    case Store.find({final, opts[:scope]}) do
      nil ->
        case Store.add({final, opts[:scope]}) do
          {:ok, _} ->
            Store.add_page_data({final, opts[:scope]}, body, %{opts | url: final})
            Map.put(opts, :alias_url, final)

          {:error, {:already_registered, _}} ->
            opts
        end

      _page ->
        opts
    end
  end

  defp remember_alias(_final, _body, opts), do: opts

  defp final_url(response, fallback) do
    case Req.Response.get_private(response, :crawler_url) do
      url when is_binary(url) and url != "" -> URL.normalize(url)
      _ -> fallback
    end
  end

  defp snap_page(body, opts) do
    if opts[:save_to] do
      Snapper.snap(body, opts)
    else
      {:ok, ""}
    end
  end
end
