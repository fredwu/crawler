defmodule Crawler.Fetcher do
  @moduledoc """
  Fetches pages and perform tasks on them.
  """

  require Logger

  alias Crawler.Charset
  alias Crawler.Fetcher.HeaderPreparer
  alias Crawler.Fetcher.Policer
  alias Crawler.Fetcher.Recorder
  alias Crawler.Fetcher.Requester
  alias Crawler.HTTP
  alias Crawler.Linker.Snapshot
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
    if stale?(opts), do: {:warn, :stale}, else: request(opts)
  end

  defp stale?(%{generation: generation, scope: scope} = opts) when is_integer(generation) do
    not Store.current?(scope, generation, opts[:queue])
  end

  defp stale?(_opts), do: false

  defp request(opts) do
    case Requester.make(opts) do
      {:ok, %Req.Response{status: 200, body: body} = response} ->
        fetch_url_200(body, response, opts)

      {:ok, %Req.Response{status: status_code}}
      when status_code in [408, 429] or status_code >= 500 ->
        fetch_url_retryable(status_code, opts)

      {:ok, %Req.Response{status: status_code}} ->
        fetch_url_non_200(status_code, opts)

      {:error, %HTTP.RedirectRejected{} = rejected} ->
        fetch_url_rejected(rejected, opts)

      {:error, %Req.TransportError{reason: reason}} ->
        fetch_url_failed(reason, opts)

      {:error, %{__exception__: true} = exception} ->
        fetch_url_failed(Exception.message(exception), opts)
    end
  end

  defp fetch_url_200(body, response, opts) do
    opts = HeaderPreparer.prepare(Req.get_headers_list(response), opts)
    body = Charset.decode(body, opts)

    with {:ok, _} <- Recorder.maybe_store_page(body, opts),
         {:ok, opts} <- record_referrer_url(response, body, opts) do
      case snap_page(body, opts) do
        {:ok, _} ->
          Logger.debug("Fetched #{opts[:url]}")
          %Page{url: opts[:url], body: body, opts: opts}

        {:error, :stale} ->
          {:warn, :stale}

        {:error, _} = error ->
          drop_owned_alias(opts)
          error
      end
    else
      {:error, :stale} -> {:warn, :stale}
      other -> other
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

  defp fetch_url_rejected(%HTTP.RedirectRejected{url: next}, opts) do
    msg = "Redirect rejected for #{opts[:url]} to #{next}"

    Logger.debug(msg)

    {:warn, msg}
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp record_referrer_url(response, body, opts) do
    final = final_url(response, opts[:url])
    opts = Map.put(opts, :referrer_url, final)

    remember_alias(final, body, opts)
  end

  defp remember_alias(final, body, %{url: url} = opts) when final != url do
    case Store.register_alias({final, opts[:scope]}, opts[:generation], opts[:queue]) do
      {:ok, :skip} ->
        with {:ok, ref} <- Store.retain_alias({final, opts[:scope]}, body, opts) do
          {:ok, if(ref, do: Map.put(opts, :alias_candidate, ref), else: opts)}
        end

      {:ok, status} ->
        opts = Map.merge(opts, %{alias_url: final, alias_created: status == :created})
        store_alias(body, opts)

      {:error, _} = error ->
        error
    end
  end

  defp remember_alias(_final, _body, opts), do: {:ok, opts}

  defp store_alias(body, opts) do
    case Recorder.maybe_store_page(body, %{opts | url: opts[:alias_url]}) do
      {:ok, _} ->
        {:ok, opts}

      {:error, _} = error ->
        drop_owned_alias(opts)
        error
    end
  end

  defp drop_owned_alias(%{alias_candidate: ref}), do: Store.discard_retained_alias(ref)

  defp drop_owned_alias(%{alias_url: url, alias_created: created?, scope: scope} = opts)
       when is_binary(url) do
    Store.rollback_alias({url, scope}, opts[:generation], opts[:queue], created?)
  end

  defp drop_owned_alias(_opts), do: :ok

  defp final_url(response, fallback) do
    case Req.Response.get_private(response, :crawler_url) do
      url when is_binary(url) and url != "" -> URL.normalize(url)
      _ -> fallback
    end
  end

  defp snap_page(body, opts) do
    if opts[:save_to] do
      with {:ok, _} <- Snapper.snap(body, opts) do
        snap_distinct_landing(body, opts)
      end
    else
      {:ok, ""}
    end
  end

  # The response body belongs to the landing page. Links to that address need
  # their own file, with relatives computed from where that file sits. The
  # requested address keeps a copy too, so a link to the old address still
  # opens the page that was fetched.
  defp snap_distinct_landing(_body, %{alias_candidate: _ref} = opts), do: {:ok, opts}

  defp snap_distinct_landing(body, %{url: url, referrer_url: final} = opts)
       when is_binary(final) do
    if final == url or Snapshot.path(final) == Snapshot.path(url) do
      {:ok, opts}
    else
      case Snapper.snap(body, %{opts | url: final}) do
        {:ok, _} -> {:ok, opts}
        other -> other
      end
    end
  end

  defp snap_distinct_landing(_body, opts), do: {:ok, opts}
end
