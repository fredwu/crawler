defmodule Crawler.Fetcher do
  @moduledoc """
  Fetches pages and perform tasks on them.
  """

  require Logger

  alias Crawler.Charset
  alias Crawler.Cookies
  alias Crawler.Diagnostics
  alias Crawler.Fetcher.HeaderPreparer
  alias Crawler.Fetcher.Policer
  alias Crawler.Fetcher.Recorder
  alias Crawler.Fetcher.Requester
  alias Crawler.HTTP
  alias Crawler.Linker.Snapshot
  alias Crawler.MediaType
  alias Crawler.Robots
  alias Crawler.Snapper
  alias Crawler.Store
  alias Crawler.Store.Page
  alias Crawler.URL

  @picture_pause 50

  @doc """
  Fetches a URL by:

  - verifying whether the URL needs fetching through `Crawler.Fetcher.Policer.police/1`
  - honouring `robots.txt` when `:respect_robots` is enabled
  - recording data for internal use through `Crawler.Fetcher.Recorder.record/1`
  - fetching the URL
  - performing retries upon failed fetches through `Crawler.Fetcher.Retrier.perform/2`
  """
  def fetch(opts) do
    case fetch_unseen(opts) do
      {:warn, "Fetch failed check 'not_fetched_yet?'" <> _} = warn ->
        seen_url(opts, warn)

      # The seen check and the store claim are separate. A second link can pass
      # the check, then lose the claim. That link was already fetched.
      {:error, {:already_registered, _pid}} ->
        seen_url(
          opts,
          {:warn, "Fetch failed check 'not_fetched_yet?', crawl: #{Diagnostics.crawl(opts)}."}
        )

      other ->
        other
    end
  end

  defp seen_url(opts, warn), do: open_stored_document(opts) || warn

  defp fetch_unseen(opts) do
    with {:ok, opts} <- Policer.police(opts),
         :ok <- permit_robots(opts),
         {:ok, opts} <- Recorder.record(opts) do
      opts[:retrier].perform(fn -> fetch_url(opts) end, opts)
    end
  end

  # The first fetch stores the body and keeps its reference role. A later page
  # link parses and rewrites a stored SVG, or an as=fetch response whose type is
  # a document, then records the document role so another link does not parse it
  # again. Other references stay closed. The page link waits out that fetch so
  # its snapshot cannot replace the rewritten file, and so the final response
  # URL is already stored. The page-link check comes before the URL filter. A
  # duplicate asset must keep the original already-seen warning when that filter
  # returns an error.
  defp open_stored_document(opts) do
    with true <- opts[:html_tag] == "a",
         {:ok, true} <- admit_reference(opts),
         %Page{body: body, opts: stored} <- await_stored(opts),
         true <- document_upgrade?(opts, stored) do
      publish_stored_document(body, stored, opts)
    else
      {:error, _} = error -> error
      _ -> nil
    end
  end

  defp await_stored(opts) do
    key = {opts[:url], opts[:scope]}

    cond do
      not current_crawl?(opts) ->
        nil

      ready = ready_page(key) ->
        ready

      stored_running?(key) ->
        Process.sleep(@picture_pause)
        await_stored(opts)

      true ->
        ready_page(key)
    end
  end

  defp ready_page(key) do
    case Store.find(key) do
      %Page{processed: true, body: body, opts: stored} = page
      when is_binary(body) and is_map(stored) ->
        page

      _ ->
        nil
    end
  end

  # Unknown bytes can still be an SVG or a fetch document. A known image, font,
  # track, or JSON body is not worth holding a worker. Duplicate page links are
  # not these fetches and return immediately.
  defp stored_running?(key) do
    case Store.find(key) do
      %Page{} = page ->
        Store.fetch_in_flight?(key) and reusable_fetch?(page)

      _ ->
        false
    end
  end

  defp reusable_fetch?(page) do
    (picture_fetch?(page) and open_picture?(page)) or open_fetch_document?(page)
  end

  defp picture_fetch?(%Page{opts: %{html_tag: tag}}) when is_binary(tag) and tag != "a", do: true
  defp picture_fetch?(%Page{fetch_tag: tag}) when is_binary(tag) and tag != "a", do: true
  defp picture_fetch?(_page), do: false

  defp open_picture?(%Page{picture_type: type}) when is_binary(type), do: MediaType.svg?(type)
  defp open_picture?(%Page{body: body}) when not is_binary(body), do: true
  defp open_picture?(%Page{opts: stored}), do: MediaType.svg?(stored[:content_type])

  defp current_crawl?(opts) do
    Store.current?(opts[:scope], opts[:generation], opts[:queue])
  end

  defp publish_stored_document(body, stored, opts) do
    opts = document_opts(opts, stored)

    case snap_page(body, opts) do
      {:ok, _} ->
        case Store.add_page_data(
               {opts[:url], opts[:scope]},
               body,
               Map.put(stored, :html_tag, "a")
             ) do
          {:error, _} = error -> error
          _ -> %Page{url: opts[:url], body: body, opts: opts}
        end

      other ->
        other
    end
  end

  # `depth` matches a normal fetch: Recorder increments it once before parsing.
  defp document_opts(opts, stored) do
    landed = stored[:referrer_url] || opts[:url]

    opts =
      opts
      |> Map.put(:content_type, stored[:content_type])
      |> Map.put(:referrer_url, landed)
      |> Map.put(:headers, stored[:headers])
      |> Map.replace!(:depth, opts[:depth] + 1)
      |> Cookies.assign_landed_site(landed)

    case stored[:alias_url] do
      final when is_binary(final) -> Map.put(opts, :alias_url, final)
      _ -> opts
    end
  end

  defp document_upgrade?(opts, stored) do
    opts[:html_tag] == "a" and stored[:html_tag] != "a" and
      (MediaType.svg?(stored[:content_type]) or fetch_document?(stored))
  end

  defp fetch_document?(%{html_tag: "fetch", content_type: type}), do: document_type?(type)
  defp fetch_document?(_stored), do: false

  defp open_fetch_document?(%Page{fetch_tag: "fetch"} = page), do: pending_document?(page)
  defp open_fetch_document?(%Page{opts: %{html_tag: "fetch"}} = page), do: pending_document?(page)
  defp open_fetch_document?(_page), do: false

  defp pending_document?(%Page{picture_type: type}) when is_binary(type), do: document_type?(type)
  defp pending_document?(%Page{body: body}) when not is_binary(body), do: true
  defp pending_document?(%Page{opts: %{content_type: type}}), do: document_type?(type)
  defp pending_document?(_page), do: true

  defp document_type?(type) do
    MediaType.html?(type) or MediaType.javascript?(type)
  end

  defp admit_reference(%{url_filter: filter, url: url} = opts)
       when is_atom(filter) and not is_nil(filter) do
    filter.filter(url, opts)
  end

  defp admit_reference(_opts), do: {:ok, true}

  defp permit_robots(opts) do
    if Robots.permitted?(opts) do
      :ok
    else
      msg = "Blocked by robots.txt for #{Diagnostics.url(opts[:url])}"
      Logger.debug(msg)
      {:warn, msg}
    end
  end

  defp fetch_url(opts) do
    if stale?(opts), do: {:warn, :stale}, else: request(opts)
  end

  defp stale?(%{generation: generation, scope: scope} = opts) when not is_nil(generation) do
    not Store.current?(scope, generation, opts[:queue])
  end

  defp stale?(_opts), do: false

  defp request(opts) do
    case Requester.make(opts) do
      {:ok, %Req.Response{status: status, body: body} = response} when status in [200, 203] ->
        fetch_url_200(body || <<>>, response, opts)

      {:error, %HTTP.BodyTooLarge{} = exception} ->
        fetch_url_warn(exception, opts)

      {:error, %HTTP.UnsupportedEncoding{} = exception} ->
        fetch_url_warn(exception, opts)

      {:ok, %Req.Response{status: status_code}}
      when status_code in [408, 429] or status_code >= 500 ->
        fetch_url_retryable(status_code, opts)

      {:ok, %Req.Response{status: status_code}} ->
        fetch_url_non_200(status_code, opts)

      {:error, %HTTP.RedirectRejected{} = rejected} ->
        fetch_url_rejected(rejected, opts)

      {:error, %Req.TransportError{reason: reason}} ->
        fetch_url_failed(transport_reason(reason), opts)

      {:error, %Req.TooManyRedirectsError{} = exception} ->
        fetch_url_failed(Exception.message(exception), opts)

      {:error, %{__exception__: true} = exception} ->
        fetch_url_failed(exception.__struct__, opts)
    end
  end

  defp fetch_url_200(body, response, opts) do
    opts = HeaderPreparer.prepare(Req.get_headers_list(response), opts)
    body = Charset.decode(body, opts)

    with :ok <- note_picture_type(opts),
         {:ok, _} <- Recorder.maybe_store_page(body, opts),
         :ok <- retain_reusable_body(body, opts),
         {:ok, opts} <- record_referrer_url(response, body, opts),
         :ok <- store_response_identity(opts) do
      case snap_page(body, opts) do
        {:ok, _} ->
          Logger.debug(fn -> "Fetched #{Diagnostics.url(opts[:url])}" end)
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
    msg = "Failed to fetch #{Diagnostics.url(opts[:url])}, status code: #{status_code}"

    Logger.debug(msg)

    {:error, msg}
  end

  defp fetch_url_non_200(status_code, opts) do
    msg = "Failed to fetch #{Diagnostics.url(opts[:url])}, status code: #{status_code}"

    Logger.debug(msg)

    {:warn, msg}
  end

  defp fetch_url_warn(exception, opts) do
    msg = "Failed to fetch #{Diagnostics.url(opts[:url])}, #{Exception.message(exception)}"

    Logger.debug(msg)

    {:warn, msg}
  end

  defp fetch_url_failed(reason, opts) do
    msg = "Failed to fetch #{Diagnostics.url(opts[:url])}, reason: #{format_reason(reason)}"

    Logger.debug(msg)

    {:error, msg}
  end

  defp fetch_url_rejected(%HTTP.RedirectRejected{url: next}, opts) do
    msg = "Redirect rejected for #{Diagnostics.url(opts[:url])} to #{Diagnostics.url(next)}"

    Logger.debug(msg)

    {:warn, msg}
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp transport_reason(reason) when is_atom(reason), do: reason
  defp transport_reason(_reason), do: :transport_error

  defp record_referrer_url(response, body, opts) do
    final = final_url(response, opts[:url])

    opts =
      opts
      |> Map.put(:referrer_url, final)
      |> land_worker_entry(final)
      |> Cookies.assign_landed_site(final)

    remember_alias(final, body, opts)
  end

  # The worker entry is the response that was loaded, after a redirect.
  defp land_worker_entry(%{worker_base: base, url: url} = opts, final)
       when is_binary(base) and base == url and is_binary(final) do
    %{opts | worker_base: final}
  end

  defp land_worker_entry(opts, _final), do: opts

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

  # Record the type before the body is stored. A document link can then stop
  # waiting as soon as a picture is known not to be SVG.
  defp note_picture_type(%{html_tag: tag} = opts) when is_binary(tag) and tag != "a" do
    case opts[:content_type] do
      type when is_binary(type) ->
        Store.note_picture_type({opts[:url], opts[:scope]}, type, opts[:generation], opts[:queue])

      _ ->
        :ok
    end
  end

  defp note_picture_type(_opts), do: :ok

  # The user store already ran. Keep an internal copy only when it did not write
  # one, so a later page link can open this SVG or as=fetch document. Other
  # media stay body-less when storage is disabled.
  defp retain_reusable_body(body, %{html_tag: tag} = opts) when is_binary(tag) and tag != "a" do
    if MediaType.svg?(opts[:content_type]) or fetch_document?(opts) do
      retain_missing_body(body, opts)
    else
      :ok
    end
  end

  defp retain_reusable_body(_body, _opts), do: :ok

  defp retain_missing_body(body, opts) do
    key = {opts[:url], opts[:scope]}

    case Store.find(key) do
      %Page{body: stored} when is_binary(stored) ->
        :ok

      _ ->
        case Store.add_page_data(key, body, opts) do
          {:error, :stale} = error -> error
          _ -> :ok
        end
    end
  end

  # The user store already received the body. Only the internal page needs the
  # final URL, so a later document upgrade does not resolve links against the
  # pre-redirect request and can publish the alias landing as well.
  defp store_response_identity(opts) do
    key = {opts[:url], opts[:scope]}

    case Store.find(key) do
      %Page{body: body, opts: stored} when is_binary(body) and is_map(stored) ->
        stored =
          stored
          |> Map.put(:referrer_url, opts[:referrer_url])
          |> put_alias_url(opts[:alias_url])
          |> put_worker_base(opts[:worker_base])

        case Store.add_page_data(key, body, stored) do
          {:error, :stale} = error -> error
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp put_alias_url(opts, url) when is_binary(url), do: Map.put(opts, :alias_url, url)
  defp put_alias_url(opts, _url), do: opts

  defp put_worker_base(opts, base) when is_binary(base), do: Map.put(opts, :worker_base, base)
  defp put_worker_base(opts, _base), do: opts

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

  # Publishing the landing file requires the alias acquired for this fetch.
  # Processed pages keep their copy; retained fallbacks publish after settlement.
  defp snap_distinct_landing(body, %{url: url, alias_url: final} = opts)
       when is_binary(final) do
    if Snapshot.path(final) == Snapshot.path(url) do
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
