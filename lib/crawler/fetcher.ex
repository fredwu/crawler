defmodule Crawler.Fetcher do
  @moduledoc """
  Fetches pages and perform tasks on them.
  """

  require Logger

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Charset
  alias Crawler.Cookies
  alias Crawler.Deadline
  alias Crawler.Diagnostics
  alias Crawler.Dispatcher
  alias Crawler.Export.Producer
  alias Crawler.Export.StagedIO
  alias Crawler.Fetcher.HeaderPreparer
  alias Crawler.Fetcher.Policer
  alias Crawler.Fetcher.Recorder
  alias Crawler.Fetcher.Requester
  alias Crawler.HTTP
  alias Crawler.Parser
  alias Crawler.Parser.CssSheets
  alias Crawler.Parser.LinkParser
  alias Crawler.Robots
  alias Crawler.Store
  alias Crawler.Store.DecodedSource
  alias Crawler.Store.Page
  alias Crawler.URL

  @doc """
  Fetches a URL by:

  - verifying whether the URL needs fetching through `Crawler.Fetcher.Policer.police/1`
  - honouring `robots.txt` when `:respect_robots` is enabled
  - recording data for internal use through `Crawler.Fetcher.Recorder.record/1`
  - fetching the URL
  - performing retries upon failed fetches through `Crawler.Fetcher.Retrier.perform/2`

  A direct call acquires one generation when none is supplied and preserves
  the caller's scope, including `nil`. A supplied stale generation is rejected.
  """
  def fetch(%{scheduler_claim: _} = opts),
    do: Crawler.Store.Execution.run(opts, &fetch_owned/1)

  def fetch(opts), do: Crawler.Store.Execution.run_job(opts, &fetch_owned/1, :fetch)

  defp fetch_owned(%{scheduler_claim: _} = opts) do
    with {:ok, opts} <- Policer.admitted(opts),
         :ok <- permit_robots(opts),
         {:ok, opts} <- Recorder.admitted(opts) do
      result = opts.retrier.perform(fn -> fetch_url(opts) end, opts)
      with :ok <- dispatch_deferred(opts, result), do: result
    end
  end

  # The queued depth is the depth before Recorder counts this attempt. A picture
  # deferred from a failed import stays a child of the stylesheet that imported it.
  defp dispatch_deferred(%{discovery_mode: :fetch}, _result), do: :ok
  defp dispatch_deferred(_opts, %Page{}), do: :ok
  defp dispatch_deferred(_opts, {:warn, :stale}), do: :ok
  defp dispatch_deferred(_opts, {:error, :stale}), do: :ok
  defp dispatch_deferred(_opts, {:error, {:already_registered, _}}), do: :ok
  defp dispatch_deferred(_opts, {:error, {kind, _}}) when kind in [:limit, :deadline], do: :ok
  defp dispatch_deferred(_opts, {:error, :representation_deferred}), do: :ok

  defp dispatch_deferred(_opts, {:warn, "Fetch failed check 'not_fetched_yet?'" <> _}), do: :ok

  defp dispatch_deferred(opts, _result) do
    case CssSheets.settle(opts) do
      urls when is_list(urls) -> Enum.each(urls, &dispatch_css_url(&1, opts))
      {:error, _} = error -> error
    end
  end

  defp dispatch_css_url(url, opts) do
    LinkParser.parse({:css, url, :url}, opts, &Dispatcher.dispatch/2)
  end

  defp permit_robots(opts) do
    case Robots.permitted_result(opts) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        msg = "Blocked by robots.txt for #{Diagnostics.url(opts[:url])}"
        Logger.debug(msg)
        {:warn, msg}

      {:error, _} = error ->
        error
    end
  end

  defp fetch_url(opts) do
    with :ok <- Store.note_response(opts, nil) do
      result = if stale?(opts), do: {:warn, :stale}, else: request(opts)
      Store.note_request_result(opts, Crawler.Store.Execution.request_outcome(result))
      result
    end
  end

  defp stale?(%{generation: generation} = opts) when not is_nil(generation) do
    not Store.current?(opts[:scope], generation, opts[:queue])
  end

  defp stale?(_opts), do: false

  defp request(opts) do
    case make_request(opts) do
      {:ok, %Req.Response{status: status, body: body} = response} when status in [200, 203] ->
        fetch_url_200(body || <<>>, response, opts)

      {:error, %HTTP.BodyTooLarge{}} when is_map_key(opts, :scheduler_claim) ->
        {:error, {:limit, :max_body}}

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

      {:error, %{reason: {kind, _} = reason}} when kind in [:deadline, :limit] ->
        {:error, reason}

      {:error, %{__exception__: true} = exception} ->
        fetch_url_failed(exception.__struct__, opts)

      {:error, _} = error ->
        error
    end
  end

  def control_request(%{scheduler_mode: :interpret} = opts) do
    with {:ok, response} <- make_request(opts) do
      {:ok, %{response | private: Map.delete(response.private, :crawler_control_sequence)}}
    end
  end

  def control_request(opts) do
    with :ok <- Store.note_response(opts, nil), do: make_request(opts)
  end

  defp make_request(%{scheduler_mode: :interpret} = opts), do: Store.response_source(opts)

  defp make_request(%{prepared_request: prepared, scheduler_claim: _} = opts) do
    with {:ok, receipt} <-
           Store.reserve_resource(opts, :response, opts.max_body + 16_384, Process.whereis(Store)) do
      result =
        send_request(
          prepared,
          Map.merge(Map.take(opts, [:scope, :generation, :queue, :execution_lease]), %{
            deadline: opts.crawler_deadline,
            control_accounting: opts[:scheduler_kind] == :sitemap
          })
        )

      case result do
        {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
          source = %{
            response
            | private:
                Map.take(response.private, [
                  :crawler_url,
                  :crawler_reuse,
                  :crawler_control_sequence
                ])
          }

          source =
            source
            |> Req.Response.put_private(:crawler_source_revision, make_ref())
            |> Req.Response.put_private(:crawler_response_receipt, receipt)
            |> Crawler.Store.SourceWitness.physical(opts)

          with {:ok, bytes} <- Crawler.Store.Retained.bytes(source, opts.max_body + 16_384),
               {:ok, copy_bytes} <-
                 Crawler.Store.Retained.bytes(%{source | body: nil}, opts.max_body + 16_384),
               :ok <-
                 Store.commit_response_resource(
                   receipt,
                   bytes,
                   copy_bytes + min(byte_size(source.body || <<>>), 64)
                 ),
               :ok <- Store.publish_source(opts, receipt, source) do
            {:ok, source}
          end

        {:status, status, reuse} ->
          release_response(receipt)

          with :ok <- Store.note_response(opts, reuse),
               do: {:ok, Req.Response.new(status: status)}

        error ->
          release_response(receipt)
          Store.note_response(opts, nil)
          error
      end
    end
  end

  defp send_request(prepared, context) do
    case Requester.send(prepared, context) do
      {:ok, %Req.Response{status: status} = response}
      when status not in [200, 203] and
             not (status in 200..299 and is_map_key(context, :control_accounting) and
                      :erlang.map_get(:control_accounting, context)) ->
        {:status, status, Requester.reuse_disposition(response)}

      result ->
        result
    end
  end

  defp release_response(receipt) do
    Store.release_resource(receipt, Process.whereis(Store))
    Store.release_resource(receipt)
  end

  defp fetch_url_200(body, response, opts) do
    opts = HeaderPreparer.prepare(Req.get_headers_list(response), opts)
    opts = Map.put(opts, :source_entity_bytes, byte_size(body))
    source_revision = Req.Response.get_private(response, :crawler_source_revision)
    opts = Map.put(opts, :source_revision, source_revision)

    opts =
      Map.put(opts, :body_resource, Req.Response.get_private(response, :crawler_response_receipt))

    with {:ok, bound} <- key_bound(opts),
         {:ok, opts} <- retain_page_metadata(nil, response, opts),
         {:ok, body, opts, pipeline} <- decode_page(body, opts, bound),
         :ok <- Store.witness_source(opts, body, pipeline.decoder_seed),
         :ok <- note_picture_type(opts),
         {:ok, opts} <- record_referrer_url(response, opts),
         {:ok, _} <- Recorder.maybe_store_page(body, opts),
         {:ok, opts} <- remember_alias(opts.referrer_url, body, opts),
         {:ok, prepared, credit} <- prepare_page(body, opts, pipeline) do
      opts = prepared.opts

      case stage_direct(prepared, credit, opts) do
        :ok ->
          Logger.debug(fn -> "Fetched #{Diagnostics.url(opts[:url])}" end)

          Crawler.Store.Execution.funded_page(%Page{
            url: opts[:url],
            body: body,
            opts: opts,
            source_revision: source_revision,
            target_handle: opts[:target_handle],
            credit: credit,
            analysis: prepared.analysis,
            interpretation: prepared
          })

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

  defp prepare_page(body, opts, pipeline) do
    if analysis_required?(opts) do
      options = Map.merge(opts, Crawler.Limits.analysis(opts))

      with {:ok, analysis, pipeline} <- lexical_analysis(body, options, pipeline) do
        prepare_analysis(body, opts, analysis, pipeline)
      end
    else
      with {:ok, prepared} <- Parser.prepare_for_parse(body, opts),
           do: {:ok, prepared, page_credit(opts, pipeline)}
    end
  end

  defp prepare_analysis(body, opts, nil, pipeline),
    do: {:ok, Parser.opaque(body, opts), page_credit(opts, pipeline)}

  defp prepare_analysis(_body, opts, analysis, pipeline) do
    with {:ok, receipt, budget, pipeline} <- reserve_analysis(opts, analysis.budget, pipeline),
         {:ok, groups} <- Analysis.css_groups_result(%{analysis | budget: budget}, opts),
         :ok <- Store.commit_resource(receipt, groups.budget.retained - budget.retained),
         pipeline = %{pipeline | retained: pipeline.retained ++ [receipt]},
         {:ok, context} <- stylesheet_context(groups.groups, opts),
         {:ok, receipt, budget, pipeline} <- reserve_analysis(opts, groups.budget, pipeline),
         {:ok, prepared} <-
           Parser.prepare_collection(analysis, opts, context, %{groups | budget: budget}),
         :ok <-
           Store.commit_resource(receipt, prepared.collection.budget.retained - budget.retained) do
      {:ok, prepared, page_credit(opts, %{pipeline | retained: pipeline.retained ++ [receipt]})}
    end
  end

  defp analysis_required?(opts) do
    opts[:fetch_kind] in [:manifest, :speculation_rules, :source_map] or
      Crawler.Parser.Guarder.pass?(opts) or
      (opts[:html_tag] == "a" and
         (Crawler.MediaType.feed?(opts[:content_type]) or
            Crawler.MediaType.xml?(opts[:content_type])))
  end

  defp page_credit(opts, pipeline) do
    %{
      retained: pipeline.retained,
      backing: pipeline.backing,
      unavailable: pipeline.unavailable,
      reservation: opts[:return_reservation]
    }
  end

  defp stylesheet_context([], _opts), do: {:ok, %{}}
  defp stylesheet_context(groups, opts), do: CssSheets.resolve_groups(opts, groups)

  defp key_bound(opts) do
    workspace = DecodedSource.context_workspace()
    credit = %{retained: [], backing: [opts.body_resource], unavailable: 0}

    with_workspace(opts, credit, workspace, fn _funding ->
      with {:ok, bytes} <-
             DecodedSource.context_bytes(
               Map.take(opts, [:content_type, :headers]),
               Crawler.Limits.decoded_context(opts),
               %{retained_bytes: 0, workspace_bytes: workspace}
             ) do
        type_bytes = if is_binary(opts[:content_type]), do: byte_size(opts.content_type), else: 0
        bound = 1_088 + 256 * type_bytes + max(type_bytes, 9) + 3 * bytes

        if bound <= opts.max_retained_bytes,
          do: {:ok, bound},
          else: {:error, {:limit, :max_retained_bytes}}
      end
    end)
  end

  defp decode_page(body, opts, bound) do
    budget = Budget.new(Crawler.Limits.analysis(opts))

    pipeline = %{
      retained: [],
      backing: [opts.body_resource],
      unavailable: 0,
      budget: budget,
      decoder_seed: nil,
      key_bound: bound,
      lexical: nil
    }

    if analysis_required?(opts) do
      with {:ok, result, budget} <- acquire_lexical(opts, pipeline),
           do: lexical_source(result, body, opts, %{pipeline | budget: budget})
    else
      decoded_source(body, opts, pipeline)
    end
  end

  defp acquire_lexical(opts, pipeline) do
    result =
      with_workspace(opts, pipeline, pipeline.key_bound, fn _funding ->
        key_acquire_frame(opts, pipeline.budget)
      end)

    with {:ok, acquired, budget} <- result,
         {:ok, budget} <- Budget.refund(budget, budget.retained - pipeline.budget.retained) do
      case acquired do
        {:waiting, _attempt} ->
          with :ok <- await_source(opts, :crawler_source_cache),
               do: acquire_lexical(opts, %{pipeline | budget: budget})

        {:error, _} = error ->
          error

        other ->
          {:ok, other, budget}
      end
    end
  end

  defp key_acquire_frame(opts, budget) do
    with :ok <- Deadline.check(opts.crawler_deadline),
         {:ok, key, budget} <- Analysis.lexical_key_result(opts, budget),
         do: {:ok, Store.acquire_analysis(opts, key, make_ref()), budget}
  end

  defp lexical_source({:compute, token}, body, opts, pipeline) do
    decoded_source(body, opts, %{pipeline | lexical: {:compute, token}})
  end

  defp lexical_source({:cached, analysis, credit}, _body, opts, pipeline) do
    pipeline = %{
      pipeline
      | retained: credit.retained,
        backing: credit.backing,
        decoder_seed: analysis.allocation.seed,
        unavailable: credit.unavailable,
        lexical: {:cached, analysis}
    }

    {:ok, analysis.regions[analysis.root].source,
     Map.put(opts, :body_resource, hd(credit.backing)), pipeline}
  end

  defp decoded_source(body, opts, pipeline) do
    with :ok <- Deadline.check(opts.crawler_deadline) do
      case Store.acquire_decoded(opts, make_ref()) do
        {:decode, token} ->
          decode_source(body, opts, pipeline, token)

        {:decoded, root} ->
          with {:ok, budget} <- historical_seed(root.decoder_seed, pipeline.budget) do
            pipeline = %{
              pipeline
              | budget: budget,
                backing: root.credit.backing,
                decoder_seed: root.decoder_seed,
                unavailable: budget.retained
            }

            {:ok, root.body, Map.put(opts, :body_resource, hd(root.credit.backing)), pipeline}
          end

        {:waiting, _attempt} ->
          with :ok <- await_source(opts, :crawler_decoded_source),
               do: decoded_source(body, opts, pipeline)

        {:error, _} = error ->
          error
      end
    end
  end

  defp decode_source(body, opts, pipeline, token) do
    available = Budget.available(pipeline.budget)

    with {:ok, receipt, capacity} <-
           Store.reserve_resource_up_to(opts, :response, available, Process.whereis(Store)),
         {:ok, seed} <- Budget.charge(pipeline.budget, available - capacity),
         {:ok, _funding} <- stage_funding(opts, pipeline, receipt, capacity),
         {:ok, decoded, budget, ownership} <- Charset.decode_owned_result(body, opts, seed),
         :ok <-
           Store.commit_response_resource(
             receipt,
             max(
               budget.retained - seed.retained,
               if(ownership == :retained, do: 128 + min(byte_size(decoded), 64), else: 0)
             ),
             if(ownership == :retained, do: 128 + min(byte_size(decoded), 64), else: 0)
           ) do
      backing = if ownership == :borrowed, do: opts.body_resource, else: receipt

      # Backing has its own receipt; preserve the decoder charge as the semantic floor.
      decoded_pipeline = %{
        pipeline
        | budget: budget,
          decoder_seed: budget,
          backing: [backing],
          unavailable: budget.retained
      }

      result =
        with_workspace(opts, decoded_pipeline, publication_workspace(token), fn _funding ->
          if token == nil,
            do: :ok,
            else:
              Store.publish_decoded(
                opts,
                token,
                decoded,
                %{budget: budget, unavailable: seed.retained},
                ownership
              )
        end)

      if ownership == :borrowed, do: release_decode_reservation(receipt)

      with :ok <- result,
           do: {:ok, decoded, Map.put(opts, :body_resource, backing), decoded_pipeline}
    end
  end

  defp lexical_analysis(_body, opts, %{lexical: {:cached, cached}} = pipeline) do
    with {:ok, seed} <- historical_seed(cached.allocation.seed, pipeline.budget),
         {:ok, analysis} <-
           with_workspace(opts, pipeline, pipeline.key_bound + Budget.cost(:context), fn _ ->
             Analysis.cached_result(cached, opts, seed)
           end) do
      pipeline = %{pipeline | budget: analysis.budget, unavailable: seed.retained}

      with_workspace(opts, pipeline, 0, fn funding ->
        if funding.retained_capacity >= analysis.budget.retained - seed.retained,
          do: {:ok, analysis, pipeline},
          else: {:error, {:limit, :receipt_capacity}}
      end)
    end
  end

  defp lexical_analysis(body, opts, %{lexical: {:compute, token}} = pipeline) do
    case lexical_candidate(body, opts, pipeline) do
      :copy ->
        {:ok, nil, pipeline}

      {:ok, receipt, seed, analysis, pipeline} ->
        publish_analysis(opts, token, receipt, seed, analysis, pipeline)

      error ->
        error
    end
  end

  defp lexical_candidate(body, opts, pipeline) do
    with {:ok, receipt, seed, pipeline} <- reserve_analysis(opts, pipeline.budget, pipeline) do
      case Analysis.analyze(body, opts, seed) do
        {:error, :invalid_json} when opts.fetch_kind == :source_map ->
          release_decode_reservation(receipt)
          :copy

        {:ok, analysis} ->
          {:ok, receipt, seed, analysis, pipeline}

        error ->
          error
      end
    end
  end

  defp publish_analysis(opts, token, receipt, seed, analysis, pipeline) do
    with :ok <- Store.commit_resource(receipt, analysis.budget.retained - seed.retained) do
      pipeline = %{pipeline | retained: [receipt], budget: analysis.budget}

      with :ok <-
             with_workspace(opts, pipeline, publication_workspace(token), fn _funding ->
               if token == nil,
                 do: :ok,
                 else: Store.publish_analysis(opts, token, analysis, :borrowed)
             end),
           do: {:ok, analysis, pipeline}
    end
  end

  defp reserve_analysis(opts, budget, pipeline) do
    available = Budget.available(budget)

    with {:ok, receipt, capacity} <-
           Store.reserve_resource_up_to(opts, :analysis, available, Process.whereis(Store)),
         {:ok, budget} <- Budget.charge(budget, available - capacity),
         pipeline = %{pipeline | unavailable: pipeline.unavailable + available - capacity},
         {:ok, _funding} <- stage_funding(opts, pipeline, receipt, capacity),
         do: {:ok, receipt, budget, pipeline}
  end

  defp historical_seed(history, current) do
    # The current branch contains only refunded key preflight and an unavailable baseline.
    if current.scratch == 0 and Enum.all?(current.counts, fn {_key, count} -> count == 0 end) do
      retained = max(history.retained, current.retained)
      peak = max(retained, max(history.peak, current.peak))
      seed = %{history | limit: current.limit, caps: current.caps, retained: retained, peak: peak}

      if retained <= seed.limit and peak <= seed.limit,
        do: {:ok, seed},
        else: {:error, {:limit, :analysis_bytes}}
    else
      {:error, :invalid_budget_continuation}
    end
  end

  defp publication_workspace(nil), do: 0
  defp publication_workspace(_token), do: DecodedSource.context_workspace()

  defp with_workspace(opts, pipeline, bytes, callback) do
    with {:ok, receipt} <- Store.reserve_resource(opts, :scratch, bytes) do
      try do
        with {:ok, funding} <- stage_funding(opts, pipeline, receipt, bytes),
             do: callback.(funding)
      after
        Store.release_resource(receipt)
      end
    end
  end

  defp stage_funding(opts, pipeline, receipt, bytes) do
    credit = %{
      retained: pipeline.retained,
      backing: pipeline.backing,
      overlap: receipt,
      unavailable: pipeline.unavailable
    }

    with {:ok, funding} <- Store.resource_funding(opts, credit),
         :ok <- StagedIO.authorized(funding, bytes),
         do: {:ok, funding}
  end

  defp release_decode_reservation(receipt) do
    Store.release_resource(receipt, Process.whereis(Store))
    Store.release_resource(receipt)
  end

  defp await_source(opts, kind) do
    source = opts.source_revision
    target = opts.target_handle
    lease = opts.execution_lease

    with :ok <- Deadline.check(opts.crawler_deadline) do
      receive do
        {^kind, ^source, ^target, ^lease, reason} when reason in [:ready, :retry] ->
          Deadline.check(opts.crawler_deadline)

        {^kind, ^source, ^target, ^lease, :retired} ->
          {:error, :source_retired}
      after
        Deadline.remaining(opts.crawler_deadline) ->
          {:error, {:deadline, opts.crawler_deadline.kind}}
      end
    end
  end

  defp retain_page_metadata(body, response, %{execution_lease: _} = opts) do
    final = final_url(response, opts.url)

    metadata =
      opts |> Store.page_metadata() |> Map.merge(%{referrer_url: final, alias_url: final})

    with {:ok, bytes} <-
           Crawler.Store.Retained.bytes(
             if(opts[:body_resource], do: metadata, else: {body, metadata}),
             opts.max_analysis_bytes
           ),
         {:ok, receipt} <- Store.reserve_resource(opts, :source, bytes, Process.whereis(Store)),
         :ok <- Store.commit_resource(receipt, bytes) do
      {:ok, Map.put(opts, :page_resource, receipt)}
    end
  end

  defp retain_page_metadata(_body, _response, opts), do: {:ok, opts}

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

  defp record_referrer_url(response, opts) do
    final = final_url(response, opts[:url])

    opts =
      opts
      |> Map.put(:referrer_url, final)
      |> land_worker_entry(final)
      |> Cookies.assign_landed_site(final)

    {:ok, opts}
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

  defp drop_owned_alias(%{alias_url: url, alias_created: created?} = opts)
       when is_binary(url) do
    Store.rollback_alias({url, opts[:scope]}, opts[:generation], opts[:queue], created?)
  end

  defp drop_owned_alias(_opts), do: :ok

  defp final_url(response, fallback) do
    case Req.Response.get_private(response, :crawler_url) do
      url when is_binary(url) and url != "" -> URL.normalize(url)
      _ -> fallback
    end
  end

  defp stage_direct(prepared, credit, %{discovery_mode: :fetch, save_to: root})
       when is_binary(root),
       do: Producer.direct(prepared, credit)

  defp stage_direct(_prepared, _credit, _opts), do: :ok
end
