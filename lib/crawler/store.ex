defmodule Crawler.Store do
  @moduledoc """
  An internal data store for information related to each crawl.

  Pages live in a registry owned by this process, so they remain available
  after the worker that fetched them has finished. `drop_scope/1` removes one
  scope's pages and counters. Other scopes stay.

  `Crawler.stop/1` drops the stopped scope. When that call also stops the
  queue, other scopes on that queue keep processed pages and their counters.
  Only that queue's in-flight URLs and page slots are dropped. Work on
  other queues in the same scope continues. Retirement preserves the scope's
  generation while other work contexts remain.

  Crawl authority consists of the scope, its opaque generation, and the
  registered queue. Revocation returns `:stale` (or `{:error, :stale}` for
  result APIs). Cancellation does not represent successful completion.
  `dispose_scope/1` removes a stopped run without retaining a revision record.
  CSS entries use scope and generation keys. Revocation does not wait for the
  derived CSS cache; its bounded sweep removes retired entries asynchronously.
  Internal page writes pass the executing generation and queue separately from
  stored metadata. Reading a page does not transfer its authority to a worker.
  Run entry points bind missing authority before submitting work or claiming a
  slot. Job submission and claim acquisition reject missing as well as retired
  generations. Internal references preserve run identity and authority; only
  explicit crawl startup can reset or select a different run.

  Logical URLs use canonical URL identity for pages, aliases, and shared page
  counts. Request representations are the bytes fetched with a frozen effective
  request, including eligible credentials, cookies, headers, and partition.
  Interpretation contexts apply document bases, stylesheet groups, and script
  goals to those bytes. A logical URL alone does not establish representation
  equivalence; interpretation identity does not grant run authority.

  A Store restart invalidates every previous generation. Managed queues stop.
  External queues remain running, but their old work cannot change new pages,
  counters, or snapshots.

  A queued URL that fails, or whose handler crashes, stays recorded until that
  queue is idle in its scope. It is then dropped so a later crawl can fetch it
  again. Direct fetch registrations and processed pages stay until the scope
  is dropped.
  """

  alias Crawler.Store.DB
  alias Crawler.Store.Server
  alias Crawler.URL

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts \\ []) do
    GenServer.start_link(Server, opts, name: __MODULE__)
  end

  @doc """
  Finds a stored URL and returns its page data.
  """
  def find({url, scope}) do
    case Registry.lookup(DB, identity(url, scope)) do
      [{_, page}] -> page
      _ -> nil
    end
  end

  @doc """
  Finds a stored URL and returns its page data only if it's processed.
  """
  def find_processed({url, scope}) do
    case Registry.match(DB, identity(url, scope), %{processed: true}) do
      [{_, page}] -> page
      _ -> nil
    end
  end

  @doc """
  Adds a URL to the registry.
  """
  def add({url, scope}, generation \\ nil, queue \\ nil, fetch_tag \\ nil, target \\ nil) do
    call({:add, identity(url, scope), generation, queue, fetch_tag, target})
  end

  @doc false
  def fetch_in_flight?({url, scope}) do
    call({:fetch_in_flight?, identity(url, scope)})
  end

  @doc false
  def note_picture_type({url, scope}, content_type, generation, queue)
      when is_binary(content_type) do
    call({:note_picture_type, identity(url, scope), content_type, generation, queue})
  end

  def register_alias({url, scope}, generation, queue) do
    call({:register_alias, identity(url, scope), generation, queue})
  end

  def rollback_alias({url, scope}, generation, queue, created?) do
    call({:rollback_alias, identity(url, scope), generation, queue, created?})
  end

  def retain_alias({url, scope}, body, opts) do
    opts =
      Map.drop(opts, [
        :prepared_request,
        :analysis,
        :interpretation,
        :document_styles,
        :css_tokens,
        :css_references,
        :source_region,
        :cookie_proof,
        :css_obligation_receipt,
        :return_reservation,
        :return_workspace,
        :body_resource,
        :page_resource
      ])

    payload =
      {:retain_alias, identity(url, scope), identity(opts[:url], scope), body,
       Map.put(opts, :url, url)}

    with {:ok, workspace} <- reserve_resource(opts, :scratch, 98_304) do
      try do
        retain_alias_payload(opts, payload)
      after
        release_resource(workspace)
      end
    end
  end

  defp retain_alias_payload(opts, payload) do
    with {:ok, bytes} <- Crawler.Store.Retained.bytes(payload, opts.max_retained_bytes),
         {:ok, copy} <- Crawler.Store.Retained.copy_bytes(payload, opts.max_retained_bytes),
         {:ok, receipt} <-
           fund_export_receipt(
             opts,
             :source,
             bytes + copy + Crawler.Store.Settlements.bookkeeping_bytes(),
             nil
           ) do
      try do
        call(Tuple.append(payload, receipt))
      after
        release_resource(receipt)
      end
    end
  end

  @doc false
  def claim_custom_storage(opts) do
    context =
      Map.take(opts, [
        :scope,
        :generation,
        :queue,
        :execution_lease,
        :representation_id,
        :source_revision,
        :store,
        :url,
        :max_pending
      ])

    with {:ok, workspace} <- reserve_resource(opts, :scratch, 98_304) do
      try do
        with {:ok, bytes} <- Crawler.Store.Retained.bytes(context, opts.max_retained_bytes),
             {:ok, copy} <- Crawler.Store.Retained.copy_bytes(context, opts.max_retained_bytes),
             {:ok, receipt} <- fund_export_receipt(opts, :source, bytes + copy + 8192, nil) do
          try do
            call({:claim_custom_storage, context, receipt}, :infinity)
          after
            release_resource(receipt)
          end
        end
      after
        release_resource(workspace)
      end
    end
  end

  @doc false
  def finish_custom_storage(opts, success?) do
    context = Map.take(opts, [:scope, :generation, :queue, :execution_lease])
    call({:finish_custom_storage, context, success?})
  end

  def discard_retained_alias(ref), do: call({:discard_retained_alias, ref})
  def start_settlement(ref), do: call({:start_settlement, ref})

  def complete_settlement(ref, token),
    do: call({:complete_settlement, ref, token})

  def settlement_payload(ref, token, opts, bytes, callback) do
    with {:ok, receipt} <- fund_export_receipt(opts, :source, bytes, nil) do
      try do
        case call({:settlement_payload, ref, token, opts, receipt}) do
          {:ok, body, stored} -> callback.(body, stored)
          error -> error
        end
      after
        GenServer.call(__MODULE__, {:discard_export_pregrant, receipt})
        release_resource(receipt)
      end
    end
  end

  @doc """
  Adds the page data for a URL to the registry.
  """
  def add_page_data(key, body, opts) do
    add_page_data(key, body, opts, opts[:generation], opts[:queue])
  end

  @doc false
  def add_page_data(key, body, opts, generation, queue),
    do: put_page_data(key, body, opts, generation, queue, :immediate)

  @doc false
  def record_page_data(key, body, opts),
    do: put_page_data(key, body, opts, opts[:generation], opts[:queue], :recording)

  defp put_page_data({url, scope}, body, opts, generation, queue, role) do
    case Process.get(:crawler_execution_lease) do
      nil ->
        call({:add_page_data, identity(url, scope), body, opts, generation, queue, role})

      lease ->
        opts = page_metadata(opts)

        with {:ok, opts} <- fund_page_data(body, opts, lease) do
          call({:add_page_data, identity(url, scope), body, opts, generation, queue, role})
        end
    end
  end

  defp fund_page_data(_body, %{page_resource: receipt} = opts, _lease) when is_reference(receipt),
    do: {:ok, opts}

  defp fund_page_data(body, opts, lease) do
    limit = opts[:max_analysis_bytes] || Crawler.Limits.defaults().max_analysis_bytes

    with {:ok, bytes} <-
           Crawler.Store.Retained.bytes(
             if(opts[:body_resource], do: opts, else: {body, opts}),
             limit
           ),
         {:ok, receipt} <-
           reserve_resource(
             Map.put(opts, :execution_lease, lease),
             :source,
             bytes,
             Process.whereis(__MODULE__)
           ),
         :ok <- commit_resource(receipt, bytes) do
      {:ok, Map.put(opts, :page_resource, receipt)}
    end
  end

  @doc false
  def page_metadata(opts) do
    Map.drop(opts, [
      :prepared_request,
      :execution_lease,
      :scheduler_claim,
      :scheduler_mode,
      :cookie_proof,
      :crawler_deadline,
      :analysis,
      :interpretation,
      :document_styles,
      :css_tokens,
      :css_references,
      :source_region,
      :req_options,
      :modifier,
      :retrier,
      :return_reservation,
      :return_workspace,
      :before_publish
    ])
  end

  @doc """
  Marks a URL as processed in the registry.
  """
  def processed({url, scope}, generation \\ nil, queue \\ nil) do
    call({:processed, identity(url, scope), generation, queue})
  end

  def complete_page({url, scope}, generation, queue, alias_url \\ nil, count? \\ true) do
    alias_key = if is_binary(alias_url), do: identity(alias_url, scope)

    request = {:complete_page, identity(url, scope), alias_key, generation, queue, count?}

    case Process.get(:crawler_funded_page) do
      %Crawler.Store.Page{opts: %{scheduler_claim: claim} = opts}
      when not is_nil(alias_key) and not is_nil(claim) ->
        fund_alias_completion(request, claim, alias_key, opts)

      _ ->
        call(Tuple.append(request, nil))
    end
  end

  defp fund_alias_completion(request, claim, alias_key, opts) do
    with {:ok, workspace} <- reserve_resource(opts, :scratch, 98_304) do
      try do
        with {:ok, bytes} <-
               Crawler.Store.Retained.bytes({claim, alias_key}, opts.max_retained_bytes),
             {:ok, copy} <-
               Crawler.Store.Retained.copy_bytes({claim, alias_key}, opts.max_retained_bytes),
             {:ok, receipt} <- fund_export_receipt(opts, :source, bytes + copy + 8192, nil) do
          try do
            call(Tuple.append(request, receipt))
          after
            release_resource(receipt)
          end
        end
      after
        release_resource(workspace)
      end
    end
  end

  @doc """
  Removes one URL from the registry.
  """
  def delete({url, scope}, generation \\ nil, queue \\ nil) do
    call({:delete, identity(url, scope), generation, queue})
  end

  @doc """
  Removes every page and counter for `scope`.

  Returns a new generation token for the scope. A worker with the previous
  token cannot write into the next crawl.
  """
  def drop_scope(scope) do
    call({:drop_scope, scope})
  end

  @doc false
  def dispose_scope(scope), do: call({:dispose_scope, scope})

  @doc false
  def dispose_scope(scope, generation), do: call({:dispose_scope, scope, generation})

  @doc false
  def claim_robots(scope, origin, generation, queue \\ nil) do
    call({:claim_robots, scope, origin, generation, queue}, :infinity)
  end

  @doc false
  def finish_robots(scope, origin, rules, generation, queue \\ nil, context \\ %{}) do
    call({:finish_robots, scope, origin, rules, generation, queue, context})
  end

  @doc false
  def forget_robots(scope, origin, rules, generation, queue \\ nil) do
    call({:forget_robots, scope, origin, rules, generation, queue})
  end

  @doc false
  def save_cookies(scope, url, headers, generation \\ nil, context \\ %{})

  def save_cookies(nil, _url, _headers, _generation, _context), do: :ok

  def save_cookies(scope, url, headers, generation, context) do
    call({:save_cookies, scope, url, List.wrap(headers), generation, context})
  end

  @doc false
  def cookie_header(scope, url, generation \\ nil, context \\ %{})

  def cookie_header(nil, _url, _generation, _context), do: nil

  def cookie_header(scope, url, generation, context) do
    call({:cookie_header, scope, url, generation, context})
  end

  @doc """
  Returns the scope's current opaque generation token.

  Compare tokens for equality only. A scope reset or Store restart invalidates
  its previous token. Other scopes keep their tokens during a scope reset.
  """
  def generation(scope), do: call({:generation, scope})

  @doc false
  def bind_run(opts),
    do: call({:bind_execution_run, Crawler.Options.assign_defaults(Map.new(opts))})

  def current?(scope, generation, queue \\ nil) do
    call({:current?, scope, generation, queue})
  end

  @doc """
  Returns the URLs of pages kept in the store.
  """
  def all_urls do
    DB
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.map(fn {url, _scope} -> url end)
    |> Enum.uniq()
  end

  @doc """
  Counts processed pages for one crawl scope.
  """
  def ops_count(scope), do: call({:ops_count, scope})

  @doc """
  Counts processed pages across every crawl scope.
  """
  def ops_count, do: call(:ops_count)

  def ops_inc(scope \\ nil, generation \\ nil, queue \\ nil) do
    call({:ops_inc, scope, generation, queue})
  end

  def ops_reset, do: call(:ops_reset)

  @doc """
  Reserves a page slot for `scope` when the crawl is still under `max_pages`.

  The reservation counts as in flight until the worker finishes. Processed
  pages keep occupying a slot via `ops_inc/1`.
  """
  def try_claim(scope, max_pages, generation \\ nil, queue \\ nil) do
    call({:try_claim, scope, max_pages, generation, queue})
  end

  def finish_claim(token, reason \\ nil) do
    if is_nil(reason) or Crawler.Store.RunStatus.limit_reason(reason),
      do: call({:finish_claim, token, reason}),
      else: {:error, :invalid_limit}
  end

  def inflight_dec(scope, generation \\ nil, queue \\ nil) do
    call({:inflight_dec, scope, generation, queue})
  end

  def inflight_count(scope), do: call({:inflight_count, scope})

  def pending_count(scope), do: call({:pending_count, scope})

  @doc """
  Checks pending and in-flight work for one queue in a scope's generation.

  A retired queue or generation has no remaining work.
  """
  def work_pending?(scope, generation, queue) do
    call({:work_pending?, scope, generation, queue})
  end

  def note_enqueued(scope, generation, queue) do
    call({:note_enqueued, scope, generation, queue})
  end

  def finish_work(scope, generation, claimed?, queue \\ nil) do
    call({:finish_work, scope, generation, claimed?, queue})
  end

  def attach_owner(feeder, owner, scope) when is_pid(feeder) and is_pid(owner) do
    call({:attach_owner, feeder, owner, scope})
  end

  def queue_record(queue) when is_pid(queue) do
    call({:queue_record, queue})
  end

  def queue_record(_queue), do: nil

  def queue_scopes(queue) when is_pid(queue) do
    call({:queue_scopes, queue})
  end

  def queue_scopes(_queue), do: []

  def release_queue(queue) when is_pid(queue) do
    call({:release_queue, queue})
  end

  def release_queue(_queue), do: :ok

  @doc false
  def admit_job(opts, prepared, kind \\ :fetch),
    do: admit_job(opts, prepared, kind, :reference)

  @doc false
  def admit_job(opts, prepared, kind, ingress),
    do: call({:admit_job, opts, prepared, kind, ingress})

  def admit_direct(opts, prepared, deadline, kind \\ :fetch),
    do: call({:admit_direct, opts, prepared, deadline, kind}, :infinity)

  def await_direct(target, deadline), do: call({:await_direct, target, deadline}, :infinity)

  def checkout_job(queue), do: call({:checkout_job, queue})

  def complete_job(claim, outcome, origin \\ :completion),
    do: call({:complete_job, claim, Crawler.Job.Outcome.bounded(outcome), origin})

  def run_deadline(scope, generation), do: call({:run_deadline, scope, generation})

  @doc false
  def export_options(opts) do
    Map.take(
      opts,
      Map.keys(Crawler.Limits.defaults()) ++
        [
          :scope,
          :generation,
          :queue,
          :execution_lease,
          :scheduler_claim,
          :target_handle,
          :representation_id,
          :source_revision,
          :crawler_deadline,
          :run_deadline,
          :url,
          :save_to
        ]
    )
  end

  def export_context(opts) do
    case export_target_reply(opts, :context) do
      {:ok, nil, receipt} ->
        release_resource(receipt)
        {:ok, nil}

      {:ok, context, _receipt} ->
        {:ok, context}

      error ->
        error
    end
  end

  def export_status(opts, paused? \\ false), do: call({:export_status, Map.new(opts), paused?})
  def close_export(opts), do: call({:close_export, export_options(Map.new(opts))})

  def await_finalizer(target, deadline), do: call({:await_finalizer, target, deadline}, :infinity)

  def export_prepare_next(opts, epoch, token, cursor, limit \\ 1),
    do: export_reply(opts, {:prepare_next, epoch, token, cursor, limit})

  def export_seal(opts, epoch, token), do: export_reply(opts, {:seal, epoch, token})

  def export_refresh_batch(opts, epoch, limit \\ 16) do
    owner = Process.whereis(__MODULE__)

    with {:ok, metadata} <-
           reserve_resource(opts, :snapshot, Crawler.Store.ExportRun.refresh_bytes(), owner) do
      try do
        export_reply(opts, {:refresh_batch, epoch, limit, metadata})
      after
        release_resource(metadata, owner)
        release_resource(metadata)
      end
    end
  end

  def release_export_refresh(opts, epoch, receipt),
    do: call({:export, export_options(opts), {:refresh_release, epoch, receipt}})

  def export_group_versions(opts, epoch, groups) do
    with {:ok, receipt} <- reserve_resource(opts, :snapshot, min(opts.max_manifest_bytes, 65_536)) do
      case export_command(opts, {:group_versions, epoch, groups, receipt}) do
        {:ok, versions} ->
          {:ok, versions, receipt}

        error ->
          release_resource(receipt)
          error
      end
    end
  end

  def export_refresh_candidate(opts, epoch, target, version, descriptor, memberships),
    do:
      export_command(
        opts,
        {:refresh_candidate, epoch, target, version, descriptor, memberships}
      )

  def export_refresh_discovered(opts, epoch, target, version, groups, bound),
    do: export_command(opts, {:refresh_discovered, epoch, target, version, groups, bound})

  def export_prepared(opts, epoch, token, target, operation, edges) do
    export_command(opts, {:prepared, epoch, token, target, operation, edges})
  end

  defp export_command(opts, command) do
    opts = export_options(opts)

    with {:ok, workspace} <- reserve_resource(opts, :scratch, 98_304) do
      try do
        payload = {:export, opts, {:funded_command, make_ref(), workspace, command}}

        with {:ok, receipt} <- fund_payload_frame(opts, payload) do
          try do
            call({:export, export_options(opts), {:funded_command, receipt, workspace, command}})
          after
            release_resource(receipt)
          end
        end
      after
        release_resource(workspace)
      end
    end
  end

  def export_rendered(opts, epoch, seal, target, operation),
    do: call({:export, export_options(opts), {:rendered, epoch, seal, target, operation}})

  def export_commit(opts, epoch, token, seal, prepared, manifest_operation) do
    call(
      {:export, export_options(opts), {:commit, epoch, token, seal, prepared, manifest_operation}}
    )
  end

  defp export_reply(opts, command) do
    with {:ok, workspace} <- reserve_resource(opts, :scratch, 98_304) do
      try do
        with {:ok, receipt, _capacity} <-
               reserve_resource_up_to(opts, :snapshot, opts.max_manifest_bytes) do
          case call({:export, export_options(opts), {:funded_reply, receipt, command}}) do
            {:ok, result} ->
              {:ok, result, receipt}

            error ->
              release_resource(receipt)
              error
          end
        end
      after
        release_resource(workspace)
      end
    end
  end

  def export_filesystem(opts, epoch) do
    reference = make_ref()

    with {:ok, receipt} <- reserve_resource(opts, :snapshot, 65_536) do
      result =
        case call({:export, export_options(opts), {:filesystem, epoch, reference, receipt}}) do
          {:pending, ^reference} -> await_export_filesystem(reference, opts.crawler_deadline)
          result -> result
        end

      if match?({:error, _}, result), do: release_resource(receipt)
      result
    end
  end

  defp await_export_filesystem(reference, deadline) do
    receive do
      {:crawler_export_filesystem, ^reference, result} ->
        case Crawler.Deadline.check(deadline) do
          :ok -> result
          error -> error
        end
    after
      Crawler.Deadline.remaining(deadline) ->
        GenServer.cast(__MODULE__, {:export_waiter_done, reference, self()})
        {:error, {:deadline, deadline.kind}}
    end
  end

  def export_reserve(opts, epoch, operation, plan),
    do: call({:export, export_options(opts), {:reserve, epoch, operation, plan}})

  def export_written(opts, epoch, operation, ack),
    do: call({:export, export_options(opts), {:written, epoch, operation, ack}})

  def start_export_io(opts, epoch, nonce) do
    with {:ok, metadata} <- fund_export_receipt(opts, :source, 32_768, nil) do
      try do
        export_command(opts, {:io_start, epoch, nonce, metadata})
      after
        GenServer.call(__MODULE__, {:discard_export_pregrant, metadata})
        release_resource(metadata)
      end
    end
  end

  def export_io_ready(owner, lease, nonce),
    do: GenServer.call(owner, {:export_io_ready, lease, nonce})

  def export_render_funding(opts, epoch, funding),
    do: export_command(opts, {:render_funding, epoch, funding, :check})

  def export_finish_render(opts, epoch, funding, bytes),
    do: export_command(opts, {:render_funding, epoch, funding, {:commit, bytes}})

  def export_custody(opts, epoch, operation, io, credit) do
    with {:ok, metadata} <- fund_export_receipt(opts, :source, 32_768, nil) do
      try do
        call(
          {:export, export_options(opts), {:io_custody, epoch, operation, io, credit, metadata}}
        )
      after
        release_resource(metadata)
      end
    end
  end

  def export_deliver(opts, epoch, io, credit, payload) do
    with {:ok, receipt} <- fund_payload(opts, payload) do
      try do
        call({:export, export_options(opts), {:io_deliver, epoch, io, credit, receipt, payload}})
      after
        release_resource(receipt)
      end
    end
  end

  def export_settled(opts, epoch, operation, result),
    do: call({:export, export_options(opts), {:io_settled, epoch, operation, result}}, :infinity)

  def export_abandon(opts, epoch, operation, reason),
    do: call({:export, export_options(opts), {:io_abandon, epoch, operation, reason}})

  def acquire_decoded(opts, attempt) when is_reference(attempt) do
    with_decode_context(opts, fn context ->
      command = {:acquire_decoded, attempt, make_ref()}
      funded_source_request(opts, context, command)
    end)
  end

  def publish_decoded(opts, token, body, checkpoint, ownership) do
    limits = Map.new(Crawler.Limits.analysis(opts))

    with :ok <- Crawler.Store.SourceManager.validate_decoder(body, checkpoint, ownership, limits) do
      with_decode_context(opts, fn context ->
        capsule = %{
          source_revision: opts.source_revision,
          decode_context: %{content_type: context[:content_type], headers: context[:headers]},
          body: body,
          decoder_seed: checkpoint.budget,
          limits: limits,
          unavailable: checkpoint.unavailable,
          root_ownership: ownership,
          retained_receipts: [],
          backing_receipts: [],
          copy_receipt: make_ref()
        }

        funded_source_request(opts, context, {:publish_decoded, token, capsule})
      end)
    end
  end

  defp with_decode_context(opts, callback) do
    workspace_bytes = Crawler.Store.DecodedSource.context_workspace()

    with {:ok, workspace} <- reserve_resource(opts, :scratch, workspace_bytes) do
      try do
        context = analysis_context(opts)
        prepaid = %{retained_bytes: 0, workspace_bytes: workspace_bytes}

        with {:ok, _bytes} <-
               Crawler.Store.DecodedSource.context_bytes(
                 %{content_type: context[:content_type], headers: context[:headers]},
                 Crawler.Limits.decoded_context(opts),
                 prepaid
               ),
             do: callback.(context)
      after
        release_resource(workspace)
      end
    end
  end

  defp funded_source_request(opts, context, command) do
    with {:ok, receipt} <- fund_payload(opts, {:source_cache, context, command}) do
      command =
        case command do
          {:acquire_decoded, attempt, _} ->
            {:acquire_decoded, attempt, receipt}

          {:publish_decoded, token, capsule} ->
            {:publish_decoded, token, %{capsule | copy_receipt: receipt}}
        end

      try do
        call({:source_cache, context, command})
      after
        release_resource(receipt)
      end
    end
  end

  def acquire_analysis(opts, key, attempt) do
    context = analysis_context(opts)
    request = {:source_cache, context, {:acquire, key, attempt, make_ref()}}

    with {:ok, receipt} <- fund_payload(opts, request) do
      try do
        call({:source_cache, context, {:acquire, key, attempt, receipt}})
      after
        release_resource(receipt)
      end
    end
  end

  def publish_analysis(opts, token, analysis, ownership) do
    context = analysis_context(opts)

    entry = %{
      source_revision: opts.source_revision,
      lexical_key: analysis.lexical_key,
      analysis: analysis,
      root_ownership: ownership,
      retained_receipts: [],
      backing_receipts: [],
      copy_receipt: make_ref()
    }

    with {:ok, receipt} <-
           fund_payload(opts, {:source_cache, context, {:publish, token, entry}}) do
      try do
        call({:source_cache, context, {:publish, token, %{entry | copy_receipt: receipt}}})
      after
        release_resource(receipt)
      end
    end
  end

  defp analysis_context(opts) do
    Map.take(opts, [
      :scope,
      :generation,
      :queue,
      :execution_lease,
      :scheduler_claim,
      :target_handle,
      :representation_id,
      :source_revision,
      :content_type,
      :headers,
      :max_interpretations,
      :max_pending,
      :max_frontier_bytes,
      :max_analysis_bytes,
      :max_body,
      :max_retained_bytes
    ])
    |> Map.put(:analysis_limits, Map.new(Crawler.Limits.analysis(opts)))
  end

  defp fund_payload(opts, payload) do
    with {:ok, workspace} <- reserve_resource(opts, :scratch, 98_304) do
      try do
        fund_payload_frame(opts, payload)
      after
        release_resource(workspace)
      end
    end
  end

  defp fund_payload_frame(opts, payload) do
    with {:ok, bytes} <- Crawler.Store.Retained.bytes(payload, opts.max_retained_bytes),
         {:ok, copy} <- Crawler.Store.Retained.copy_bytes(payload, opts.max_retained_bytes),
         do: fund_export_receipt(opts, :response, max(bytes, copy), copy)
  end

  defp fund_export_receipt(opts, kind, bytes, copy) do
    with {:ok, receipt} <- reserve_resource(opts, kind, bytes, Process.whereis(__MODULE__)) do
      result =
        if is_nil(copy),
          do: commit_resource(receipt, bytes),
          else: commit_response_resource(receipt, bytes, copy)

      case result do
        :ok ->
          {:ok, receipt}

        error ->
          GenServer.call(__MODULE__, {:discard_export_pregrant, receipt})
          release_resource(receipt)
          error
      end
    end
  end

  def export_source_info(opts, epoch), do: export_target_reply(opts, {:source_info, epoch})

  def export_source(opts, epoch, operation, type, final_url),
    do: export_command(opts, {:source, epoch, operation, type, final_url})

  def arm_export(opts, epoch), do: export_command(opts, {:arm, epoch})

  def export_candidate(opts, epoch, version, descriptor, memberships),
    do: export_command(opts, {:candidate, epoch, version, descriptor, memberships})

  def export_discovered(opts, epoch, version, groups, bound),
    do: export_command(opts, {:discovered, epoch, version, groups, bound})

  defp export_target_reply(opts, command) do
    with {:ok, workspace} <- reserve_resource(opts, :scratch, 98_304) do
      try do
        with {:ok, receipt} <- reserve_resource(opts, :snapshot, 65_536) do
          case call({:export, export_options(opts), {:target_reply, receipt, command}}) do
            {:ok, result} ->
              {:ok, result, receipt}

            error ->
              release_resource(receipt)
              error
          end
        end
      after
        release_resource(workspace)
      end
    end
  end

  def target_outcome(handle), do: call({:target_outcome, handle})

  @doc false
  def run_status(opts, paused?) do
    authority = Map.take(opts, [:scope, :generation, :queue, :target_handle])
    call({:run_status, authority, paused?})
  end

  @doc false
  def report_run_limit(reason) do
    if Crawler.Store.RunStatus.limit_reason(reason),
      do: call({:report_run_limit, reason}),
      else: {:error, :invalid_limit}
  end

  def publish_source(opts, receipt, source), do: call({:publish_source, opts, receipt, source})
  def response_source(opts), do: call({:response_source, opts})
  def retry_direct(claim, deadline), do: call({:retry_direct, claim, deadline}, :infinity)
  def note_response(opts, reuse), do: call({:note_response, opts, reuse})

  def witness_source(opts, body, seed) do
    if Crawler.Store.Authority.export_managed?(opts.scope, opts.generation) do
      with :ok <-
             Crawler.Store.SourceManager.validate_decoder(
               body,
               %{budget: seed, unavailable: seed.retained},
               :borrowed,
               Crawler.Limits.analysis(opts)
             ),
           {:ok, workspace} <- reserve_resource(opts, :scratch, 98_304) do
        try do
          witness = %{
            revision: opts.source_revision,
            digest: :crypto.hash(:sha256, body),
            bytes: byte_size(body),
            root_ownership: :borrowed,
            decoder_seed: seed
          }

          with {:ok, receipt} <- fund_payload_frame(opts, witness) do
            try do
              call({:source_witness, export_options(opts), witness, receipt})
            after
              GenServer.call(__MODULE__, {:discard_export_pregrant, receipt})
              release_resource(receipt)
            end
          end
        after
          release_resource(workspace)
        end
      end
    else
      :ok
    end
  end

  def note_request_result(opts, outcome),
    do: call({:note_request_result, opts, Crawler.Job.Outcome.bounded(outcome)})

  def prepare_control(opts, prepared, receipt),
    do: call({:prepare_control, opts, prepared, receipt})

  @doc false
  def cookie_snapshot(scope, url, generation, context, expected),
    do: call({:cookie_snapshot, scope, url, generation, context, expected})

  def save_cookies_with_proof(scope, url, headers, generation, context, expected),
    do:
      call(
        {:save_cookies_with_proof, scope, url, List.wrap(headers), generation, context, expected}
      )

  def validate_cookie_proof(scope, generation, context, expected),
    do: call({:validate_cookie_proof, scope, generation, context, expected})

  def cookie_outcome(scope, generation \\ nil, queue \\ nil),
    do: GenServer.call(__MODULE__, {:cookie_outcome, scope, generation, queue})

  @doc false
  def account_control_document(opts), do: call({:control_document, opts})
  def account_control_bytes(opts, bytes), do: call({:control_bytes, opts, bytes})

  def control_transport_started(context), do: call({:control_transport_started, context})
  def control_transport_finished(context), do: call({:control_transport_finished, context})

  def account_control_entity(context, sequence, bytes),
    do: call({:control_entity, context, sequence, bytes})

  @doc false
  def schedule_css(opts, group, revision), do: call({:schedule_css, opts, group, revision})

  def complete_css(lease, group, revision, outcome),
    do: GenServer.call(__MODULE__, {:complete_css, lease, group, revision, outcome})

  def notify_css_revision(opts, group, revision, receipt),
    do: GenServer.cast(__MODULE__, {:css_revision, self(), opts, group, revision, receipt})

  @doc false
  def reserve_resource(opts, kind, bytes, holder \\ self()),
    do:
      GenServer.call(__MODULE__, {:reserve_resource, opts[:execution_lease], kind, bytes, holder})

  def resource_funding(opts, credit, holder \\ self()),
    do: call({:resource_funding, opts, credit, holder})

  def reserve_resource_up_to(opts, kind, maximum, holder \\ self()),
    do: call({:reserve_resource_up_to, opts, kind, maximum, holder})

  def commit_resource(receipt, bytes),
    do:
      GenServer.call(
        __MODULE__,
        {:commit_resource, resource_lease(), receipt, bytes}
      )

  def commit_response_resource(receipt, bytes, copy_bytes),
    do:
      GenServer.call(
        __MODULE__,
        {:commit_response_resource, resource_lease(), receipt, bytes, copy_bytes}
      )

  def retain_resource(receipt, holder),
    do:
      GenServer.call(
        __MODULE__,
        {:retain_resource, resource_lease(), receipt, holder}
      )

  def release_resource(receipt, holder \\ self()),
    do:
      GenServer.call(
        __MODULE__,
        {:release_resource, receipt, resource_lease(), holder}
      )

  def deliver_resource(receipt, holder, payload) do
    GenServer.call(
      __MODULE__,
      {:deliver_resource, receipt, Process.get(:crawler_execution_lease), holder, payload}
    )
  end

  def deliver_resource_async(receipt, lease, holder, payload, reply_to, delivery_ref) do
    GenServer.cast(
      __MODULE__,
      {:deliver_resource, receipt, lease, self(), holder, payload, reply_to, delivery_ref}
    )
  end

  @doc false
  def begin_execution(opts, deadline, observer \\ nil),
    do:
      call(
        {:begin_execution,
         opts
         |> Map.new()
         |> Map.put(:execution_observer, observer)
         |> Crawler.Options.assign_defaults(), deadline},
        :infinity
      )

  def begin_preparation(opts, deadline, observer) do
    limits =
      Map.take(opts, [
        :max_body,
        :max_analysis_bytes,
        :max_control_bytes,
        :max_control_documents,
        :max_retained_bytes
      ])

    GenServer.call(__MODULE__, {:begin_preparation, limits, deadline, observer}, :infinity)
  end

  def end_preparation(lease), do: GenServer.call(__MODULE__, {:end_preparation, lease})

  def prepare_execution_return(opts, caller, credit),
    do: GenServer.call(__MODULE__, {:prepare_execution_return, opts, caller, credit})

  def accept_execution_return(token),
    do: GenServer.call(__MODULE__, {:accept_execution_return, token})

  def discard_execution_return(executor) do
    {:ok, refs} = GenServer.call(__MODULE__, {:discard_execution_return, executor})
    flush_return_notifications(refs)

    receive do
      {:crawler_execution_revoked, ^executor, _lease, result} -> {:revoked, result}
    after
      0 -> :ok
    end
  end

  def release_page(%Crawler.Store.Page{credit: %{return_token: token}}) do
    {result, refs} = GenServer.call(__MODULE__, {:release_execution_return, token})
    flush_return_notifications(refs)
    result
  end

  def release_page(%Crawler.Store.Page{}), do: :ok

  defp flush_return_notifications(refs) do
    Enum.each(refs, fn ref ->
      receive do
        {:crawler_resource_abandon, ^ref, _lease} -> :ok
      after
        0 -> :ok
      end
    end)
  end

  def end_execution(lease), do: GenServer.call(__MODULE__, {:end_execution, lease})
  def expire_execution(executor), do: GenServer.call(__MODULE__, {:expire_execution, executor})

  defp resource_lease,
    do: Process.get(:crawler_execution_lease) || Process.get(:crawler_preparation_lease)

  defp call(request, timeout \\ 5_000) do
    case Process.get(:crawler_execution_lease) do
      nil -> GenServer.call(__MODULE__, request, timeout)
      lease -> GenServer.call(__MODULE__, {:execution, lease, request}, timeout)
    end
  end

  defp identity(url, scope) when is_binary(url), do: {URL.canonical(url), scope}
  defp identity(url, scope), do: {url, scope}
end
