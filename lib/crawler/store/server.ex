defmodule Crawler.Store.Server do
  @moduledoc false

  use GenServer

  alias Crawler.Frontier.Index
  alias Crawler.Robots
  alias Crawler.Store.Aliases
  alias Crawler.Store.Authority
  alias Crawler.Store.Claims
  alias Crawler.Store.DB
  alias Crawler.Store.Page
  alias Crawler.Store.PageCandidates
  alias Crawler.Store.ResourceManager
  alias Crawler.Store.Resources
  alias Crawler.Store.Settlements
  alias Crawler.Store.State

  @impl true
  def init(_opts) do
    await_registry_shutdown()
    Authority.init()
    {:ok, _} = Registry.start_link(keys: :unique, name: DB)

    {:ok, State.new()}
  end

  @impl true
  def handle_call({:execution, lease, request}, {worker, _} = from, state) do
    if Authority.execution_current?(lease, worker) do
      Process.put(:crawler_current_execution, lease)

      try do
        handle_call(request, from, state)
      after
        Process.delete(:crawler_current_execution)
      end
    else
      reply = if match?({:current?, _, _, _}, request), do: false, else: {:error, :stale}
      state = reject_export_pregrant(state, request, worker)
      {:reply, reply, reject_source_pregrant(state, request, worker)}
    end
  end

  def handle_call({:admit_job, opts, prepared, kind, ingress}, _from, state) do
    opts = Map.delete(opts, :crawler_ingress)
    scope = opts[:scope]

    ingress =
      if ingress === :root and is_nil(Process.get(:crawler_current_execution)) and
           State.count(state, :pending, scope) == 0 and
           State.count(state, :inflight, scope) == 0,
         do: :root,
         else: :reference

    reset? = opts[:force] == true and opts[:depth] == 0
    authorized? = admission_authorized?(state, opts, reset?)
    fresh? = is_nil(opts[:generation]) or reset?

    tentative =
      cond do
        reset? ->
          %{
            state
            | scopes: Map.put(state.scopes, scope, Crawler.Store.Scope.new()),
              cookies: Map.delete(state.cookies, scope),
              cookie_outcomes: Map.delete(state.cookie_outcomes, scope),
              cookie_bytes:
                state.cookie_bytes - Crawler.Cookies.Jar.retained_cost(state.cookies[scope])
          }

        fresh? ->
          State.ensure_scope(state, scope)

        true ->
          state
      end

    generation = if fresh?, do: State.generation(tentative, scope), else: opts.generation
    run = tentative.scopes[scope]

    deadline =
      if run,
        do:
          run.run_deadline || if(not reset?, do: opts[:run_deadline]) ||
            Crawler.Deadline.after_ms(opts.run_timeout, :run)

    opts = Map.merge(opts, %{generation: generation, run_deadline: deadline})

    with true <- authorized? and not is_nil(run) and State.current?(tentative, scope, generation),
         true <- queue_available?(tentative, opts[:queue]),
         :ok <- Crawler.Deadline.check(deadline),
         {{:ok, _, observation}, tentative} <-
           Crawler.Store.CookieProof.snapshot(
             tentative,
             scope,
             opts.url,
             generation,
             opts,
             :unbound
           ),
         {{:ok, _export}, tentative} <- Crawler.Store.ExportRun.prepare(tentative, opts) do
      opts = Map.put(opts, :cookie_proof, observation.proof)

      prepared =
        if prepared, do: Crawler.Fetcher.Requester.bind_cookie_proof(prepared, observation.proof)

      logical = Crawler.URL.canonical(opts.url)

      succeeded? =
        not reset? and
          case Registry.lookup(DB, {logical, scope}) do
            [{_, %Page{processed: true, opts: stored, target_handle: target}}] ->
              stored[:count_page] != false and
                counted_target?(tentative, target, {scope, generation})

            _ ->
              false
          end

      frontier =
        Crawler.Frontier.seed(
          tentative.scheduler.frontier,
          {scope, generation},
          run.ops,
          logical,
          succeeded?
        )

      tentative = %{tentative | scheduler: %{tentative.scheduler | frontier: frontier}}

      case Crawler.Store.Scheduler.admit(tentative.scheduler, opts, prepared, kind, ingress) do
        {status, handle, scheduler} when status in [:accepted, :existing] ->
          candidate = %{tentative | scheduler: scheduler}
          options = ResourceManager.options(candidate, opts)

          admission =
            Resources.admission(
              candidate.resources,
              {scope, generation},
              0,
              ResourceManager.envelope(opts),
              options
            )

          commit_job_admission(
            state,
            candidate,
            scheduler,
            opts,
            scope,
            generation,
            reset?,
            deadline,
            handle,
            admission
          )

        {:limited, key, _scheduler} ->
          {:reply, {:error, {:limit, key}}, note_limit(state, scope, generation, {:limit, key})}

        {:error, reason, _scheduler} ->
          {:reply, {:error, reason}, state}
      end
    else
      false -> {:reply, {:error, :stale}, state}
      {{:error, reason}, _candidate} -> {:reply, {:error, reason}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:admit_direct, opts, prepared, deadline, kind}, from, state)
      when kind in [:fetch, :css_settlement] do
    bytes = 16_384
    options = ResourceManager.options(state, opts)

    available =
      min(options.max_retained_bytes, state.resources.limit) -
        state.resources.used - options.external_frontier_bytes

    cond do
      map_size(state.direct_waiters) >= opts.max_pending ->
        {:reply, {:error, {:limit, :max_pending}}, state}

      bytes > available ->
        {:reply, {:error, {:limit, :max_retained_bytes}}, state}

      Crawler.Deadline.check(deadline) != :ok ->
        {:reply, {:error, {:deadline, deadline.kind}}, state}

      true ->
        candidate = %{state | waiting_bytes: state.waiting_bytes + bytes}

        case handle_call({:admit_job, opts, prepared, kind, :reference}, from, candidate) do
          {:reply, {:ok, admitted}, candidate} ->
            reply_direct_admission(state, candidate, admitted, from, deadline, bytes)

          {:reply, error, _candidate} ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:await_direct, target, deadline}, from, state) do
    case state.scheduler.frontier.jobs[target] do
      nil ->
        {:reply, {:error, :stale}, state}

      %{outcome: %Crawler.Job.Outcome{} = outcome} ->
        {:reply, {:terminal, outcome, %{target_handle: target}}, state}

      %{job: job} = record ->
        with {:ok, bytes} <- direct_waiter_capacity(state, job.opts, deadline),
             true <-
               current_work?(
                 state,
                 elem(job.authority, 0),
                 elem(job.authority, 1),
                 elem(job.authority, 2)
               ) do
          owner? =
            is_nil(elem(job.authority, 2)) and
              record.status != {:waiting, :finalizer_driver} and
              not Map.has_key?(state.direct_owners, target)

          state = %{state | waiting_bytes: state.waiting_bytes + bytes}

          {:noreply,
           schedule_frontier(enroll_direct(state, from, target, deadline, owner?, bytes))}
        else
          {:error, _} = error -> {:reply, error, state}
          false -> {:reply, {:error, :stale}, state}
        end
    end
  end

  def handle_call({:retry_direct, claim, deadline}, {worker, _} = from, state) do
    with %{worker: ^worker, job: job, monitor: monitor} <- state.scheduler_workers[claim],
         lease when is_reference(lease) <- state.execution_workers[worker],
         %{
           status: :returned,
           direct_retry?: true,
           arena: arena,
           deadline: ^deadline,
           opts: %{scheduler_claim: ^claim}
         } <- state.executions[lease],
         %{job: target} <- state.scheduler.claims[claim],
         true <- target === job.id,
         {:ok, bytes} <- direct_waiter_capacity(state, job.opts, deadline),
         {scope, generation, nil} <- job.authority,
         true <- current_work?(state, scope, generation, nil),
         scheduler = Crawler.Store.Scheduler.park(state.scheduler, claim, :direct_retry),
         %{status: {:waiting, :direct_retry}} <- scheduler.frontier.jobs[job.id] do
      {_, state} = ResourceManager.transition(state, Resources.close(state.resources, arena))
      state = release_execution(state, lease)
      state = reattempt_representation(%{state | scheduler: scheduler}, job, job.id)
      state = %{state | waiting_bytes: state.waiting_bytes + bytes}
      state = enroll_direct(state, from, job.id, deadline, true, bytes)
      Process.demonitor(monitor, [:flush])
      state = PageCandidates.release(state, claim)

      state = %{
        state
        | scheduler_workers: Map.delete(state.scheduler_workers, claim),
          scheduler_monitors: Map.delete(state.scheduler_monitors, monitor)
      }

      {:noreply, schedule_frontier(state)}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:checkout_job, queue}, {worker, _}, state) do
    case Crawler.Store.Scheduler.checkout(state.scheduler, queue) do
      {:ok, claim, :terminal, job, scheduler} ->
        {reply, state} = replay_terminal(%{state | scheduler: scheduler}, claim, job)
        {:reply, reply, schedule_frontier(state)}

      {:ok, claim, mode, job, scheduler} ->
        monitor = Process.monitor(worker)

        state = %{
          state
          | scheduler: scheduler,
            scheduler_monitors: Map.put(state.scheduler_monitors, monitor, claim),
            scheduler_workers:
              Map.put(state.scheduler_workers, claim, %{
                worker: worker,
                monitor: monitor,
                job: job
              })
        }

        opts = claimed_options(job, claim, mode)

        {:reply, {:ok, claim, job.kind, opts}, schedule_frontier(state)}

      {:maintenance, scheduler} ->
        {:reply, :empty, schedule_frontier(%{state | scheduler: scheduler})}

      :empty ->
        checkout_settlement(state, queue, worker)
    end
  end

  def handle_call({:complete_job, claim, outcome, origin}, {worker, _}, state)
      when origin in [:completion, :local] do
    case state.scheduler_workers[claim] do
      %{worker: ^worker} ->
        {:reply, :ok, complete_scheduler_claim(state, claim, outcome, origin)}

      _ ->
        {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:export_status, opts, paused?}, _from, state) when is_boolean(paused?) do
    if current_work?(state, opts[:scope], opts[:generation], opts[:queue]),
      do: {:reply, Crawler.Store.ExportRun.status(state, opts, paused?), state},
      else: {:reply, Crawler.Store.ExportRun.retired_status(state, opts, paused?), state}
  end

  def handle_call({:run_status, opts, paused?}, _from, state) when is_boolean(paused?) do
    {:reply, Crawler.Store.RunStatus.read(state, opts, paused?), state}
  end

  def handle_call({:report_run_limit, reason}, {worker, _}, state) do
    lease = Process.get(:crawler_current_execution)

    with %{worker: ^worker, opts: opts, observer: observer} <- state.executions[lease],
         true <- current_claim_execution?(state, Map.put(opts, :execution_lease, lease), worker),
         %{worker: claimant, job: job} <- state.scheduler_workers[opts[:scheduler_claim]],
         true <- claimant === worker or claimant === observer,
         true <- job.authority === {opts[:scope], opts[:generation], opts[:queue]},
         reason when not is_nil(reason) <- Crawler.Store.RunStatus.limit_reason(reason) do
      {:reply, :ok, note_limit(state, opts[:scope], opts[:generation], reason)}
    else
      _ -> {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:close_export, opts}, _from, state) do
    if current_work?(state, opts[:scope], opts[:generation], opts[:queue]) do
      {reply, state} = Crawler.Store.ExportRun.close(state, opts)
      {:reply, reply, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:await_finalizer, target, deadline}, from, state) do
    with %{job: %{kind: :finalize} = job, status: {:waiting, :finalizer_driver}} <-
           state.scheduler.frontier.jobs[target],
         key = Crawler.Frontier.run_key(job),
         %{helper: %{finalizer: %{id: ^target}}, failure: nil} <- state.exports[key],
         {:ok, bytes} <- direct_waiter_capacity(state, job.opts, deadline),
         {:ok, frontier} <- Crawler.Frontier.resume(state.scheduler.frontier, target) do
      state = %{
        state
        | scheduler: %{state.scheduler | frontier: frontier},
          waiting_bytes: state.waiting_bytes + bytes
      }

      {:noreply, schedule_frontier(enroll_direct(state, from, target, deadline, true, bytes))}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :stale_finalizer}, state}
    end
  end

  def handle_call({:export, opts, command}, {worker, _} = from, state) do
    with true <- current_claim_execution?(state, opts, worker),
         %{worker: claimant, job: %{id: target}} <-
           state.scheduler_workers[opts[:scheduler_claim]],
         true <-
           claimant === worker or claimant === state.executions[opts.execution_lease].observer,
         true <- target == opts[:target_handle],
         %{job: job} <- state.scheduler.frontier.jobs[target] do
      export_request(state, opts, job, command, from)
    else
      _ ->
        {:reply, {:error, :stale},
         reject_export_pregrant(state, {:export, opts, command}, worker)}
    end
  end

  def handle_call({:source_cache, opts, command} = request, {worker, _}, state) do
    if current_source_execution?(state, opts, worker) do
      {reply, state} = Crawler.Store.SourceManager.request(state, opts, command, worker)
      {:reply, reply, state}
    else
      {:reply, {:error, :stale}, reject_source_pregrant(state, request, worker)}
    end
  end

  def handle_call({:export_io_ready, lease, nonce}, {io, _}, state) do
    {reply, state} = Crawler.Store.ExportIO.ready(state, lease, nonce, io)
    {:reply, reply, state}
  end

  def handle_call({:source_witness, opts, witness, receipt}, {worker, _}, state) do
    if current_source_execution?(state, opts, worker) do
      {reply, state} = Crawler.Store.SourceWitness.record(state, opts, witness, receipt, worker)
      {:reply, reply, state}
    else
      {:reply, {:error, :stale},
       release_rejected_pregrant(state, opts, worker, receipt, :response)}
    end
  end

  def handle_call({:discard_export_pregrant, receipt}, {worker, _}, state) do
    state =
      case Resources.receipt(state.resources, receipt) do
        %{kind: kind, lease: lease} when kind in [:source, :response] ->
          release_rejected_pregrant(state, %{execution_lease: lease}, worker, receipt, kind)

        _ ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call({:run_deadline, scope, generation}, _from, state) do
    if is_nil(generation) or State.current?(state, scope, generation) do
      run = state.scopes[scope]
      {:reply, {:ok, if(run, do: run.run_deadline)}, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:target_outcome, handle}, _from, state),
    do: {:reply, Crawler.Frontier.outcome(state.scheduler.frontier, handle), state}

  def handle_call({:cookie_outcome, scope, generation, queue}, _from, state) do
    if State.current?(state, scope, generation) and queue_available?(state, queue) and
         State.queue_active?(state, scope, queue) do
      {:reply, {:ok, Crawler.Store.CookieProof.outcome(state, scope)}, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:publish_source, opts, receipt, source}, {worker, _}, state) do
    lease = opts[:execution_lease]

    if Authority.execution_current?(lease, worker) and
         Authority.resource_current?(receipt, lease, self()) do
      reuse = Crawler.Fetcher.Requester.reuse_disposition(source)
      {valid?, state} = reusable_source(state, reuse, opts)

      reuse =
        if valid?,
          do: reuse,
          else: %{reuse | disposition: :private, reason: :cookie_state_changed}

      previous =
        case state.scheduler.claims[opts.scheduler_claim] do
          %{representation: id} -> state.scheduler.representations[id].source
          _ -> nil
        end

      case Crawler.Store.Scheduler.publish(state.scheduler, opts.scheduler_claim, %{
             value: source,
             receipt: receipt,
             reuse: reuse
           }) do
        {:ok, scheduler} ->
          state = retire_replaced_source(%{state | scheduler: scheduler}, previous, receipt)

          operation =
            if reuse.disposition == :candidate,
              do: Resources.adopt(state.resources, receipt, self()),
              else: {:ok, state.resources, []}

          {_, state} = ResourceManager.transition(state, operation)

          state =
            if reuse.disposition == :candidate,
              do: %{state | source_resources: MapSet.put(state.source_resources, receipt)},
              else: state

          state = remember_physical_source(state, lease, source)
          {:reply, :ok, schedule_frontier(state)}

        {:error, reason, _} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:response_source, opts}, {worker, _}, state) do
    with true <- Authority.execution_current?(opts[:execution_lease], worker),
         %{arena: arena} <- state.executions[opts.execution_lease],
         {:ok, source} <-
           Crawler.Store.Scheduler.response(state.scheduler, opts.representation_id) do
      {reusable?, state} = reusable_source(state, source.reuse, opts)

      if not reusable? do
        scheduler = Crawler.Store.Scheduler.invalidate(state.scheduler, opts.representation_id)

        state =
          if is_nil(opts[:queue]) do
            execution = Map.put(state.executions[opts.execution_lease], :direct_retry?, true)

            %{
              state
              | executions: Map.put(state.executions, opts.execution_lease, execution),
                scheduler: scheduler
            }
          else
            %{state | scheduler: Crawler.Store.Scheduler.park(scheduler, opts.scheduler_claim)}
          end

        {:reply, {:error, :representation_deferred}, schedule_frontier(state)}
      else
        {reply, state} =
          ResourceManager.transition(
            state,
            Resources.retain_from(
              state.resources,
              source.receipt,
              arena,
              opts.execution_lease,
              self(),
              worker,
              :backing
            )
          )

        if reply == :ok do
          {_, state} =
            ResourceManager.transition(
              state,
              Resources.adopt(state.resources, source.receipt, worker)
            )

          state = remember_physical_source(state, opts.execution_lease, source.value)
          {:reply, {:ok, source.value}, state}
        else
          {:reply, reply, state}
        end
      end
    else
      _ -> {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:prepare_control, opts, prepared, receipt}, {worker, _}, state) do
    lease = opts[:execution_lease]
    claim = opts[:scheduler_claim]

    with true <- Authority.execution_current?(lease, worker),
         true <- Authority.resource_current?(receipt, lease, self()),
         %{job: id} <- state.scheduler.claims[claim],
         %{job: %{kind: :sitemap, prepared_request: nil} = job} <-
           state.scheduler.frontier.jobs[id],
         {{:ok, _header, observation}, candidate} <-
           Crawler.Store.CookieProof.snapshot(
             state,
             opts.scope,
             opts.url,
             opts.generation,
             opts,
             :unbound
           ),
         prepared = Crawler.Fetcher.Requester.bind_cookie_proof(prepared, observation.proof),
         stored =
           Map.merge(job.opts, %{
             cookie_proof: observation.proof,
             crawler_deadline: opts.crawler_deadline
           }),
         {:ok, bytes} <- Crawler.Store.Retained.bytes({stored, prepared}, opts.max_frontier_bytes) do
      scheduler =
        Crawler.Store.Scheduler.prepare_control(
          candidate.scheduler,
          claim,
          prepared,
          stored,
          bytes
        )

      before = Crawler.Frontier.bytes(candidate.scheduler.frontier)
      after_bytes = Crawler.Frontier.bytes(scheduler.frontier)

      delta =
        max(after_bytes.metadata + after_bytes.payload - before.metadata - before.payload, 0)

      {funded, candidate} =
        ResourceManager.transition(
          candidate,
          Resources.transfer_external(
            candidate.resources,
            candidate.executions[lease].arena,
            lease,
            delta
          )
        )

      if funded == :ok do
        {_, candidate} =
          ResourceManager.transition(
            candidate,
            Resources.adopt(candidate.resources, receipt, self())
          )

        {_, candidate} =
          ResourceManager.transition(
            candidate,
            Resources.release(candidate.resources, receipt, self())
          )

        workers =
          Map.update!(
            candidate.scheduler_workers,
            claim,
            &%{&1 | job: scheduler.frontier.jobs[id].job}
          )

        candidate = %{candidate | scheduler: scheduler, scheduler_workers: workers}

        candidate =
          case Crawler.Frontier.outcome(scheduler.frontier, id) do
            %{status: :limited, reason: reason} ->
              note_limit(candidate, opts.scope, opts.generation, reason)

            _ ->
              candidate
          end

        {:reply, :ok, schedule_frontier(candidate)}
      else
        {:reply, {:error, {:limit, :max_retained_bytes}}, state}
      end
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :stale}, state}
    end
  end

  def handle_call(
        {:note_request_result, opts, %Crawler.Job.Outcome{} = outcome},
        {worker, _},
        state
      ) do
    claim = opts[:scheduler_claim]

    if current_claim_execution?(state, opts, worker) do
      scheduler = Crawler.Store.Scheduler.note_request_result(state.scheduler, claim, outcome)
      {:reply, :ok, %{state | scheduler: scheduler}}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:note_response, opts, reuse}, {worker, _}, state) do
    if current_claim_execution?(state, opts, worker) do
      {valid?, state} = reusable_source(state, reuse, opts)
      reuse = if valid?, do: reuse, else: nil

      scheduler =
        Crawler.Store.Scheduler.note_response(state.scheduler, opts.scheduler_claim, reuse)

      state = %{state | scheduler: scheduler}

      state =
        if is_nil(reuse), do: clear_physical_source(state, opts.execution_lease), else: state

      {:reply, :ok, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:begin_preparation, limits, deadline, observer}, {worker, _} = from, state) do
    with :ok <- Crawler.Deadline.check(deadline),
         true <- is_pid(observer) and Process.alive?(observer),
         true <- is_nil(state.execution_workers[worker]) do
      lease = make_ref()

      opts =
        Map.merge(limits, %{
          scope: nil,
          generation: lease,
          queue: nil,
          execution_observer: observer,
          preparation?: true
        })

      options = ResourceManager.options(state, opts)
      acquire_execution(state, opts, deadline, from, worker, lease, {nil, lease}, options, true)
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:end_preparation, lease}, {worker, _}, state) do
    case state.executions[lease] do
      %{worker: ^worker, preparation?: true, arena: arena} ->
        {_, state} = ResourceManager.transition(state, Resources.close(state.resources, arena))
        {:reply, :ok, release_execution(state, lease)}

      _ ->
        {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:begin_execution, opts, deadline}, {worker, _} = from, state) do
    if current_work?(state, opts[:scope], opts[:generation], opts[:queue]) and
         Crawler.Deadline.check(deadline) == :ok do
      lease = make_ref()
      run = {opts[:scope], opts[:generation]}
      options = ResourceManager.options(state, opts)

      acquire_execution(state, opts, deadline, from, worker, lease, run, options)
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:schedule_css, opts, group, revision}, {worker, _}, state) do
    lease = opts[:execution_lease]
    key = {{opts[:scope], opts[:generation]}, group}

    if Authority.execution_current?(lease, worker) and
         Authority.export_writable?(opts[:scope], opts[:generation], opts[:queue], lease) do
      record = state.css_jobs[key]

      cond do
        record && record.settled == revision and opts[:scheduler_kind] != :css_settlement ->
          {:reply, {:ok, :settled}, state}

        record && record.owner && record.owner != lease ->
          record = %{record | revision: revision}
          {:reply, {:ok, :queued}, put_css_record(state, key, record)}

        true ->
          record =
            record || css_record(opts, revision)

          record = %{
            record
            | owner: lease,
              revision: revision,
              active_revision: revision,
              queued?: false
          }

          keys =
            Map.get(state.css_executions, lease, Crawler.Frontier.Ring.new())
            |> Crawler.Frontier.Ring.put(key)

          state = put_css_record(state, key, record)

          {:reply, {:ok, :compute},
           %{
             state
             | css_run_jobs: index_css_run(state, key),
               css_executions: Map.put(state.css_executions, lease, keys)
           }}
      end
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:complete_css, lease, group, revision, outcome}, {worker, _}, state) do
    case state.executions[lease] do
      %{opts: %{scope: scope, generation: generation}} ->
        key = {{scope, generation}, group}

        case state.css_jobs[key] do
          %{owner: ^lease} = record ->
            complete_owned_css(state, lease, worker, key, record, revision, outcome)

          _ ->
            {:reply, {:error, :stale}, state}
        end

      _ ->
        {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:resource_funding, opts, credit, holder}, {worker, _}, state) do
    lease = opts[:execution_lease]

    if Authority.execution_current?(lease, worker) and
         current_work?(state, opts[:scope], opts[:generation], opts[:queue]) do
      {:reply, Crawler.Export.StagedIO.funding(state.resources, credit, lease, holder), state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:reserve_resource, lease, kind, bytes, holder}, {worker, _}, state) do
    with true <- resource_execution_current?(state, lease, worker),
         %{arena: arena} <- state.executions[lease],
         true <- is_pid(holder) and Process.alive?(holder) do
      {reply, state} =
        ResourceManager.transition(
          state,
          Resources.reserve(state.resources, arena, lease, kind, bytes, holder)
        )

      {:reply, reply, state}
    else
      _ -> {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:reserve_resource_up_to, opts, kind, maximum, holder}, {worker, _}, state) do
    lease = opts[:execution_lease]

    with true <- resource_execution_current?(state, lease, worker),
         %{arena: arena} <- state.executions[lease],
         true <- current_work?(state, opts[:scope], opts[:generation], opts[:queue]) do
      {reply, state} =
        ResourceManager.transition(
          state,
          Resources.reserve_up_to(state.resources, arena, lease, kind, maximum, holder)
        )

      {:reply, reply, state}
    else
      _ -> {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:commit_resource, lease, receipt, bytes}, {worker, _}, state) do
    if resource_execution_current?(state, lease, worker) do
      {reply, state} =
        ResourceManager.transition(
          state,
          Resources.commit(state.resources, receipt, lease, bytes)
        )

      {:reply, reply, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call(
        {:commit_response_resource, lease, receipt, bytes, copy_bytes},
        {worker, _},
        state
      ) do
    if resource_execution_current?(state, lease, worker) do
      {reply, state} =
        ResourceManager.transition(
          state,
          Resources.commit_response(state.resources, receipt, lease, bytes, copy_bytes)
        )

      {:reply, reply, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:retain_resource, lease, receipt, holder}, {worker, _}, state) do
    with true <- resource_execution_current?(state, lease, worker),
         %{arena: arena} <- state.executions[lease],
         %{run: run} <- Resources.receipt(state.resources, receipt),
         %{opts: %{scope: scope, generation: generation}} <- state.executions[lease],
         true <- run === {scope, generation} do
      {reply, state} =
        ResourceManager.transition(
          state,
          Resources.retain_from(state.resources, receipt, arena, lease, worker, holder)
        )

      {:reply, reply, state}
    else
      _ -> {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:release_resource, receipt, lease, holder}, {worker, _}, state) do
    if worker == holder or Authority.resource_current?(receipt, lease, worker) do
      {reply, state} =
        ResourceManager.transition(state, Resources.release(state.resources, receipt, holder))

      {:reply, reply, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:deliver_resource, receipt, lease, holder, payload}, {worker, _}, state) do
    ref = make_ref()
    reply = relay_resource(receipt, lease, worker, holder, payload, worker, ref)

    state =
      if reply == :ok,
        do: %{state | resource_relays: Map.put(state.resource_relays, receipt, holder)},
        else: state

    {:reply, if(reply == :ok, do: {:ok, ref}, else: reply), state}
  end

  def handle_call({:prepare_execution_return, opts, caller, credit}, {worker, _}, state) do
    if resource_execution_current?(state, opts[:execution_lease], worker) do
      {reply, state} = Crawler.Store.Returns.prepare(state, opts, caller, credit, worker)
      {:reply, reply, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:accept_execution_return, token}, {caller, _}, state) do
    {reply, state} = Crawler.Store.Returns.accept(state, token, caller)
    {:reply, reply, state}
  end

  def handle_call({:release_execution_return, token}, {caller, _}, state) do
    refs = Crawler.Store.Returns.references_for(state, token, caller)
    {reply, state} = Crawler.Store.Returns.release(state, token, caller)
    {:reply, {reply, refs}, state}
  end

  def handle_call({:discard_execution_return, producer}, {caller, _}, state) do
    refs = Crawler.Store.Returns.pending_references(state, producer, caller)
    {:reply, {:ok, refs}, Crawler.Store.Returns.discard(state, producer, caller)}
  end

  def handle_call({:end_execution, lease}, {worker, _}, state) do
    case state.executions[lease] do
      %{worker: ^worker} ->
        state = debit_and_revoke_execution(state, lease)
        record = state.executions[lease]
        Process.cancel_timer(record.timer)

        {:reply, :ok,
         %{
           state
           | executions: Map.put(state.executions, lease, Map.put(record, :status, :returned))
         }}

      _ ->
        {:reply, :stale, state}
    end
  end

  def handle_call({:expire_execution, executor}, _from, state) do
    state =
      case state.direct_workers[executor] do
        nil -> state
        reference -> abandon_direct(state, reference)
      end

    state =
      case state.execution_workers[executor] do
        nil -> state
        lease -> revoke_execution(state, lease)
      end

    state =
      case state.waiting_workers[executor] do
        nil ->
          state

        reference ->
          record = state.pending_executions[reference]
          GenServer.reply(record.from, {:error, {:deadline, record.deadline.kind}})
          remove_execution_waiter(state, reference)
      end

    {:reply, :ok, state}
  end

  def handle_call({:add, {url, scope} = key, generation, queue, fetch_tag, target}, _from, state) do
    if current_work?(state, scope, generation, queue) do
      result =
        case Registry.lookup(DB, key) do
          [{pid, _page}] ->
            {:error, {:already_registered, pid}}

          [] ->
            Registry.register(DB, key, %Page{
              url: url,
              fetch_tag: fetch_tag,
              target_handle: target,
              storage_revision: make_ref()
            })
        end

      state = if match?({:ok, _}, result), do: State.track_page(state, key, queue), else: state
      {:reply, result, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:fetch_in_flight?, key}, {worker, _tag}, state) do
    {:reply, Aliases.in_use?(state, key, worker), state}
  end

  def handle_call(
        {:note_picture_type, {_url, scope} = key, content_type, generation, queue},
        _from,
        state
      ) do
    result =
      if current_work?(state, scope, generation, queue) do
        Registry.update_value(DB, key, &%{&1 | picture_type: content_type})
        :ok
      else
        {:error, :stale}
      end

    {:reply, result, state}
  end

  def handle_call({:register_alias, {_url, scope} = key, generation, queue}, {worker, _}, state) do
    if current_work?(state, scope, generation, queue) do
      {result, state} = Aliases.register(state, key, queue, worker)
      {:reply, result, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:claim_custom_storage, opts, receipt}, from, state),
    do: Crawler.Store.CustomStorage.claim(state, opts, receipt, from)

  def handle_call({:finish_custom_storage, opts, success?}, {worker, _}, state),
    do: {:reply, :ok, Crawler.Store.CustomStorage.finish(state, opts, success?, worker)}

  def handle_call({:retain_alias, key, source_key, body, opts, receipt}, {worker, _}, state) do
    lease = opts[:execution_lease]

    valid? =
      current_claim_execution?(state, opts, worker) and
        state.executions[lease][:source_revision] === opts[:source_revision] and
        alias_representation?(state, opts) and
        case Resources.receipt(state.resources, receipt) do
          %{kind: :source, lease: ^lease, executor: ^worker, actual: actual, holders: holders}
          when is_integer(actual) ->
            actual >= Settlements.bookkeeping_bytes() and
              match?(%{status: :pending, lease: ^lease, origin: ^worker}, holders[self()]) and
              Crawler.Store.Retained.bytes(
                {:retain_alias, key, source_key, body, opts, receipt},
                actual - Settlements.bookkeeping_bytes()
              ) != {:error, {:limit, :max_retained_bytes}}

          _ ->
            false
        end

    if valid? do
      {reply, state} = Settlements.retain(state, key, source_key, body, opts, worker, receipt)
      state = ResourceManager.release_owner(state, receipt)
      {:reply, reply, state}
    else
      state = release_rejected_pregrant(state, opts, worker, receipt, :source)
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:discard_retained_alias, ref}, {worker, _}, state) do
    {:reply, :ok, Settlements.discard(state, ref, worker)}
  end

  def handle_call({:start_settlement, ref}, {worker, _}, state) do
    {reply, state} = start_settlement(state, ref, worker)
    {:reply, reply, state}
  end

  def handle_call({:settlement_payload, ref, token, opts, receipt}, {worker, _}, state) do
    lease = opts[:execution_lease]
    candidate = state.settlements.candidates[ref]

    valid? =
      match?(%Settlements.Candidate{status: {:running, ^token}}, candidate) and
        current_claim_execution?(state, opts, worker) and
        {opts.scope, opts.generation, opts.queue} ===
          {elem(candidate.key, 1), candidate.generation, candidate.queue} and
        case Resources.receipt(state.resources, receipt) do
          %{kind: :source, lease: ^lease, executor: ^worker, actual: actual, holders: holders}
          when is_integer(actual) ->
            match?(%{status: :pending, lease: ^lease, origin: ^worker}, holders[self()]) and
              actual >= Resources.receipt(state.resources, hd(candidate.resources)).actual

          _ ->
            false
        end

    if valid? do
      stored =
        candidate.opts
        |> Map.drop([:scheduler_claim, :scheduler_mode])
        |> Map.merge(%{
          execution_lease: lease,
          crawler_deadline: opts.crawler_deadline,
          page_resource: receipt,
          body_resource: nil
        })

      source =
        {candidate.opts.representation_id, candidate.opts.source_revision, candidate.opts.store,
         elem(candidate.key, 0)}

      execution = Map.put(state.executions[lease], :custom_storage_source, source)
      state = %{state | executions: Map.put(state.executions, lease, execution)}
      {:reply, {:ok, candidate.body, stored}, state}
    else
      state = release_rejected_pregrant(state, opts, worker, receipt, :source)
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:complete_settlement, ref, token}, {worker, _}, state) do
    state =
      if Claims.owned?(state.claims, token, worker),
        do: Settlements.complete(state, ref, token),
        else: state

    {:reply, :ok, schedule_frontier(state)}
  end

  def handle_call(
        {:rollback_alias, {_url, scope} = key, generation, queue, created?},
        {worker, _},
        state
      ) do
    if current_work?(state, scope, generation, queue) do
      {:reply, :ok, Aliases.rollback(state, key, queue, worker, created?)}
    else
      {:reply, :stale, state}
    end
  end

  def handle_call(
        {:add_page_data, {_url, scope} = key, body, opts, generation, queue, role},
        {worker, _},
        state
      ) do
    lease = Process.get(:crawler_current_execution)
    receipt = opts[:page_resource]
    backing = opts[:body_resource]
    refs = ResourceManager.page_receipts(opts)

    old_refs =
      case Registry.lookup(DB, key) do
        [{_, %{opts: stored}}] when is_map(stored) -> ResourceManager.page_receipts(stored)
        _ -> MapSet.new()
      end

    state =
      if lease,
        do: ensure_page_grants(state, ResourceManager.page_receipts(opts), lease, worker),
        else: state

    backing? =
      is_nil(backing) or
        (Authority.resource_current?(backing, lease, worker) and
           match?(
             %{holders: holders} when is_map_key(holders, self()),
             Resources.receipt(state.resources, backing)
           ))

    resources_current? =
      if is_nil(lease),
        do: MapSet.subset?(refs, old_refs),
        else: Authority.resource_current?(receipt, lease, self()) and backing?

    allowed? = current_work?(state, scope, generation, queue) and resources_current?

    if allowed? do
      staged =
        if role == :recording,
          do: PageCandidates.stage(state, key, body, opts, worker, lease),
          else: :immediate

      case staged do
        {:staged, state} ->
          {:reply, :stored, state}

        :immediate ->
          result =
            Registry.update_value(DB, key, fn page ->
              %{
                page
                | body: body,
                  opts: opts,
                  target_handle: opts[:target_handle] || page.target_handle,
                  storage_revision: make_ref()
              }
            end)

          finish_page_replacement(state, result, lease, {scope, receipt, refs, old_refs})
      end
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:processed, {_url, scope} = key, generation, queue}, _from, state) do
    if current_work?(state, scope, generation, queue) do
      result = Registry.update_value(DB, key, &%{&1 | processed: true})
      {:reply, result, reconcile_page_cleanup(state, key, queue)}
    else
      {:reply, :stale, state}
    end
  end

  def handle_call(
        {:complete_page, {_url, scope} = key, alias_key, generation, queue, count?, receipt},
        {worker, _},
        state
      ) do
    with true <- current_work?(state, scope, generation, queue),
         {:ok, state} <- retain_completed_alias(state, key, alias_key, receipt, worker) do
      state =
        case Registry.update_value(DB, key, &%{&1 | processed: true}) do
          {_page, %Page{processed: true}} ->
            state
            |> reconcile_page_cleanup(key, queue)
            |> Settlements.complete_source(key, worker)

          {_page, _previous} ->
            state
            |> count_completed_page(count?, scope, queue)
            |> complete_alias(alias_key, queue)
            |> reconcile_page_cleanup(key, queue)
            |> Settlements.complete_source(key, worker)

          :error ->
            state
        end

      {:reply, :ok, state}
    else
      _ -> {:reply, {:error, :stale}, reject_alias_completion(state, receipt, worker)}
    end
  end

  def handle_call({:delete, {_url, scope} = key, generation, queue}, _from, state) do
    if current_work?(state, scope, generation, queue) do
      {:reply, :ok, ResourceManager.remove_page(state, key)}
    else
      {:reply, :stale, state}
    end
  end

  def handle_call({:drop_scope, scope}, _from, state) do
    state = State.ensure_scope(retire_scope(state, scope), scope)
    Authority.put(state, scope)
    {:reply, State.generation(state, scope), state}
  end

  def handle_call({:dispose_scope, scope}, _from, state) do
    {:reply, :ok, retire_scope(state, scope)}
  end

  def handle_call({:dispose_scope, scope, generation}, _from, state) do
    if not is_nil(generation) and Map.has_key?(state.scopes, scope) and
         State.generation(state, scope) === generation do
      {:reply, :ok, retire_scope(state, scope)}
    else
      {:reply, :stale, state}
    end
  end

  def handle_call({:claim_robots, scope, origin, generation, queue}, from, state) do
    {pid, _tag} = from

    if current_work?(state, scope, generation, queue) and not is_nil(generation) do
      case State.claim_robots(state, scope, origin, from, pid, queue) do
        {{:reply, {:ready, rules}}, state} ->
          reply_robots_reader(state, scope, origin, pid, rules)

        {{:reply, reply}, state} ->
          {:reply, reply, state}

        {{:noreply, :wait}, state} ->
          {:noreply, state}
      end
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call(
        {:finish_robots, scope, origin, rules, generation, queue, context},
        {pid, _tag},
        state
      ) do
    receipt = context[:robots_receipt]
    lease = Process.get(:crawler_current_execution)

    funded? =
      if lease,
        do: is_reference(receipt) and Authority.resource_current?(receipt, lease, self()),
        else: true

    if current_work?(state, scope, generation, queue) and not is_nil(generation) and funded? do
      owner? = match?({:loading, _, ^pid, ^queue, _}, get_in(state.robots, [scope, origin]))

      if owner? do
        finish_owned_robots(state, scope, origin, rules, pid, queue, receipt)
      else
        {:reply, {:error, :stale}, state}
      end
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:forget_robots, scope, origin, rules, generation, queue}, {pid, _tag}, state) do
    if current_work?(state, scope, generation, queue) and not is_nil(generation) do
      {waiters, state} = State.forget_robots(state, scope, origin, pid, queue)

      reply_robots(waiters, robots_reply(rules))
      {:reply, :ok, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call(
        {:cookie_snapshot, scope, url, generation, context, expected},
        {worker, _},
        state
      ) do
    if cookie_read_authorized?(state, scope, generation, context, worker) do
      apply_cookie_transition(state, fn state ->
        Crawler.Store.CookieProof.snapshot(state, scope, url, generation, context, expected)
      end)
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call(
        {:save_cookies_with_proof, scope, url, headers, generation, context, expected},
        {worker, _},
        state
      ) do
    state = bind_cookie_write(state, scope, generation, context)

    cookie_write(state, scope, url, headers, generation, context, expected, worker)
  end

  def handle_call(
        {:validate_cookie_proof, scope, generation, context, expected},
        {worker, _},
        state
      ) do
    cookie_transition(state, scope, generation, context, worker, fn state ->
      Crawler.Store.CookieProof.validate(state, scope, generation, context, expected)
    end)
  end

  def handle_call({:control_transport_started, context}, {worker, _}, state) do
    control_transition(state, context, worker, fn record, scope ->
      {:ok, %{record | control_active: record.control_active + 1}, scope}
    end)
  end

  def handle_call({:control_transport_finished, context}, {worker, _}, state) do
    control_transition(state, context, worker, fn record, scope ->
      {:ok, %{record | control_active: max(record.control_active - 1, 0)}, scope}
    end)
  end

  def handle_call({:control_document, opts}, {worker, _}, state) do
    control_transition(state, opts, worker, fn record, scope ->
      role = if opts[:robots_fetch], do: :robots, else: :sitemap
      id = {role, Crawler.URL.canonical(opts.url)}
      documents = Map.get(record, :control_documents, MapSet.new())

      cond do
        MapSet.member?(documents, id) ->
          {:ok, record, scope}

        scope.control_documents >= record.max_control_documents ->
          {{:error, {:limit, :max_control_documents}}, record, scope}

        true ->
          with {:ok, bytes} <- Crawler.Store.Retained.bytes(id, opts.max_analysis_bytes),
               {{:ok, _receipt}, resources, effects} <-
                 Resources.reserve(
                   state.resources,
                   record.arena,
                   opts.execution_lease,
                   :control,
                   bytes
                 ) do
            {:ok, Map.put(record, :control_documents, MapSet.put(documents, id)),
             %{scope | control_documents: scope.control_documents + 1}, {resources, effects}}
          else
            {{:error, reason}, _, _} -> {{:error, reason}, record, scope}
            error -> {error, record, scope}
          end
      end
    end)
  end

  def handle_call({:control_bytes, opts, bytes}, {worker, _}, state)
      when is_integer(bytes) and bytes >= 0 do
    control_transition(state, opts, worker, fn record, scope ->
      previous = Map.get(record, :control_entity_bytes, 0)
      sequence = opts[:control_sequence]

      cond do
        is_integer(sequence) and sequence != record.control_sequence ->
          {{:error, :stale_control_entity}, record, scope}

        is_nil(sequence) and record.control_sequence == 0 ->
          charge_control(record, scope, max(previous, bytes) - previous, opts)

        true ->
          charge_control(record, scope, max(previous, bytes) - previous, opts)
      end
    end)
  end

  def handle_call({:control_entity, opts, sequence, bytes}, {worker, _}, state)
      when is_integer(sequence) and sequence > 0 do
    control_transition(state, opts, worker, fn record, scope ->
      if sequence <= Map.get(record, :control_sequence, 0) do
        {:ok, record, scope}
      else
        charge_control_entity(record, scope, opts, sequence, bytes)
      end
    end)
  end

  def handle_call({:save_cookies, scope, url, headers, generation, context}, {worker, _}, state) do
    state = bind_cookie_write(state, scope, generation, context)

    case cookie_write(state, scope, url, headers, generation, context, :unbound, worker) do
      {:reply, {:ok, _}, state} -> {:reply, :ok, state}
      {:reply, {:error, :stale}, state} -> {:reply, :ok, state}
      other -> other
    end
  end

  def handle_call({:cookie_header, scope, url, generation, context}, _from, state) do
    {header, state} =
      if current_work?(state, scope, generation, context[:queue]),
        do: State.cookie_header(state, scope, url, generation, context),
        else: {nil, state}

    {:reply, header, state}
  end

  def handle_call({:bind_execution_run, opts}, _from, state) do
    scope = opts[:scope]
    state = if is_nil(opts[:generation]), do: State.ensure_scope(state, scope), else: state
    generation = opts[:generation] || State.generation(state, scope)

    if current_work?(state, scope, generation, opts[:queue]) do
      record = Map.fetch!(state.scopes, scope)

      deadline =
        record.run_deadline || opts[:run_deadline] ||
          Crawler.Deadline.after_ms(opts.run_timeout, :run)

      record = arm_run_timer(record, scope, generation, deadline)

      runs =
        Map.update(
          state.scope_runs,
          scope,
          Crawler.Frontier.Ring.put(Crawler.Frontier.Ring.new(), {scope, generation}),
          &Crawler.Frontier.Ring.put(&1, {scope, generation})
        )

      state = %{state | scopes: Map.put(state.scopes, scope, record), scope_runs: runs}
      Authority.put(state, scope)
      {:reply, Map.merge(opts, %{generation: generation, run_deadline: deadline}), state}
    else
      {:reply, opts, state}
    end
  end

  def handle_call({:generation, scope}, _from, state) do
    state = State.ensure_scope(state, scope)
    Authority.put(state, scope)
    {:reply, State.generation(state, scope), state}
  end

  def handle_call({:current?, scope, generation, queue}, _from, state) do
    {:reply, current_work?(state, scope, generation, queue), state}
  end

  def handle_call({:ops_inc, scope, generation, queue}, _from, state) do
    state =
      if current_work?(state, scope, generation, queue) do
        State.increment(state, :ops, scope, queue)
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:ops_count, scope}, _from, state) do
    {:reply, State.count(state, :ops, scope), state}
  end

  def handle_call(:ops_count, _from, state) do
    {:reply, State.ops_count(state), state}
  end

  def handle_call(:ops_reset, _from, state) do
    state = State.reset_ops(state)
    state = %{state | scheduler: Crawler.Store.Scheduler.reset_completed(state.scheduler)}
    {:reply, :ok, schedule_frontier(state)}
  end

  def handle_call({:try_claim, scope, max_pages, generation, queue}, _from, state) do
    if current_work?(state, scope, generation, queue) do
      {reply, state} = State.try_claim(state, scope, max_pages, queue)
      {:reply, reply, state}
    else
      {:reply, :stale, state}
    end
  end

  def handle_call({:finish_claim, token, reason}, {worker, _tag}, state) do
    state = note_claim_limit(state, token, worker, reason)
    {:reply, :ok, release_claim(state, token, worker)}
  end

  def handle_call({:inflight_dec, scope, generation, queue}, _from, state) do
    state =
      if current_work?(state, scope, generation, queue) do
        State.decrement(state, :inflight, scope, queue)
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:inflight_count, scope}, _from, state) do
    {:reply, State.count(state, :inflight, scope) + frontier_count(state, scope, :inflight),
     state}
  end

  def handle_call({:pending_count, scope}, _from, state) do
    pending = State.count(state, :pending, scope) + frontier_count(state, scope, :pending)

    pending =
      if pending == 0 and Crawler.Store.ExportRun.automatic_pending?(state, scope),
        do: 1,
        else: pending

    {:reply, pending, state}
  end

  def handle_call({:work_pending?, scope, generation, queue}, _from, state) do
    pending? =
      current_work?(state, scope, generation, queue) and
        (State.work_pending?(state, scope, queue) or
           Crawler.Store.ExportRun.automatic_pending?(state, scope) or
           Crawler.Frontier.queue_pending(state.scheduler.frontier, {scope, generation}, queue) >
             0)

    {:reply, pending?, state}
  end

  def handle_call({:note_enqueued, scope, generation, queue}, _from, state) do
    if not is_nil(generation) and State.current?(state, scope, generation) and
         queue_available?(state, queue) do
      state = state |> monitor_queue(queue) |> State.note_enqueued(scope, queue)
      Authority.put(state, scope)
      {:reply, :ok, state}
    else
      {:reply, :stale, state}
    end
  end

  def handle_call({:finish_work, scope, generation, claimed?, queue}, _from, state) do
    if current_work?(state, scope, generation, queue) do
      state = state |> State.finish_work(scope, claimed?, queue) |> settle_scope_work(scope)

      {:reply, :ok, state}
    else
      {:reply, :stale, state}
    end
  end

  def handle_call({:attach_owner, feeder, owner, scope}, _from, state) do
    state = state |> monitor_queue(feeder) |> State.attach_owner(feeder, owner, scope)
    {:reply, :ok, state}
  end

  def handle_call({:queue_record, queue}, _from, state) do
    {:reply, State.queue_record(state, queue), state}
  end

  def handle_call({:queue_scopes, queue}, _from, state) do
    {:reply, State.queue_scopes(state, queue), state}
  end

  def handle_call({:release_queue, queue}, _from, state) do
    {:reply, :ok, retire_queue(state, queue)}
  end

  @impl true
  def handle_cast({:export_waiter_done, reference, worker}, state),
    do: {:noreply, Crawler.Store.ExportRun.cancel_waiter(state, reference, worker)}

  def handle_cast({:css_revision, holder, opts, group, revision, receipt}, state) do
    run = {opts[:scope], opts[:generation]}

    valid =
      case Resources.receipt(state.resources, receipt) do
        %{run: ^run, holders: holders} ->
          Map.has_key?(holders, holder) and
            Authority.export_writable?(opts[:scope], opts[:generation], opts[:queue])

        _ ->
          false
      end

    if valid do
      {_, state} =
        ResourceManager.transition(state, Resources.adopt(state.resources, receipt, self()))

      key = {run, group}
      previous = state.css_jobs[key]

      state =
        if previous && previous.receipt && previous.receipt != receipt do
          elem(
            ResourceManager.transition(
              state,
              Resources.release(state.resources, previous.receipt, self())
            ),
            1
          )
        else
          state
        end

      record =
        state.css_jobs[key] || css_record(opts, revision)

      origin = opts[:execution_lease]
      live_origin? = Authority.execution_current?(origin)
      owner = record.owner || if(live_origin?, do: origin)
      record = %{record | revision: revision, owner: owner, receipt: receipt}

      pending =
        if owner || record.settled == revision,
          do: state.css_pending,
          else: Crawler.Frontier.Ring.put(state.css_pending, key)

      executions =
        if owner do
          Map.update(
            state.css_executions,
            owner,
            Crawler.Frontier.Ring.put(Crawler.Frontier.Ring.new(), key),
            &Crawler.Frontier.Ring.put(&1, key)
          )
        else
          state.css_executions
        end

      state = put_css_record(state, key, record)
      state = Crawler.Store.ExportRun.css_revision(state, run, group, revision)

      state = %{
        state
        | css_run_jobs: index_css_run(state, key),
          css_pending: pending,
          css_executions: executions
      }

      if is_nil(record.owner) and record.settled != revision, do: send(self(), :css_pending)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_cast(
        {:deliver_resource, receipt, lease, producer, holder, payload, reply_to, ref},
        state
      ) do
    state =
      case relay_resource(receipt, lease, producer, holder, payload, reply_to, ref) do
        :ok ->
          %{state | resource_relays: Map.put(state.resource_relays, receipt, holder)}

        error ->
          send(reply_to, {ref, error})
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:expire_run, scope, generation}, state) do
    if State.current?(state, scope, generation) do
      Authority.delete(scope)
      state = note_limit(state, scope, generation, {:deadline, :run})
      run = %{state.scopes[scope] | outcome: {:limited, {:deadline, :run}}, run_timer: nil}
      state = %{state | scopes: Map.put(state.scopes, scope, run)}

      {:noreply,
       retire_frontier(
         state,
         {scope, generation},
         Crawler.Job.Outcome.new(:limited, {:deadline, :run}),
         false
       )}
    else
      {:noreply, state}
    end
  end

  def handle_info(:scope_disposal, state),
    do: {:noreply, drain_scope_disposals(%{state | disposal_scheduled?: false}, 16)}

  def handle_info(:retire_queue_frontier, state) do
    case Crawler.Frontier.Ring.take(state.retiring_queues) do
      :empty ->
        {:noreply, state}

      {:ok, token, ring} ->
        {status, claims, ids, frontier} =
          Crawler.Frontier.retire_queue_batch(state.scheduler.frontier, token, 16)

        state = %{
          state
          | retiring_queues: ring,
            scheduler:
              Enum.reduce(
                ids,
                %{state.scheduler | frontier: frontier},
                &Crawler.Store.Scheduler.observe_terminal(&2, &1)
              )
        }

        state = cleanup_retired_jobs(state, ids, claims)
        state = Enum.reduce(claims, state, &retire_scheduler_claim(&2, &1))

        ring = if status == :more, do: Crawler.Frontier.Ring.put(ring, token), else: ring
        if Crawler.Frontier.Ring.size(ring) > 0, do: send(self(), :retire_queue_frontier)
        {:noreply, schedule_frontier(%{state | retiring_queues: ring})}
    end
  end

  def handle_info(:retire_frontier, state) do
    state = drain_retired(%{state | retiring_scheduled?: false}, 16)
    {:noreply, schedule_frontier(state)}
  end

  def handle_info(:frontier_transition, state) do
    {_status, _visited, scheduler} = Crawler.Store.Scheduler.maintenance(state.scheduler, 32)
    {queues, more?, frontier} = Crawler.Frontier.take_wakeups(scheduler.frontier, 32)
    state = %{state | scheduler: %{scheduler | frontier: frontier}, scheduler_scheduled?: false}
    state = resume_representation_forks(state, 16)
    state = dispatch_direct(state, 16)
    state = notify_direct(state, 16)
    state = retire_direct(state, 16)
    scheduler = state.scheduler

    Enum.each(queues, fn queue ->
      ensure_queue_ticket(state, queue)
    end)

    pending? =
      more? or Crawler.Frontier.Ring.size(scheduler.maintenance) > 0 or
        Crawler.Frontier.Ring.size(scheduler.outcomes) > 0 or
        Crawler.Frontier.Ring.size(scheduler.forks) > 0 or
        Crawler.Frontier.Ring.size(scheduler.notifications) > 0 or
        Crawler.Frontier.ready?(scheduler.frontier, nil) or
        Crawler.Frontier.Ring.size(state.retired_direct_runs) > 0

    {:noreply, if(pending?, do: schedule_frontier(state), else: state)}
  end

  def handle_info({:crawler_queue_credit, queue}, state) do
    ensure_queue_ticket(state, queue)

    {:noreply, state}
  end

  def handle_info(:css_pending, state), do: {:noreply, dispatch_css(state, 16)}

  def handle_info({:css_runner_finished, pid, key, revision, outcome}, state) do
    case state.css_jobs[key] do
      %{runner: ^pid} = record ->
        current? = record.revision === revision

        record = %{
          record
          | settled: if(current?, do: revision, else: record.settled),
            outcome: if(current?, do: outcome, else: record.outcome),
            queued?: false,
            active_refresh?: false,
            runner: nil
        }

        state = put_css_record(state, key, record)
        state = Crawler.Store.ExportRun.progress(state, elem(key, 0))

        pending =
          if record.refresh_pending? or record.settled !== record.revision,
            do: Crawler.Frontier.Ring.put(state.css_pending, key),
            else: state.css_pending

        if Crawler.Frontier.Ring.size(pending) > 0, do: send(self(), :css_pending)
        {:noreply, %{state | css_pending: pending}}

      _ ->
        _ = pid
        {:noreply, state}
    end
  end

  def handle_info({:release_css_owner, lease}, state),
    do: {:noreply, release_css_owner(state, lease, 32)}

  def handle_info({:crawler_resource_abandon, receipt, _lease}, state) do
    if Map.has_key?(state.resource_relays, receipt) do
      {:noreply, state}
    else
      {_, state} =
        ResourceManager.transition(
          state,
          Resources.settle(state.resources, receipt, self(), :released)
        )

      {:noreply, state}
    end
  end

  def handle_info({:resource_delivery_consumed, receipt, holder}, state) do
    if state.resource_relays[receipt] == holder do
      state = %{state | resource_relays: Map.delete(state.resource_relays, receipt)}

      reply_consumed_resource(state, receipt)
    else
      {:noreply, state}
    end
  end

  def handle_info({:crawler_resource_adopted, receipt, holder}, state) do
    {_, state} =
      ResourceManager.transition(state, Resources.adopt(state.resources, receipt, holder))

    {:noreply, Crawler.Store.ExportIO.resource_event(state, :adopted, receipt, holder)}
  end

  def handle_info({:crawler_resource_settled, receipt, holder, result}, state)
      when result in [:retained, :released] do
    {_, state} =
      ResourceManager.transition(
        state,
        Resources.settle(state.resources, receipt, holder, result)
      )

    state =
      if result == :released,
        do: Crawler.Store.ExportIO.resource_event(state, :released, receipt, holder),
        else: state

    {:noreply, state}
  end

  def handle_info({:release_execution_returns, caller}, state),
    do: {:noreply, Crawler.Store.Returns.caller_down(state, caller)}

  def handle_info({:release_resource_holder, pid}, state),
    do: {:noreply, ResourceManager.holder_down(state, pid)}

  def handle_info(:resource_credit, state) do
    state = %{state | resource_credit_scheduled?: false}
    {:noreply, resume_execution_waiters(state, 16)}
  end

  def handle_info({:expire_execution, lease}, state) do
    state = revoke_execution(state, lease)

    terminate_owned_executor(state.executions[lease])

    {:noreply, state}
  end

  def handle_info(:export_pending, state) do
    state = drive_exports(%{state | export_scheduled?: false}, 16)
    {:noreply, Crawler.Store.ExportRun.schedule_pending(state)}
  end

  def handle_info({:crawler_export_finalized, monitor, nonce, pid, result}, state),
    do: {:noreply, Crawler.Store.ExportRun.driver_result(state, monitor, nonce, pid, result)}

  def handle_info({:export_source_ready, run}, state),
    do: {:noreply, Crawler.Store.ExportSource.drain(state, run)}

  def handle_info({:export_io_drain, run}, state),
    do: {:noreply, Crawler.Store.ExportIO.drain(state, run, 16)}

  def handle_info({:activate_export_io, lease, nonce, io}, state),
    do: {:noreply, Crawler.Store.ExportIO.activate(state, lease, nonce, io)}

  def handle_info(:source_cache_pending, state),
    do: {:noreply, Crawler.Store.SourceManager.drain(state)}

  def handle_info(:source_cache_refund, state),
    do: {:noreply, Crawler.Store.SourceManager.refund(state)}

  def handle_info({:activate_export_filesystem, key, nonce, pid}, state),
    do: {:noreply, Crawler.Store.ExportRun.activate(state, key, nonce, pid)}

  def handle_info({:crawler_filesystem_acquired, nonce, pid, result}, state),
    do: {:noreply, Crawler.Store.ExportRun.acquired(state, nonce, pid, result)}

  def handle_info({:crawler_filesystem_terminal, pid, nonce, operation, result}, state) do
    {:noreply, Crawler.Store.ExportRun.terminal_result(state, pid, nonce, operation, result)}
  end

  def handle_info({:release_export_command, opts, worker, receipt}, state),
    do: {:noreply, release_rejected_pregrant(state, opts, worker, receipt, :response)}

  def handle_info({:release_source_witness, receipt}, state),
    do: {:noreply, ResourceManager.release_owner(state, receipt)}

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    state = release_export_driver(state, ref, pid, reason)

    state =
      case state.export_monitors[ref] do
        {run, ^pid} -> Crawler.Store.ExportIO.filesystem_down(state, run, pid)
        _ -> state
      end

    state = Crawler.Store.ExportIO.down(state, ref, pid, reason)
    state = Crawler.Store.ExportRun.down(state, ref, pid, reason)

    state =
      case state.direct_monitors[ref] do
        nil -> state
        reference -> abandon_direct(state, reference)
      end

    state =
      case Map.pop(state.css_runners, ref) do
        {nil, _} ->
          state

        {key, runners} ->
          state = clear_css_runner(state, key, pid)
          record = state.css_jobs[key]

          pending =
            if record && (record.settled != record.revision or record.refresh_pending?),
              do: Crawler.Frontier.Ring.put(state.css_pending, key),
              else: state.css_pending

          send(self(), :css_pending)
          %{state | css_runners: runners, css_pending: pending}
      end

    state =
      case state.waiting_refs[ref] do
        nil -> state
        reference -> remove_execution_waiter(state, reference)
      end

    state =
      if state.resource_refs[ref] == pid do
        state |> Crawler.Store.Returns.caller_down(pid) |> ResourceManager.holder_down(pid)
      else
        state
      end

    state =
      case state.execution_monitors[ref] do
        nil -> state
        lease -> release_execution(state, lease)
      end

    state =
      case Map.pop(state.scheduler_monitors, ref) do
        {nil, _} ->
          state

        {claim, monitors} ->
          key =
            case state.scheduler.claims[claim] do
              %{run: run} -> run
              _ -> nil
            end

          state =
            case state.scheduler_workers[claim] do
              %{worker: worker, job: job} ->
                outcome =
                  Crawler.Frontier.outcome(state.scheduler.frontier, job.id) ||
                    Crawler.Job.Outcome.new(:failed, {:executor_down, reason})

                {:reply, _result, state} =
                  handle_call({:complete_job, claim, outcome, :local}, {worker, nil}, state)

                state

              _ ->
                state
            end

          state = state |> PageCandidates.release(claim) |> release_completed_alias(claim)
          scheduler = Crawler.Store.Scheduler.release(state.scheduler, claim)

          state =
            if match?(%{retired?: true}, scheduler.frontier.runs[key]),
              do: schedule_retirement(state, key),
              else: state

          state = %{
            state
            | scheduler: scheduler,
              scheduler_monitors: monitors,
              scheduler_workers: Map.delete(state.scheduler_workers, claim)
          }

          state |> settle_released_claim(key) |> schedule_frontier()
      end

    case State.robots_down(state, ref) do
      {waiters, state} when waiters != [] ->
        # The owner died before it stored the file. That is not permission to fetch.
        reply_robots(waiters, {:ready, Robots.disallow_all()})
        {:noreply, state}

      {[], state} ->
        if state.monitors[pid] == ref do
          state = retire_queue(state, pid)
          {:noreply, %{state | monitors: Map.delete(state.monitors, pid)}}
        else
          {:noreply, release_claim(state, ref, pid)}
        end
    end
  end

  defp direct_waiter_capacity(state, opts, deadline) do
    bytes = 16_384
    options = ResourceManager.options(state, opts)

    available =
      min(options.max_retained_bytes, state.resources.limit) -
        state.resources.used - options.external_frontier_bytes

    cond do
      Crawler.Deadline.check(deadline) != :ok ->
        {:error, {:deadline, deadline.kind}}

      map_size(state.direct_waiters) >= opts.max_pending ->
        {:error, {:limit, :max_pending}}

      bytes > available ->
        {:error, {:limit, :max_retained_bytes}}

      true ->
        {:ok, bytes}
    end
  end

  defp enroll_direct(state, {worker, _} = from, target, deadline, owner?, bytes) do
    reference = make_ref()
    monitor = Process.monitor(worker)
    run = Crawler.Frontier.run_key(state.scheduler.frontier.jobs[target].job)

    record = %{
      from: from,
      worker: worker,
      monitor: monitor,
      target: target,
      run: run,
      deadline: deadline,
      bytes: bytes,
      owner?: owner?
    }

    targets =
      Map.update(
        state.direct_targets,
        target,
        Crawler.Frontier.Ring.put(Crawler.Frontier.Ring.new(), reference),
        &Crawler.Frontier.Ring.put(&1, reference)
      )

    state = %{
      state
      | direct_waiters: Map.put(state.direct_waiters, reference, record),
        direct_runs:
          Map.update(
            state.direct_runs,
            run,
            Crawler.Frontier.Ring.put(Crawler.Frontier.Ring.new(), reference),
            &Crawler.Frontier.Ring.put(&1, reference)
          ),
        direct_targets: targets,
        direct_owners:
          if(owner?,
            do: Map.put(state.direct_owners, target, reference),
            else: state.direct_owners
          ),
        direct_workers: Map.put(state.direct_workers, worker, reference),
        direct_monitors: Map.put(state.direct_monitors, monitor, reference)
    }

    if owner?, do: claim_direct_target(state, reference), else: state
  end

  defp claim_direct_target(state, reference) do
    record = state.direct_waiters[reference]

    case Crawler.Store.Scheduler.claim_target(state.scheduler, record.target) do
      {:ok, claim, mode, job, scheduler} ->
        grant_direct(%{state | scheduler: scheduler}, reference, claim, mode, job)

      {:terminal, outcome, scheduler} ->
        GenServer.reply(record.from, {:terminal, outcome, %{target_handle: record.target}})
        remove_direct(%{state | scheduler: scheduler}, reference)

      {:error, reason, scheduler} ->
        GenServer.reply(record.from, {:error, reason})
        remove_direct(%{state | scheduler: scheduler}, reference)

      {_waiting, scheduler} ->
        %{state | scheduler: scheduler}
    end
  end

  defp grant_direct(state, reference, claim, mode, job) do
    if mode == :terminal do
      record = state.direct_waiters[reference]
      {reply, state} = replay_terminal(state, claim, job)

      case reply do
        {:terminal, outcome} ->
          GenServer.reply(record.from, {:terminal, outcome, %{target_handle: job.id}})
          remove_direct(state, reference)

        :empty ->
          state
      end
    else
      grant_direct_execution(state, reference, claim, mode, job)
    end
  end

  defp grant_direct_execution(state, reference, claim, mode, job) do
    record = state.direct_waiters[reference]
    state = remove_direct(state, reference)
    monitor = Process.monitor(record.worker)

    state = %{
      state
      | scheduler_monitors: Map.put(state.scheduler_monitors, monitor, claim),
        scheduler_workers:
          Map.put(state.scheduler_workers, claim, %{
            worker: record.worker,
            monitor: monitor,
            job: job
          })
    }

    GenServer.reply(record.from, {:ok, claim, job.kind, claimed_options(job, claim, mode)})
    state
  end

  defp replay_terminal(state, claim, job) do
    {:ok, outcome, reuse} =
      Crawler.Store.Scheduler.terminal(state.scheduler, job.representation_id)

    {valid?, state} = reusable_source(state, reuse, job.opts)

    if valid? do
      state = %{
        state
        | scheduler_workers: Map.put(state.scheduler_workers, claim, %{worker: self(), job: job})
      }

      {:reply, :ok, state} =
        handle_call({:complete_job, claim, outcome, :completion}, {self(), nil}, state)

      scheduler = Crawler.Store.Scheduler.release(state.scheduler, claim)

      {{:terminal, outcome},
       %{
         state
         | scheduler: scheduler,
           scheduler_workers: Map.delete(state.scheduler_workers, claim)
       }}
    else
      scheduler =
        state.scheduler
        |> Crawler.Store.Scheduler.invalidate(job.representation_id)
        |> Crawler.Store.Scheduler.park(claim)

      {:empty, %{state | scheduler: scheduler}}
    end
  end

  defp claimed_options(job, claim, mode),
    do:
      Map.merge(job.opts, %{
        target_handle: job.id,
        scheduler_claim: claim,
        prepared_request: job.prepared_request,
        scheduler_mode: mode,
        scheduler_kind: job.kind,
        representation_id: job.representation_id
      })

  defp dispatch_direct(state, 0), do: state

  defp dispatch_direct(state, remaining) do
    case Crawler.Store.Scheduler.checkout(state.scheduler, nil) do
      {:ok, claim, mode, job, scheduler} ->
        reference = Map.fetch!(state.direct_owners, job.id)
        state = grant_direct(%{state | scheduler: scheduler}, reference, claim, mode, job)
        dispatch_direct(state, remaining - 1)

      {:maintenance, scheduler} ->
        %{state | scheduler: scheduler}

      :empty ->
        state
    end
  end

  defp notify_direct(state, 0), do: state

  defp notify_direct(state, remaining) do
    case Crawler.Frontier.Ring.take(state.scheduler.notifications) do
      :empty ->
        state

      {:ok, target, _ring} ->
        state = project_terminal_outcome(state, target)
        {:ok, ^target, scheduler} = Crawler.Store.Scheduler.take_notification(state.scheduler)
        state = %{state | scheduler: scheduler}

        case Crawler.Frontier.Ring.take(
               Map.get(state.direct_targets, target, Crawler.Frontier.Ring.new())
             ) do
          :empty ->
            notify_direct(state, remaining - 1)

          {:ok, reference, _} ->
            notify_direct_waiter(state, reference, target, remaining)
        end
    end
  end

  defp project_terminal_outcome(state, target) do
    case state.scheduler.frontier.jobs[target] do
      %{job: %Crawler.Job{} = job, outcome: %Crawler.Job.Outcome{} = outcome} ->
        {scope, generation, _queue} = job.authority

        state =
          if outcome.status == :limited,
            do: note_limit(state, scope, generation, outcome.reason),
            else: state

        case Crawler.Store.ExportRun.settle(state, job, outcome) do
          {:ok, state} ->
            schedule_export_refresh(state, job)

          {:error, reason} ->
            Crawler.Store.ExportRun.fail(state, Crawler.Frontier.run_key(job), reason)
        end

      _ ->
        state
    end
  end

  defp schedule_export_refresh(state, job) do
    run = Crawler.Frontier.run_key(job)

    with %{automatic: automatic, failure: nil, helper: helper} when not is_nil(automatic) <-
           state.exports[run],
         %{dirty?: true, descriptor: descriptor, memberships: memberships}
         when not is_nil(descriptor) <- helper.targets[job.id],
         {group, _, _} <- :maps.next(:maps.iterator(memberships)),
         %{revision: _revision} = record <- state.css_jobs[{run, group}] do
      record = %{record | refresh_pending?: true}
      state = put_css_record(state, {run, group}, record)
      pending = Crawler.Frontier.Ring.put(state.css_pending, {run, group})
      if Crawler.Frontier.Ring.size(state.css_pending) == 0, do: send(self(), :css_pending)
      %{state | css_pending: pending}
    else
      _ -> state
    end
  end

  defp retire_direct(state, 0), do: state

  defp retire_direct(state, remaining) do
    case Crawler.Frontier.Ring.take(state.retired_direct_runs) do
      :empty ->
        state

      {:ok, key, order} ->
        state = %{state | retired_direct_runs: order}

        case Crawler.Frontier.Ring.take(
               Map.get(state.direct_runs, key, Crawler.Frontier.Ring.new())
             ) do
          :empty ->
            retire_direct(state, remaining - 1)

          {:ok, reference, _} ->
            record = state.direct_waiters[reference]
            GenServer.reply(record.from, {:error, :stale})
            state = remove_direct(state, reference)

            state = %{
              state
              | retired_direct_runs: Crawler.Frontier.Ring.put(state.retired_direct_runs, key)
            }

            retire_direct(state, remaining - 1)
        end
    end
  end

  defp remove_direct(state, reference) do
    {record, records} = Map.pop(state.direct_waiters, reference)
    Process.demonitor(record.monitor, [:flush])
    targets = Crawler.Frontier.Ring.delete(state.direct_targets[record.target], reference)
    runs = Crawler.Frontier.Ring.delete(state.direct_runs[record.run], reference)

    %{
      state
      | direct_waiters: records,
        direct_runs:
          if(Crawler.Frontier.Ring.size(runs) == 0,
            do: Map.delete(state.direct_runs, record.run),
            else: Map.put(state.direct_runs, record.run, runs)
          ),
        direct_owners:
          if(record.owner?,
            do: Map.delete(state.direct_owners, record.target),
            else: state.direct_owners
          ),
        direct_targets:
          if(Crawler.Frontier.Ring.size(targets) == 0,
            do: Map.delete(state.direct_targets, record.target),
            else: Map.put(state.direct_targets, record.target, targets)
          ),
        direct_workers: Map.delete(state.direct_workers, record.worker),
        direct_monitors: Map.delete(state.direct_monitors, record.monitor),
        waiting_bytes: state.waiting_bytes - record.bytes
    }
  end

  defp abandon_direct(state, reference) do
    record = state.direct_waiters[reference]
    state = remove_direct(state, reference)

    if record.owner? do
      outcome =
        case Crawler.Deadline.check(record.deadline) do
          :ok -> Crawler.Job.Outcome.new(:cancelled, :executor_down)
          {:error, reason} -> Crawler.Job.Outcome.new(:limited, reason)
        end

      case Crawler.Frontier.settle_job(state.scheduler.frontier, record.target, outcome) do
        {:ok, frontier} ->
          scheduler =
            Crawler.Store.Scheduler.observe_terminal(
              %{state.scheduler | frontier: frontier},
              record.target
            )

          schedule_frontier(%{state | scheduler: scheduler})

        _ ->
          state
      end
    else
      state
    end
  end

  defp defer_execution(state, opts, deadline, {worker, _} = from) do
    options = ResourceManager.options(state, opts)
    limit = min(options.max_retained_bytes, state.resources.limit)
    metadata_limit = max(limit - state.resources.used - options.external_frontier_bytes, 0)

    case Crawler.Store.Retained.bytes({opts, from}, metadata_limit) do
      {:ok, metadata}
      when map_size(state.pending_executions) < opts.max_pending and
             metadata + 4096 <= metadata_limit ->
        reference = make_ref()
        monitor = Process.monitor(worker)

        record = %{
          opts: opts,
          deadline: deadline,
          from: from,
          monitor: monitor,
          worker: worker,
          metadata: metadata + 4096
        }

        cost =
          Resources.arena_cost(
            {opts[:scope], opts[:generation]},
            make_ref(),
            worker,
            ResourceManager.envelope(opts)
          )

        state = %{
          state
          | resource_waiters: Index.put(state.resource_waiters, reference, cost),
            pending_executions: Map.put(state.pending_executions, reference, record),
            waiting_workers: Map.put(state.waiting_workers, worker, reference),
            waiting_refs: Map.put(state.waiting_refs, monitor, reference),
            waiting_bytes: state.waiting_bytes + record.metadata
        }

        {:noreply, state}

      _ ->
        {:reply, {:error, {:limit, :max_pending}}, state}
    end
  end

  defp remove_execution_waiter(state, reference) do
    case Map.pop(state.pending_executions, reference) do
      {nil, _} ->
        state

      {record, pending} ->
        Process.demonitor(record.monitor, [:flush])

        %{
          state
          | pending_executions: pending,
            waiting_workers: Map.delete(state.waiting_workers, record.worker),
            waiting_refs: Map.delete(state.waiting_refs, record.monitor),
            waiting_bytes: state.waiting_bytes - record.metadata,
            resource_waiters: Index.delete(state.resource_waiters, reference)
        }
    end
  end

  defp resume_execution_waiters(state, 0) do
    if map_size(state.pending_executions) > 0 and not state.resource_credit_scheduled? do
      send(self(), :resource_credit)
      %{state | resource_credit_scheduled?: true}
    else
      state
    end
  end

  defp resume_execution_waiters(state, remaining) do
    bytes = Crawler.Frontier.bytes(state.scheduler.frontier)

    available =
      state.resources.limit - state.resources.used - bytes.metadata - bytes.payload -
        state.waiting_bytes

    case Index.first_full(state.resource_waiters, available) do
      :none ->
        if ResourceManager.releasable?(state) do
          state
        else
          fail_execution_waiter(state, remaining)
        end

      {:ok, reference} ->
        record = state.pending_executions[reference]
        state = remove_execution_waiter(state, reference)

        case handle_call({:begin_execution, record.opts, record.deadline}, record.from, state) do
          {:reply, reply, state} ->
            GenServer.reply(record.from, reply)
            resume_execution_waiters(state, remaining - 1)

          {:noreply, state} ->
            state
        end
    end
  end

  defp reusable_source(state, %{disposition: :candidate, dependency: :initial}, _opts),
    do: {true, state}

  defp reusable_source(
         state,
         %{disposition: :candidate, dependency: {:redirect_jar, proof}},
         opts
       ) do
    case Crawler.Store.CookieProof.validate(state, opts[:scope], opts[:generation], opts, proof) do
      {{:ok, %{verdict: :current}}, state} -> {true, state}
      {_result, state} -> {false, state}
    end
  end

  defp reusable_source(state, _receipt, _opts), do: {false, state}

  defp resume_representation_forks(state, 0), do: state

  defp resume_representation_forks(state, remaining) do
    case Crawler.Store.Scheduler.take_fork(state.scheduler) do
      :empty ->
        state

      {:ok, id, scheduler} ->
        state = %{state | scheduler: scheduler}

        case scheduler.frontier.jobs[id] do
          %{job: job, status: {:waiting, _}} ->
            resume_representation_fork(state, job, id, remaining)

          _ ->
            resume_representation_forks(state, remaining - 1)
        end
    end
  end

  defp schedule_scope_disposal(%{disposal_scheduled?: true} = state), do: state

  defp schedule_scope_disposal(state) do
    send(self(), :scope_disposal)
    %{state | disposal_scheduled?: true}
  end

  defp drain_scope_disposals(state, 0) do
    if Crawler.Frontier.Ring.size(state.disposal_order) > 0,
      do: schedule_scope_disposal(state),
      else: state
  end

  defp drain_scope_disposals(state, remaining) do
    case Crawler.Frontier.Ring.take(state.disposal_order) do
      :empty ->
        state

      {:ok, reference, order} ->
        record = state.scope_disposals[reference]

        case Crawler.Frontier.Ring.take(record.runs) do
          {:ok, key, runs} ->
            state = retire_frontier(state, key)

            state = %{
              state
              | scope_disposals:
                  Map.put(state.scope_disposals, reference, %{record | runs: runs}),
                disposal_order: Crawler.Frontier.Ring.put(order, reference)
            }

            drain_scope_disposals(state, remaining - 1)

          :empty ->
            dispose_scope_pages(state, record, reference, order, remaining)
        end
    end
  end

  defp index_css_run(state, {run, _group} = key),
    do:
      Map.update(
        state.css_run_jobs,
        run,
        Crawler.Frontier.Ring.put(Crawler.Frontier.Ring.new(), key),
        &Crawler.Frontier.Ring.put(&1, key)
      )

  defp retire_frontier(
         state,
         key,
         outcome \\ Crawler.Job.Outcome.new(:cancelled, :run_retired),
         dispose? \\ true
       ) do
    scheduler = Crawler.Store.Scheduler.retire(state.scheduler, key, outcome, dispose?)
    state = Crawler.Store.ExportRun.retire(state, key, dispose?)

    state = %{
      state
      | retired_direct_runs: Crawler.Frontier.Ring.put(state.retired_direct_runs, key)
    }

    {_, state} =
      ResourceManager.transition(
        %{state | scheduler: scheduler},
        Resources.retire_run(state.resources, key)
      )

    state |> schedule_retirement(key) |> schedule_frontier()
  end

  defp schedule_retirement(state, key) do
    if not state.retiring_scheduled?, do: send(self(), :retire_frontier)

    %{
      state
      | retiring_runs: Crawler.Frontier.Ring.put(state.retiring_runs, key),
        retiring_scheduled?: true
    }
  end

  defp drain_retired(state, 0), do: state

  defp drain_retired(state, remaining) do
    case Crawler.Frontier.Ring.take(state.retiring_runs) do
      :empty ->
        state

      {:ok, key, ring} ->
        state = %{state | retiring_runs: ring}

        {claims_status, claims, frontier} =
          Crawler.Frontier.retire_claims_batch(state.scheduler.frontier, key, 1)

        {settle_status, settled, frontier} = Crawler.Frontier.settle_batch(frontier, key, 1)

        ids = Enum.map(claims, &frontier.claims[&1].id) ++ settled

        scheduler =
          Enum.reduce(
            ids,
            %{state.scheduler | frontier: frontier},
            &Crawler.Store.Scheduler.observe_terminal(&2, &1)
          )

        state = cleanup_retired_jobs(%{state | scheduler: scheduler}, ids, claims)
        state = Enum.reduce(claims, state, &retire_scheduler_claim(&2, &1))
        scheduler = state.scheduler
        frontier = scheduler.frontier

        {dispose_status, _, frontier} =
          if match?(%{dispose?: false}, frontier.runs[key]),
            do: {:done, 0, frontier},
            else: Crawler.Frontier.dispose_batch(frontier, key, 1)

        scheduler = %{scheduler | frontier: frontier}

        {source_more?, source, marker, scheduler} =
          case Crawler.Store.Scheduler.take_retired_source(scheduler, key) do
            {:empty, scheduler} -> {false, nil, nil, scheduler}
            {:ok, source, scheduler} -> {true, source, nil, scheduler}
            {:marker, marker, scheduler} -> {true, nil, marker, scheduler}
          end

        state = %{state | scheduler: scheduler}

        state =
          if marker, do: Crawler.Store.CustomStorage.retire_marker(state, marker), else: state

        state =
          if source,
            do: %{state | source_resources: MapSet.delete(state.source_resources, source.receipt)},
            else: state

        state =
          if source, do: Crawler.Store.SourceManager.release_source(state, source), else: state

        {robots_more?, state} = retire_robots_receipt(state, key)
        {aliases_more?, state} = Settlements.retire_one(state, key)
        {css_more?, state} = retire_css_group(state, key)
        {execution_more?, state} = retire_run_execution(state, key)

        more? =
          source_more? or robots_more? or aliases_more? or css_more? or execution_more? or
            claims_status == :more or
            settle_status == :more or
            dispose_status == :more

        state = if more?, do: schedule_retirement(state, key), else: state
        drain_retired(state, remaining - 1)
    end
  end

  defp retire_run_execution(state, key) do
    ring = Map.get(state.execution_runs, key, Crawler.Frontier.Ring.new())

    case Crawler.Frontier.Ring.take(ring) do
      :empty ->
        {false, %{state | execution_runs: Map.delete(state.execution_runs, key)}}

      {:ok, lease, ring} ->
        state = %{state | execution_runs: Map.put(state.execution_runs, key, ring)}
        result = retirement_result(state, key)
        state = fail_owned_robots(state, lease, result)
        state = notify_execution_revocation(state, lease, result)
        state = debit_and_revoke_execution(state, lease)

        terminate_owned_executor(state.executions[lease])

        {true, state}
    end
  end

  defp retire_robots_receipt(state, {scope, generation} = run) do
    if Map.has_key?(state.scopes, scope) and State.current?(state, scope, generation) do
      {false, state}
    else
      take_retired_robots_receipt(state, run)
    end
  end

  defp take_retired_robots_receipt(state, {scope, _generation} = run) do
    origins = Map.get(state.robots_receipts, run, %{})

    case :maps.next(:maps.iterator(origins)) do
      :none ->
        {false, state}

      {origin, receipt, _iterator} ->
        origins = Map.delete(origins, origin)

        index =
          if map_size(origins) == 0,
            do: Map.delete(state.robots_receipts, run),
            else: Map.put(state.robots_receipts, run, origins)

        retained =
          if MapSet.member?(state.persistent_resources, receipt),
            do: state.retained_pages,
            else: remove_retained_receipt(state.retained_pages, scope, receipt)

        state = %{state | robots_receipts: index, retained_pages: retained}
        state = retire_robots_cache(state, run, origin)
        {map_size(origins) > 0, ResourceManager.release_owner(state, receipt)}
    end
  end

  defp retire_robots_cache(state, {scope, generation}, origin) do
    if Map.has_key?(state.scopes, scope) and State.generation(state, scope) === generation and
         state.scopes[scope].outcome != :open do
      origins = Map.delete(Map.get(state.robots, scope, %{}), origin)

      robots =
        if map_size(origins) == 0,
          do: Map.delete(state.robots, scope),
          else: Map.put(state.robots, scope, origins)

      %{state | robots: robots}
    else
      state
    end
  end

  defp terminate_owned_executor(%{worker: worker, observer: observer}) when is_pid(observer),
    do: Process.exit(worker, :kill)

  defp terminate_owned_executor(_record), do: :ok

  defp retirement_result(state, {scope, generation} = key) do
    case state.scheduler.frontier.runs[key] do
      %{retired_outcome: %{status: :limited, reason: reason}} ->
        {:error, reason}

      _ ->
        scope_retirement_result(state, scope, generation)
    end
  end

  defp retire_css_group(state, run) do
    case Crawler.Frontier.Ring.take(Map.get(state.css_run_jobs, run, Crawler.Frontier.Ring.new())) do
      :empty ->
        {false, %{state | css_run_jobs: Map.delete(state.css_run_jobs, run)}}

      {:ok, key, ring} ->
        record = state.css_jobs[key]
        state = put_css_record(state, key, nil)
        jobs = state.css_jobs

        state = %{
          state
          | css_jobs: jobs,
            css_pending: Crawler.Frontier.Ring.delete(state.css_pending, key),
            css_run_jobs: Map.put(state.css_run_jobs, run, ring)
        }

        state =
          if record && record.receipt do
            elem(
              ResourceManager.transition(
                state,
                Resources.release(state.resources, record.receipt, self())
              ),
              1
            )
          else
            state
          end

        {true, state}
    end
  end

  defp put_css_record(state, {run, _group} = key, record) do
    active = fn
      nil ->
        0

      row ->
        if row.revision === row.settled and not row.refresh_pending? and not row.active_refresh?,
          do: 0,
          else: 1
    end

    count = Map.get(state.css_unsettled, run, 0) + active.(record) - active.(state.css_jobs[key])

    counts =
      if count == 0,
        do: Map.delete(state.css_unsettled, run),
        else: Map.put(state.css_unsettled, run, count)

    jobs =
      if record, do: Map.put(state.css_jobs, key, record), else: Map.delete(state.css_jobs, key)

    %{state | css_jobs: jobs, css_unsettled: counts}
  end

  defp css_record(opts, revision) do
    keys =
      Map.keys(Crawler.Options.assign_defaults(%{})) ++
        [
          :url,
          :site,
          :generation,
          :queue_owner,
          :referrer_url,
          :style_group,
          :style_sheet_url,
          :reference_tag,
          :document_url,
          :worker_base,
          :cookie_site,
          :cookie_navigation,
          :credentials,
          :run_deadline
        ]

    %{
      owner: nil,
      revision: revision,
      active_revision: nil,
      committed: nil,
      settled: nil,
      outcome: nil,
      queued?: false,
      runner: nil,
      refresh_pending?: false,
      active_refresh?: false,
      receipt: opts[:css_obligation_receipt],
      opts: Map.take(opts, keys)
    }
  end

  defp dispatch_css(state, 0) do
    if Crawler.Frontier.Ring.size(state.css_pending) > 0 and map_size(state.css_runners) < 2,
      do: send(self(), :css_pending)

    state
  end

  defp dispatch_css(state, _remaining) when map_size(state.css_runners) >= 2, do: state

  defp dispatch_css(state, remaining) do
    case Crawler.Frontier.Ring.take(state.css_pending) do
      :empty ->
        state

      {:ok, key, pending} ->
        state = %{state | css_pending: pending}

        case state.css_jobs[key] do
          %{owner: nil, queued?: false, revision: revision, settled: settled} = record
          when revision != settled or record.refresh_pending? ->
            dispatch_css_record(state, remaining, key, record, revision)

          _ ->
            dispatch_css(state, remaining - 1)
        end
    end
  end

  defp release_css_owner(state, lease, 0) do
    send(self(), {:release_css_owner, lease})
    state
  end

  defp release_css_owner(state, lease, remaining) do
    ring = Map.get(state.css_executions, lease, Crawler.Frontier.Ring.new())

    case Crawler.Frontier.Ring.take(ring) do
      :empty ->
        %{state | css_executions: Map.delete(state.css_executions, lease)}

      {:ok, key, ring} ->
        state = %{state | css_executions: Map.put(state.css_executions, lease, ring)}

        state =
          case state.css_jobs[key] do
            %{owner: ^lease} = record ->
              clear_css_owner_record(state, key, record)

            _ ->
              state
          end

        release_css_owner(state, lease, remaining - 1)
    end
  end

  defp frontier_count(state, scope, counter) do
    if Map.has_key?(state.scopes, scope) do
      key = {scope, State.generation(state, scope)}

      case counter do
        :pending -> Crawler.Frontier.pending(state.scheduler.frontier, key)
        :inflight -> Crawler.Frontier.inflight(state.scheduler.frontier, key)
      end
    else
      0
    end
  end

  defp schedule_frontier(%{scheduler_scheduled?: true} = state), do: state

  defp schedule_frontier(state) do
    send(self(), :frontier_transition)
    %{state | scheduler_scheduled?: true}
  end

  defp bind_cookie_write(state, scope, nil, context) when not is_nil(scope) do
    if is_nil(context[:queue]) and is_nil(context[:execution_lease]) and
         not Map.has_key?(state.scopes, scope) do
      state = State.ensure_scope(state, scope)
      Authority.put(state, scope)
      state
    else
      state
    end
  end

  defp bind_cookie_write(state, _scope, _generation, _context), do: state

  defp cookie_write(state, scope, _url, [], generation, context, expected, worker) do
    cookie_transition(state, scope, generation, context, worker, fn state ->
      Crawler.Store.CookieProof.validate(state, scope, generation, context, expected)
    end)
  end

  defp cookie_write(state, scope, url, headers, generation, context, expected, worker) do
    cookie_transition(state, scope, generation, context, worker, fn state ->
      write_cookies(state, scope, url, headers, generation, context, expected)
    end)
  end

  defp cookie_arena(state, _scope, _generation, lease, %{arena: arena}, _scratch),
    do: {{:ok, arena, lease, false}, state}

  defp cookie_arena(state, scope, generation, _lease, nil, scratch) do
    opts =
      Crawler.Options.assign_defaults(%{scope: scope, generation: generation})
      |> then(&ResourceManager.options(state, &1))

    token = make_ref()

    {reply, state} =
      ResourceManager.transition(
        state,
        Resources.acquire(
          state.resources,
          {scope, generation},
          token,
          self(),
          scratch + 32_768,
          opts
        )
      )

    case reply do
      {:ok, arena} -> {{:ok, arena, token, true}, state}
      _ -> {reply, state}
    end
  end

  defp cookie_read_authorized?(state, scope, generation, context, worker) do
    lease = context[:execution_lease] || Process.get(:crawler_current_execution)

    case {lease, state.executions[lease]} do
      {nil, _} ->
        is_nil(generation) or State.current?(state, scope, generation)

      {lease, %{worker: ^worker, opts: %{scope: ^scope, generation: bound, queue: queue}}} ->
        (is_nil(generation) or generation === bound) and
          Authority.current?(scope, bound, queue, lease) and
          Authority.execution_current?(lease, worker)

      _ ->
        false
    end
  end

  defp cookie_transition(state, scope, generation, context, worker, transition) do
    lease = context[:execution_lease] || Process.get(:crawler_current_execution)
    inert? = is_nil(generation) and not Map.has_key?(state.scopes, scope)

    if (inert? or current_work?(state, scope, generation, context[:queue])) and
         (is_nil(lease) or
            (Authority.current?(scope, generation, context[:queue], lease) and
               Authority.execution_current?(lease, worker))) do
      apply_cookie_transition(state, transition)
    else
      {:reply, {:error, :stale}, state}
    end
  end

  defp apply_cookie_transition(state, transition) do
    previous = state.cookie_bytes
    {reply, state} = transition.(state)
    state = if state.cookie_bytes < previous, do: ResourceManager.credit(state), else: state
    {:reply, reply, state}
  end

  defp control_transition(state, opts, worker, transition) do
    lease = opts[:execution_lease]

    case state.executions[lease] do
      %{opts: %{scope: scope}} = record ->
        if Authority.execution_current?(lease, worker) and
             Authority.current?(scope, record.opts.generation, record.opts.queue, lease) and
             opts[:scope] === scope and opts[:generation] == record.opts.generation and
             opts[:queue] == record.opts.queue do
          apply_control_transition(state, scope, lease, record, transition)
        else
          {:reply, {:error, :stale}, state}
        end

      _ ->
        {:reply, {:error, :stale}, state}
    end
  end

  defp charge_control(record, scope, delta, opts) do
    cap = min(opts[:max_control_bytes] || record.max_control_bytes, record.max_control_bytes)

    if delta > cap - scope.control_bytes do
      {{:error, {:limit, :max_control_bytes}}, record, %{scope | control_bytes: cap}}
    else
      {:ok, Map.update!(record, :control_entity_bytes, &(&1 + delta)),
       %{scope | control_bytes: scope.control_bytes + delta}}
    end
  end

  defp alias_representation?(state, opts) do
    case state.scheduler.claims[opts[:scheduler_claim]] do
      %{representation: representation, job: target} ->
        representation === opts[:representation_id] and target === opts[:target_handle]

      _ ->
        false
    end
  end

  defp current_claim_execution?(state, opts, worker) do
    claim = opts[:scheduler_claim]

    case state.executions[opts[:execution_lease]] do
      %{worker: ^worker, opts: %{scheduler_claim: ^claim} = owned} ->
        Authority.execution_current?(opts[:execution_lease], worker) and
          {opts[:scope], opts[:generation], opts[:queue]} ===
            {owned[:scope], owned[:generation], owned[:queue]} and
          current_work?(state, owned[:scope], owned[:generation], owned[:queue])

      _ ->
        false
    end
  end

  defp retire_replaced_source(state, %{receipt: ref} = source, replacement)
       when ref != replacement do
    state = %{state | source_resources: MapSet.delete(state.source_resources, ref)}
    Crawler.Store.SourceManager.release_source(state, source)
  end

  defp retire_replaced_source(state, _source, _replacement), do: state

  defp reject_export_pregrant(state, {:export, opts, command}, worker) do
    case command do
      {:io_custody, _, _, _, _, receipt} ->
        release_rejected_pregrant(state, opts, worker, receipt, :source)

      {:io_deliver, _, _, _, receipt, _} ->
        release_rejected_pregrant(state, opts, worker, receipt, :response)

      {:funded_command, receipt, _, {:io_start, _, _, metadata}} ->
        state = release_rejected_pregrant(state, opts, worker, receipt, :response)
        release_rejected_pregrant(state, opts, worker, metadata, :source)

      {:funded_command, receipt, _, _} ->
        release_rejected_pregrant(state, opts, worker, receipt, :response)

      {:funded_reply, _, {:refresh_batch, _, _, metadata}} ->
        release_rejected_pregrant(state, opts, worker, metadata, :snapshot)

      _ ->
        state
    end
  end

  defp reject_export_pregrant(state, _request, _worker), do: state

  defp reject_source_pregrant(state, {:source_cache, opts, command}, worker) do
    receipt =
      case command do
        {:acquire, _, _, receipt} when is_reference(receipt) ->
          receipt

        {:acquire_decoded, _, receipt} when is_reference(receipt) ->
          receipt

        {kind, _, %{copy_receipt: receipt}}
        when kind in [:publish, :publish_decoded] and is_reference(receipt) ->
          receipt

        _ ->
          nil
      end

    release_rejected_pregrant(state, opts, worker, receipt, :response)
  end

  defp reject_source_pregrant(state, {:complete_page, _, _, _, _, _, receipt}, worker),
    do: reject_alias_completion(state, receipt, worker)

  defp reject_source_pregrant(state, {:claim_custom_storage, opts, receipt}, worker),
    do: release_rejected_pregrant(state, opts, worker, receipt, :source)

  defp reject_source_pregrant(state, {:settlement_payload, _, _, opts, receipt}, worker),
    do: release_rejected_pregrant(state, opts, worker, receipt, :source)

  defp reject_source_pregrant(state, {:retain_alias, _, _, _, opts, receipt}, worker),
    do: release_rejected_pregrant(state, opts, worker, receipt, :source)

  defp reject_source_pregrant(state, _request, _worker), do: state

  defp clear_physical_source(state, lease) do
    Crawler.Store.SourceWitness.clear(state, lease)
  end

  defp remember_physical_source(state, lease, source),
    do: Crawler.Store.SourceWitness.remember(state, lease, source)

  defp current_source_execution?(state, opts, worker) do
    target = opts[:target_handle]
    representation = opts[:representation_id]

    current_claim_execution?(state, opts, worker) and
      match?(
        %{job: ^target, representation: ^representation},
        state.scheduler.claims[opts[:scheduler_claim]]
      )
  end

  defp release_rejected_pregrant(state, opts, worker, receipt, kind) do
    case Resources.receipt(state.resources, receipt) do
      %{kind: ^kind, holders: holders} ->
        case holders[self()] do
          %{status: :pending, origin: ^worker, lease: lease} when lease == opts.execution_lease ->
            elem(
              ResourceManager.transition(
                state,
                Resources.release(state.resources, receipt, self())
              ),
              1
            )

          _ ->
            state
        end

      _ ->
        state
    end
  end

  defp export_request(state, opts, job, {:target_reply, receipt, {:source_info, epoch}}, from),
    do: Crawler.Store.ExportSource.info(state, opts, job, receipt, epoch, from)

  defp export_request(state, opts, _job, {:io_settled, epoch, operation, result}, from),
    do: Crawler.Store.ExportIO.settled(state, opts, epoch, operation, result, from)

  defp export_request(state, opts, job, command, _from) do
    {reply, state} = export_transition(state, opts, job, command)
    {:reply, reply, state}
  end

  defp export_transition(
         state,
         opts,
         _job,
         {:io_custody, epoch, operation, io, credit, metadata}
       ),
       do: Crawler.Store.ExportIO.custody(state, opts, epoch, operation, io, credit, metadata)

  defp export_transition(state, opts, _job, {:io_deliver, epoch, io, credit, receipt, payload}),
    do: Crawler.Store.ExportIO.deliver(state, opts, epoch, io, credit, receipt, payload)

  defp export_transition(state, opts, _job, {:io_abandon, epoch, operation, reason}),
    do: Crawler.Store.ExportIO.abandon(state, opts, epoch, operation, reason)

  defp export_transition(state, opts, job, {:target_reply, receipt, command}),
    do: Crawler.Store.ExportRun.target_reply(state, opts, job, receipt, command)

  defp export_transition(
         state,
         opts,
         job,
         {:funded_reply, receipt, {:prepare_next, epoch, token, cursor, limit}}
       ),
       do:
         Crawler.Store.ExportRun.prepare_next(
           state,
           opts,
           job,
           receipt,
           epoch,
           token,
           cursor,
           limit
         )

  defp export_transition(state, opts, job, {:funded_reply, receipt, {:seal, epoch, token}}),
    do: Crawler.Store.ExportRun.seal(state, opts, job, receipt, epoch, token)

  defp export_transition(
         state,
         opts,
         job,
         {:funded_reply, receipt, {:refresh_batch, epoch, limit, metadata}}
       ),
       do:
         Crawler.Store.ExportRun.refresh_batch(state, opts, job, receipt, epoch, limit, metadata)

  defp export_transition(
         state,
         opts,
         job,
         {:funded_command, receipt, workspace, command} = envelope
       ) do
    worker = state.executions[opts.execution_lease].worker
    send(self(), {:release_export_command, Map.take(opts, [:execution_lease]), worker, receipt})

    with true <- Authority.resource_current?(workspace, opts.execution_lease, worker),
         %{kind: :scratch, actual: nil, capacity: size} when size >= 98_304 <-
           Resources.receipt(state.resources, workspace),
         %{kind: :response, actual: actual, copy_bytes: copy, holders: holders}
         when is_integer(actual) and is_integer(copy) <-
           Resources.receipt(state.resources, receipt),
         %{status: :pending, lease: lease, origin: ^worker} when lease === opts.execution_lease <-
           holders[self()],
         {:ok, _} <- Crawler.Store.Retained.bytes({:export, opts, envelope}, actual),
         {:ok, _} <- Crawler.Store.Retained.copy_bytes({:export, opts, envelope}, copy) do
      export_funded_command(state, opts, job, command)
    else
      _ -> {{:error, :unfunded_export_command}, state}
    end
  end

  defp export_transition(state, opts, job, {:rendered, epoch, seal, target, operation}),
    do: Crawler.Store.ExportRun.rendered(state, opts, job, epoch, seal, target, operation)

  defp export_transition(state, opts, job, {:commit, epoch, token, seal, prepared, operation}) do
    case Crawler.Store.ExportRun.commit(state, opts, job, epoch, token, seal, prepared, operation) do
      {{:ok, :committed} = reply, state} ->
        state =
          complete_scheduler_claim(
            state,
            opts.scheduler_claim,
            Crawler.Job.Outcome.new(:succeeded),
            :completion
          )

        {reply, state}

      result ->
        result
    end
  end

  defp export_transition(state, opts, _job, {:filesystem, epoch, reference, receipt}),
    do: Crawler.Store.ExportRun.filesystem(state, opts, epoch, reference, receipt)

  defp export_transition(state, opts, _job, {:reserve, epoch, operation, plan}),
    do: Crawler.Store.ExportRun.reserve(state, opts, epoch, operation, plan)

  defp export_transition(state, opts, _job, {:written, epoch, operation, ack}),
    do: Crawler.Store.ExportRun.written(state, opts, epoch, operation, ack)

  defp export_transition(state, opts, _job, {:refresh_release, epoch, receipt}),
    do: Crawler.Store.ExportRun.release_refresh(state, opts, epoch, receipt)

  defp export_transition(state, _opts, _job, _command),
    do: {{:error, :invalid_export_command}, state}

  defp export_funded_command(state, opts, job, {:arm, epoch}),
    do: Crawler.Store.ExportRun.arm(state, opts, job, epoch)

  defp export_funded_command(state, opts, _job, {:io_start, epoch, nonce, metadata}),
    do: Crawler.Store.ExportIO.start(state, opts, epoch, nonce, metadata)

  defp export_funded_command(state, opts, job, {:render_funding, epoch, funding, action}),
    do: Crawler.Store.ExportIO.render_funding(state, opts, job, epoch, funding, action)

  defp export_funded_command(state, opts, _job, {:group_versions, epoch, groups, receipt}),
    do: Crawler.Store.ExportRun.group_versions(state, opts, epoch, groups, receipt)

  defp export_funded_command(
         state,
         opts,
         job,
         {:refresh_candidate, epoch, target, version, descriptor, memberships}
       ),
       do:
         Crawler.Store.ExportRun.refresh_candidate(
           state,
           opts,
           job,
           epoch,
           target,
           version,
           descriptor,
           memberships
         )

  defp export_funded_command(
         state,
         opts,
         job,
         {:refresh_discovered, epoch, target, version, groups, bound}
       ),
       do:
         Crawler.Store.ExportRun.refresh_discovered(
           state,
           opts,
           job,
           epoch,
           target,
           version,
           groups,
           bound
         )

  defp export_funded_command(state, opts, job, {:source, epoch, operation, type, final_url}),
    do: Crawler.Store.ExportRun.source(state, opts, epoch, job, operation, type, final_url)

  defp export_funded_command(
         state,
         opts,
         job,
         {:candidate, epoch, version, descriptor, memberships}
       ),
       do:
         Crawler.Store.ExportRun.candidate(
           state,
           opts,
           epoch,
           job.id,
           version,
           descriptor,
           memberships
         )

  defp export_funded_command(state, opts, job, {:discovered, epoch, version, groups, bound}),
    do: Crawler.Store.ExportRun.discovered(state, opts, epoch, job.id, version, groups, bound)

  defp export_funded_command(
         state,
         opts,
         job,
         {:prepared, epoch, token, target, operation, edges}
       ),
       do:
         Crawler.Store.ExportRun.prepared(
           state,
           opts,
           job,
           epoch,
           token,
           target,
           operation,
           edges
         )

  defp export_funded_command(state, _opts, _job, _command),
    do: {{:error, :invalid_export_command}, state}

  defp drive_exports(state, 0), do: state

  defp drive_exports(state, remaining) do
    case Crawler.Store.ExportRun.next_driver(state) do
      {:empty, state} ->
        state

      {:skip, state} ->
        drive_exports(state, remaining - 1)

      {{:launch, key, nonce, options, closed}, state} ->
        state = start_export_driver(state, key, nonce, options, closed)
        drive_exports(state, remaining - 1)
    end
  end

  defp start_export_driver(state, key, nonce, options, closed) do
    {pid, monitor} =
      spawn_monitor(Crawler.Store.ExportRun, :run_driver, [self(), nonce, options, closed])

    Crawler.Store.ExportRun.driver_started(state, key, nonce, pid, monitor)
  catch
    _, _ -> Crawler.Store.ExportRun.driver_failed(state, key, nonce)
  end

  defp release_export_driver(state, monitor, pid, reason) do
    if Map.has_key?(state.export_drivers, monitor) do
      state = Crawler.Store.ExportRun.driver_down(state, monitor, pid, reason)
      schedule_frontier(state)
    else
      state
    end
  end

  defp relay_resource(receipt, lease, producer, holder, payload, reply_to, ref) do
    if Authority.resource_current?(receipt, lease, producer) and
         Authority.resource_current?(receipt, lease, holder) do
      send(holder, {:crawler_resource_delivery, receipt, lease, reply_to, ref, payload})
      :ok
    else
      {:error, :stale}
    end
  end

  defp ensure_page_grants(state, refs, lease, worker) do
    Enum.reduce(refs, state, fn ref, state ->
      ensure_page_grant(state, ref, lease, worker)
    end)
  end

  defp fund_robots_reader(state, scope, origin, worker) do
    lease = state.execution_workers[worker]
    receipt = get_in(state.robots_receipts, [{scope, State.generation(state, scope)}, origin])

    case {state.executions[lease], Resources.receipt(state.resources, receipt)} do
      {%{arena: arena}, %{holders: holders}} ->
        if Map.has_key?(holders, worker) do
          {:ok, state}
        else
          retain_robots_reader(state, receipt, arena, lease, worker)
        end

      _ ->
        {:ok, state}
    end
  end

  defp note_limit(state, scope, generation, {kind, _} = reason)
       when kind in [:limit, :deadline] do
    case state.scopes[scope] do
      %{reported_limit: nil} = run ->
        if State.generation(state, scope) === generation,
          do: %{state | scopes: Map.put(state.scopes, scope, %{run | reported_limit: reason})},
          else: state

      _ ->
        state
    end
  end

  defp note_limit(state, _scope, _generation, _reason), do: state

  defp debit_terminal_control(state, lease) do
    case state.executions[lease] do
      %{
        control_active: active,
        control_terminal_debited?: false,
        opts: %{scope: scope, generation: generation}
      } = record
      when active > 0 ->
        case state.scopes[scope] do
          nil ->
            state

          run ->
            debit_current_control(state, scope, generation, lease, record, run, active)
        end

      _ ->
        state
    end
  end

  defp notify_execution_revocation(state, lease, result) do
    case state.executions[lease] do
      %{status: :returned} ->
        state

      %{revocation_sent?: true} ->
        state

      %{observer: observer, worker: worker} = record when is_pid(observer) ->
        result =
          if result == {:error, :stale} and record.opts[:scheduler_kind] == :fetch,
            do: {:warn, :stale},
            else: result

        send(observer, {:crawler_execution_revoked, worker, lease, result})

        %{
          state
          | executions: Map.put(state.executions, lease, Map.put(record, :revocation_sent?, true))
        }

      _ ->
        state
    end
  end

  defp debit_and_revoke_execution(state, lease) do
    state = debit_terminal_control(state, lease)
    Authority.revoke_execution(lease)
    state
  end

  defp revoke_execution(state, lease) do
    state =
      case state.executions[lease] do
        %{deadline: deadline} ->
          result = {:error, {:deadline, deadline.kind}}
          state = fail_owned_robots(state, lease, result)
          notify_execution_revocation(state, lease, result)

        _ ->
          state
      end

    state = debit_and_revoke_execution(state, lease)

    case state.executions[lease] do
      %{opts: %{scheduler_claim: claim}, deadline: deadline} ->
        complete_scheduler_claim(
          state,
          claim,
          Crawler.Job.Outcome.new(:limited, {:deadline, deadline.kind}),
          :local
        )

      _ ->
        state
    end
  end

  defp robots_reply({:error, reason} = error) do
    if Crawler.Store.RunStatus.limit_reason(reason),
      do: error,
      else: {:ready, Robots.disallow_all()}
  end

  defp robots_reply(rules), do: {:ready, rules}

  defp fail_owned_robots(state, lease, {:error, reason} = result) do
    with reason when not is_nil(reason) <- Crawler.Store.RunStatus.limit_reason(reason),
         %{worker: worker, opts: opts} <- state.executions[lease],
         %{revision: _} <- state.scopes[opts.scope],
         true <- State.generation(state, opts.scope) === opts.generation,
         true <- Map.has_key?(state.scopes[opts.scope].work, opts.queue) do
      {waiters, state} = State.forget_robots_owner(state, opts.scope, worker, opts.queue)
      reply_robots(waiters, result)
      state
    else
      _ -> state
    end
  end

  defp release_execution(state, lease) do
    state = Crawler.Store.CustomStorage.execution_ended(state, lease)
    state = Crawler.Store.SourceManager.execution_ended(state, lease)
    state = Crawler.Store.ExportIO.execution_ended(state, lease)
    state = Crawler.Store.ExportRun.execution_ended(state, lease)
    state = debit_terminal_control(state, lease)

    state =
      if state.executions[lease],
        do: Crawler.Store.SourceWitness.clear_decoded(state, lease),
        else: state

    case Map.pop(state.executions, lease) do
      {nil, _} ->
        state

      {record, executions} ->
        Authority.revoke_execution(lease)
        Process.cancel_timer(record.timer)
        Process.demonitor(record.monitor, [:flush])
        state = release_css_owner(state, lease, 32)

        Crawler.Store.ExportRun.progress(
          %{
            state
            | executions: executions,
              execution_monitors: Map.delete(state.execution_monitors, record.monitor),
              execution_workers: Map.delete(state.execution_workers, record.worker),
              execution_runs:
                drop_run_execution(
                  state.execution_runs,
                  {record.opts.scope, record.opts.generation},
                  lease
                ),
              execution_claims: Map.delete(state.execution_claims, record.opts[:scheduler_claim])
          },
          {record.opts.scope, record.opts.generation}
        )
    end
  end

  defp drop_run_execution(index, key, lease) do
    ring = Map.get(index, key, Crawler.Frontier.Ring.new()) |> Crawler.Frontier.Ring.delete(lease)

    if Crawler.Frontier.Ring.size(ring) == 0,
      do: Map.delete(index, key),
      else: Map.put(index, key, ring)
  end

  defp reply_robots(waiters, reply) do
    Enum.each(waiters, fn {from, _queue} -> GenServer.reply(from, reply) end)
  end

  defp retire_scope(state, scope) do
    case state.scopes[scope] do
      %{run_timer: timer} when is_reference(timer) -> Process.cancel_timer(timer)
      _ -> :ok
    end

    reference = make_ref()

    disposal = %{
      runs: Map.get(state.scope_runs, scope, Crawler.Frontier.Ring.new()),
      pages: Map.get(state.retained_pages, scope, Crawler.Frontier.Ring.new())
    }

    state = %{
      state
      | scope_runs: Map.delete(state.scope_runs, scope),
        retained_pages: Map.delete(state.retained_pages, scope),
        scope_disposals: Map.put(state.scope_disposals, reference, disposal),
        disposal_order: Crawler.Frontier.Ring.put(state.disposal_order, reference)
    }

    state = schedule_scope_disposal(state)

    state =
      if Map.has_key?(state.scopes, scope),
        do: retire_frontier(state, {scope, State.generation(state, scope)}),
        else: state

    Authority.delete(scope)
    unregister_scope(scope)
    state = Settlements.drop_scope(state, scope)
    {waiters, state} = State.drop_scope(state, scope)
    reply_robots(waiters, {:error, :stale})
    state
  end

  defp release_claim(state, token, worker) do
    case Claims.take(state.claims, token, worker) do
      {nil, _claims} ->
        state

      {claim, claims} ->
        Process.demonitor(token, [:flush])
        state = Settlements.claim_finished(%{state | claims: claims}, token)

        if existing_claim_scope?(state, claim) do
          state
          |> State.finish_work(claim.scope, claim.reserved?, claim.queue)
          |> settle_scope_work(claim.scope)
          |> Crawler.Store.ExportRun.progress({claim.scope, claim.generation})
        else
          state
        end
    end
  end

  defp note_claim_limit(state, token, worker, reason) do
    with reason when not is_nil(reason) <- Crawler.Store.RunStatus.limit_reason(reason),
         %{worker: ^worker} = claim <- state.claims.active[token],
         true <- current_work?(state, claim.scope, claim.generation, claim.queue),
         true <-
           Enum.any?(state.settlements.candidates, fn
             {_, %{status: {:running, ^token}} = candidate} ->
               candidate.key === claim.primary_key and
                 candidate.generation === claim.generation and candidate.queue === claim.queue

             _ ->
               false
           end) do
      note_limit(state, claim.scope, claim.generation, reason)
    else
      _ -> state
    end
  end

  defp existing_claim_scope?(state, claim) do
    Map.has_key?(state.scopes, claim.scope) and
      State.generation(state, claim.scope) === claim.generation and
      State.queue_active?(state, claim.scope, claim.queue)
  end

  defp counted_target?(state, target, run) when is_reference(target) do
    case state.scheduler.frontier.jobs[target] do
      %{job: job, outcome: %{status: :succeeded}} -> Crawler.Frontier.run_key(job) === run
      _ -> false
    end
  end

  defp counted_target?(_state, _target, _run), do: true

  defp count_completed_page(state, false, _scope, _queue), do: state

  defp count_completed_page(state, _count, scope, queue) do
    State.increment(state, :ops, scope, queue)
  end

  defp retain_completed_alias(state, _key, _alias_key, nil, _worker), do: {:ok, state}

  defp retain_completed_alias(state, key, key, receipt, worker),
    do: {:ok, reject_alias_completion(state, receipt, worker)}

  defp retain_completed_alias(state, key, alias_key, receipt, worker) do
    lease = state.execution_workers[worker]

    with %{worker: ^worker, physical_final_url: final, opts: %{scheduler_claim: claim}} <-
           state.executions[lease],
         true <- is_binary(final) and Crawler.URL.canonical(final) === elem(alias_key, 0),
         %{job: %{logical_key: logical, authority: {scope, _, _}}} = record <-
           state.scheduler_workers[claim],
         true <-
           key === {logical, scope},
         %{kind: :source, lease: ^lease, executor: ^worker, actual: actual, holders: holders}
         when is_integer(actual) and actual >= 8192 <-
           Resources.receipt(state.resources, receipt),
         %{status: :pending, origin: ^worker, lease: ^lease} <- holders[self()],
         true <- Authority.resource_current?(receipt, lease, self()),
         {:ok, _} <- Crawler.Store.Retained.bytes({claim, alias_key}, actual - 8192) do
      case {State.owns_page?(state, alias_key, elem(record.job.authority, 2)),
            record[:completed_alias]} do
        {true, nil} ->
          {:ok, state} =
            ResourceManager.transition(state, Resources.adopt(state.resources, receipt, self()))

          record = Map.put(record, :completed_alias, {alias_key, receipt})

          state = %{state | scheduler_workers: Map.put(state.scheduler_workers, claim, record)}
          state = ResourceManager.retain_persistent(state, receipt, scope)

          {:ok, state}

        _ ->
          {:ok, reject_alias_completion(state, receipt, worker)}
      end
    else
      _ -> {:error, :stale}
    end
  end

  defp reject_alias_completion(state, receipt, worker) do
    case Resources.receipt(state.resources, receipt) do
      %{kind: :source, executor: ^worker, lease: lease} ->
        release_rejected_pregrant(state, %{execution_lease: lease}, worker, receipt, :source)

      _ ->
        state
    end
  end

  defp consume_completed_alias(state, claim, job) do
    case state.scheduler_workers[claim][:completed_alias] do
      {{logical, scope}, _receipt} ->
        {^scope, generation, queue} = job.authority

        state = commit_completed_alias(state, logical, scope, job, generation, queue)

        release_completed_alias(state, claim)

      _ ->
        state
    end
  end

  defp release_completed_alias(state, claim) do
    case state.scheduler_workers[claim] do
      %{completed_alias: {_key, receipt}} = record ->
        state = %{
          state
          | scheduler_workers:
              Map.put(state.scheduler_workers, claim, Map.delete(record, :completed_alias))
        }

        ResourceManager.release_persistent(state, receipt)

      _ ->
        state
    end
  end

  defp commit_completed_alias(state, logical, scope, job, generation, queue) do
    if match?(%{status: :succeeded}, Crawler.Frontier.outcome(state.scheduler.frontier, job.id)) and
         current_work?(state, scope, generation, queue) do
      Registry.update_value(
        DB,
        {logical, scope},
        &%{&1 | processed: true, alias_owner: {:completed, job.id}}
      )

      state = State.forget_page(state, {logical, scope})

      scheduler =
        Crawler.Store.Scheduler.mark_processed(
          state.scheduler,
          {scope, generation},
          logical,
          State.count(state, :ops, scope)
        )

      %{state | scheduler: scheduler}
    else
      state
    end
  end

  defp remove_retained_receipt(retained_pages, scope, receipt) do
    case retained_pages[scope] do
      nil ->
        retained_pages

      ring ->
        ring = Crawler.Frontier.Ring.delete(ring, receipt)

        if Crawler.Frontier.Ring.size(ring) == 0,
          do: Map.delete(retained_pages, scope),
          else: Map.put(retained_pages, scope, ring)
    end
  end

  defp complete_alias(state, nil, _queue), do: state

  defp complete_alias(state, key, queue) do
    lease = Process.get(:crawler_current_execution)
    claim = get_in(state.executions, [lease, :opts, :scheduler_claim])

    if match?({^key, _}, get_in(state.scheduler_workers, [claim, :completed_alias])) do
      state
    else
      mark_alias_page(state, key, queue)
    end
  end

  defp mark_alias_page(state, key, queue) do
    if State.owns_page?(state, key, queue) do
      Registry.update_value(DB, key, &%{&1 | processed: true})
      State.forget_page(state, key)
    else
      state
    end
  end

  defp retire_queue(state, queue) do
    {token, frontier} = Crawler.Frontier.retire_queue(state.scheduler.frontier, queue)

    if token && Crawler.Frontier.Ring.size(state.retiring_queues) == 0,
      do: send(self(), :retire_queue_frontier)

    ring =
      if token,
        do: Crawler.Frontier.Ring.put(state.retiring_queues, token),
        else: state.retiring_queues

    state = %{state | retiring_queues: ring, scheduler: %{state.scheduler | frontier: frontier}}
    scopes = State.queue_scopes(state, queue)

    generations =
      Map.new(scopes, &{&1, {State.generation(state, &1), state.scopes[&1].run_timer}})

    state = Settlements.drop_queue(state, queue)
    {pages, state} = State.release_queue(state, queue)

    Enum.each(scopes, &Authority.put(state, &1))
    {waiters, state} = State.retire_robots_queue(state, queue)
    reply_robots(waiters, :retry)

    state =
      Enum.reduce(scopes, state, fn scope, state ->
        retire_rotated_scope(state, scope, generations[scope])
      end)

    state = Enum.reduce(pages, state, &ResourceManager.remove_page(&2, &1))

    state =
      Enum.reduce(scopes, state, fn scope, state ->
        if Map.has_key?(state.scopes, scope), do: settle_scope_work(state, scope), else: state
      end)

    if Process.alive?(queue) do
      state
    else
      %{state | closing: MapSet.delete(state.closing, queue)}
    end
  end

  defp retire_rotated_scope(state, scope, {generation, timer}) do
    if Map.has_key?(state.scopes, scope) and State.generation(state, scope) === generation do
      state
    else
      if is_reference(timer), do: Process.cancel_timer(timer)
      state = arm_rotated_run_timer(state, scope)
      state = retire_frontier(state, {scope, generation})
      {waiters, state} = State.clear_scope_caches(state, scope)
      reply_robots(waiters, {:error, :stale})
      state
    end
  end

  defp arm_run_timer(run, scope, generation, deadline) do
    timer =
      run.run_timer ||
        Process.send_after(
          self(),
          {:expire_run, scope, generation},
          Crawler.Deadline.remaining(deadline)
        )

    %{run | run_deadline: deadline, run_timer: timer}
  end

  defp arm_rotated_run_timer(state, scope) do
    case state.scopes[scope] do
      %{outcome: :open, run_deadline: %Crawler.Deadline{} = deadline} = run ->
        run = arm_run_timer(run, scope, State.generation(state, scope), deadline)
        %{state | scopes: Map.put(state.scopes, scope, run)}

      _ ->
        state
    end
  end

  defp checkout_settlement(state, queue, worker) do
    case Settlements.next(state, queue) do
      nil ->
        {:reply, :empty, state}

      ref ->
        {reply, state} = start_settlement(state, ref, worker)

        reply =
          case reply do
            {:ok, token, options, bytes} -> {:alias_settlement, ref, token, options, bytes}
            :skip -> :empty
          end

        {:reply, reply, state}
    end
  end

  defp start_settlement(state, ref, worker) do
    queue =
      case state.settlements.candidates[ref] do
        %{queue: queue} -> queue
        _ -> nil
      end

    {reply, state} = enroll_settlement(state, ref, worker)
    ensure_queue_ticket(state, queue)
    {reply, state}
  end

  defp enroll_settlement(state, ref, worker) do
    case Settlements.start(state, ref) do
      {:ok, candidate, state} ->
        token = Process.monitor(worker)
        opts = Map.put(candidate.opts, :page_key, candidate.key)
        claims = Claims.track(state.claims, token, worker, opts, false)
        state = Settlements.started(%{state | claims: claims}, ref, token)

        options =
          candidate.opts
          |> Map.take(
            Map.keys(Crawler.Limits.defaults()) ++
              [
                :scope,
                :generation,
                :queue,
                :run_deadline,
                :crawler_deadline,
                :attempt_timeout,
                :run_timeout
              ]
          )
          |> Map.put(:scheduler_kind, :alias_settlement)
          |> Map.put(:scheduler_claim, nil)

        bytes = Resources.receipt(state.resources, hd(candidate.resources)).actual
        {{:ok, token, options, bytes}, state}

      {:skip, scope, state} ->
        {:skip, settle_scope_work(state, scope)}

      {:skip, state} ->
        {:skip, state}
    end
  end

  defp queue_ready?(state, queue),
    do:
      Crawler.Frontier.ready?(state.scheduler.frontier, queue) or Settlements.ready?(state, queue)

  defp ensure_queue_ticket(state, queue) when is_pid(queue),
    do: Crawler.QueueTickets.ensure(queue, if(queue_ready?(state, queue), do: 1, else: 0))

  defp ensure_queue_ticket(_state, _queue), do: :ok

  defp settle_scope_work(state, scope) do
    state = Settlements.prune(state, scope)
    state = cleanup_idle_pages(state, scope)
    {queues, state} = Settlements.schedule(state, scope)
    Enum.each(queues, &ensure_queue_ticket(state, &1))
    state
  end

  defp monitor_queue(state, queue) when is_pid(queue) do
    if Map.has_key?(state.monitors, queue) do
      state
    else
      %{state | monitors: Map.put(state.monitors, queue, Process.monitor(queue))}
    end
  end

  defp monitor_queue(state, _queue), do: state

  defp admission_authorized?(state, opts, reset?) do
    case Process.get(:crawler_current_execution) do
      nil ->
        true

      lease ->
        case state.executions[lease] do
          %{opts: bound} ->
            not reset? and bound.scope === opts[:scope] and
              (is_nil(opts[:generation]) or bound.generation == opts[:generation]) and
              Authority.current?(bound.scope, bound.generation, bound.queue, lease)

          _ ->
            false
        end
    end
  end

  defp current_work?(state, scope, generation, queue) do
    execution? =
      case Process.get(:crawler_current_execution) do
        nil ->
          true

        lease ->
          case state.executions[lease] do
            %{opts: bound} ->
              bound.scope === scope and (is_nil(generation) or bound.generation == generation) and
                (is_nil(queue) or bound.queue == queue) and
                Authority.current?(bound.scope, bound.generation, bound.queue, lease)

            _ ->
              false
          end
      end

    execution? and State.current?(state, scope, generation) and queue_available?(state, queue) and
      State.queue_active?(state, scope, queue)
  end

  defp queue_available?(_state, nil), do: true

  defp queue_available?(state, queue) when is_pid(queue) do
    Process.alive?(queue) and not MapSet.member?(state.closing, queue)
  end

  defp queue_available?(_state, _queue), do: false

  defp await_registry_shutdown do
    case Process.whereis(DB) do
      nil ->
        :ok

      registry ->
        # A killed Store exits before its linked Registry completes shutdown.
        ref = Process.monitor(registry)

        receive do
          {:DOWN, ^ref, :process, ^registry, _reason} -> :ok
        end
    end
  end

  defp unregister_scope(scope) do
    DB
    |> Registry.select([
      {{:"$1", :_, :_}, [{:"=:=", {:element, 2, :"$1"}, {:const, scope}}], [:"$1"]}
    ])
    |> Enum.each(&Registry.unregister(DB, &1))
  end

  defp commit_job_admission(
         state,
         candidate,
         scheduler,
         opts,
         scope,
         generation,
         reset?,
         deadline,
         handle,
         admission
       ) do
    if admission == :ok or
         (match?({:blocked, _}, admission) and ResourceManager.releasable?(candidate)) do
      candidate =
        if reset? and Map.has_key?(state.scopes, scope) do
          old_key = {scope, State.generation(state, scope)}
          retired = retire_scope(state, scope)

          Crawler.Store.ExportRun.merge_admission(
            %{
              retired
              | scheduler: Crawler.Store.Scheduler.retire(scheduler, old_key),
                scopes: Map.put(retired.scopes, scope, candidate.scopes[scope])
            },
            candidate,
            {scope, generation}
          )
        else
          candidate
        end

      candidate =
        candidate
        |> State.register_queue(scope, opts[:queue])
        |> monitor_queue(opts[:queue])

      run = candidate.scopes[scope]

      run = arm_run_timer(run, scope, generation, deadline)

      runs =
        Map.update(
          candidate.scope_runs,
          scope,
          Crawler.Frontier.Ring.put(Crawler.Frontier.Ring.new(), {scope, generation}),
          &Crawler.Frontier.Ring.put(&1, {scope, generation})
        )

      candidate = %{
        candidate
        | scopes: Map.put(candidate.scopes, scope, run),
          scope_runs: runs
      }

      Authority.put(candidate, scope)
      candidate = Crawler.Store.ExportRun.commit_admission(candidate, opts)
      {:reply, {:ok, Map.put(opts, :target_handle, handle)}, schedule_frontier(candidate)}
    else
      reason =
        case admission do
          {:limited, key} -> {:limit, key}
          {:blocked, _} -> {:limit, :production_headroom}
          {:error, reason} -> reason
        end

      {:reply, {:error, reason}, note_limit(state, scope, generation, reason)}
    end
  end

  defp reply_direct_admission(state, candidate, admitted, from, deadline, bytes) do
    target = admitted.target_handle
    outcome = Crawler.Frontier.outcome(candidate.scheduler.frontier, target)

    if outcome do
      {:reply, {:terminal, outcome, admitted},
       %{candidate | waiting_bytes: candidate.waiting_bytes - bytes}}
    else
      owner? = not Map.has_key?(state.scheduler.frontier.jobs, target)
      candidate = enroll_direct(candidate, from, target, deadline, owner?, bytes)
      {:noreply, schedule_frontier(candidate)}
    end
  end

  defp settle_released_claim(state, {scope, generation}) do
    if Map.has_key?(state.scopes, scope) and State.generation(state, scope) === generation do
      if State.current?(state, scope, generation),
        do: settle_scope_work(state, scope),
        else: cleanup_idle_pages(state, scope)
    else
      state
    end
  end

  defp settle_released_claim(state, _run), do: state

  defp cleanup_retired_jobs(state, ids, claims) do
    state = Enum.reduce(claims, state, &release_completed_alias(&2, &1))
    state = Enum.reduce(claims, state, &Settlements.claim_finished(&2, &1))

    Enum.reduce(ids, state, fn id, state ->
      case state.scheduler.frontier.jobs[id] do
        %{job: job, outcome: %Crawler.Job.Outcome{}} -> cleanup_terminal_page(state, job)
        _ -> state
      end
    end)
  end

  defp cleanup_terminal_page(state, job) do
    {scope, generation, queue} = job.authority

    if Map.has_key?(state.scopes, scope) and State.generation(state, scope) === generation do
      key = {job.logical_key, scope}
      state = reconcile_page_cleanup(state, key, queue)

      state =
        case Registry.lookup(DB, key) do
          [{_, %Page{target_handle: target}}] ->
            release_failed_page(state, target, key, scope, generation)

          _ ->
            state
        end

      cleanup_idle_pages(state, scope)
    else
      state
    end
  end

  defp cleanup_idle_pages(state, scope) do
    direct_pages = get_in(state.scopes[scope].work, [nil, Access.key(:pages, MapSet.new())])
    {pages, state} = State.take_idle_pages(state, scope)

    Enum.reduce(pages, state, fn key, state ->
      cond do
        Aliases.completed?(state, key) ->
          state

        MapSet.member?(direct_pages || MapSet.new(), key) ->
          cleanup_direct_page(state, key, scope)

        true ->
          ResourceManager.remove_page(state, key)
      end
    end)
  end

  defp cleanup_direct_page(state, key, scope) do
    generation = State.generation(state, scope)

    case Registry.lookup(DB, key) do
      [{_, %Page{target_handle: target}}] when is_reference(target) ->
        state = release_failed_page(state, target, key, scope, generation)
        if Registry.lookup(DB, key) == [], do: state, else: State.track_page(state, key, nil)

      [{_, %Page{}}] ->
        State.track_page(state, key, nil)

      _ ->
        state
    end
  end

  defp complete_scheduler_claim(state, claim, outcome, origin) do
    case state.scheduler_workers[claim] do
      %{job: job} ->
        key = Crawler.Frontier.run_key(job)
        before_count = Crawler.Frontier.counts(state.scheduler.frontier, key).completed

        case Crawler.Store.Scheduler.complete(state.scheduler, claim, outcome, origin) do
          {:ok, scheduler} ->
            state = %{state | scheduler: scheduler}
            state = complete_job_effects(state, claim, job, outcome, before_count)
            schedule_frontier(state)

          {:stale, scheduler} ->
            %{state | scheduler: scheduler}
        end

      _ ->
        state
    end
  end

  defp complete_job_effects(state, claim, job, outcome, before_count) do
    after_count =
      Crawler.Frontier.counts(state.scheduler.frontier, Crawler.Frontier.run_key(job)).completed

    {scope, generation, queue} = job.authority

    state =
      if outcome.status == :limited,
        do: note_limit(state, scope, generation, outcome.reason),
        else: state

    state =
      if after_count > before_count and current_work?(state, scope, generation, queue),
        do: State.increment(state, :ops, scope, queue),
        else: state

    if outcome.reason == :control_document and
         current_work?(state, scope, generation, queue) do
      Registry.update_value(DB, {job.logical_key, scope}, fn page ->
        %{page | opts: Map.put(page.opts || %{}, :count_page, false)}
      end)
    end

    state = PageCandidates.complete(state, claim, job)
    state = consume_completed_alias(state, claim, job)
    state = cleanup_terminal_page(state, job)
    state = Settlements.claim_finished(state, claim)

    if Map.has_key?(state.scopes, scope), do: settle_scope_work(state, scope), else: state
  end

  defp finish_page_replacement(state, :error, _lease, _context),
    do: {:reply, :error, state}

  defp finish_page_replacement(state, result, lease, {scope, receipt, refs, old_refs}) do
    state =
      if lease,
        do: retain_page_resources(state, scope, receipt, refs, old_refs),
        else: state

    state =
      Enum.reduce(
        MapSet.difference(old_refs, refs),
        state,
        &ResourceManager.release_persistent(&2, &1)
      )

    {:reply, if(lease, do: :stored, else: result), state}
  end

  defp retain_page_resources(state, scope, receipt, refs, old_refs) do
    {_, state} =
      ResourceManager.transition(state, Resources.adopt(state.resources, receipt, self()))

    Enum.reduce(MapSet.difference(refs, old_refs), state, fn ref, state ->
      ResourceManager.retain_persistent(state, ref, scope)
    end)
  end

  defp reconcile_page_cleanup(state, {_, scope} = key, queue) do
    case Registry.lookup(DB, key) do
      [{_, %Page{}}] ->
        if Aliases.completed?(state, key) do
          State.forget_page(state, key)
        else
          track_provisional_page(state, key, scope, queue)
        end

      _ ->
        state
    end
  end

  defp track_provisional_page(state, key, scope, queue) do
    owner =
      case Aliases.owner(state, key) do
        {:owned, owner} -> owner
        _ -> queue
      end

    if Map.has_key?(state.scopes, scope) and State.queue_active?(state, scope, owner),
      do: State.track_page(state, key, owner),
      else: state
  end

  defp release_failed_page(state, target, key, scope, generation) do
    failed_owner? =
      case state.scheduler.frontier.jobs[target] do
        %{job: owner_job, outcome: %{status: status}} ->
          group =
            get_in(state.scheduler.frontier.runs, [
              {scope, generation},
              :groups,
              owner_job.logical_key
            ])

          Crawler.Frontier.run_key(owner_job) === {scope, generation} and
            status != :succeeded and not is_nil(group) and MapSet.size(group.active) == 0 and
            not Aliases.completed?(state, key)

        _ ->
          false
      end

    pending? =
      case Aliases.owner(state, key) do
        {:owned, queue} when is_pid(queue) or is_nil(queue) ->
          Crawler.Frontier.queue_pending(state.scheduler.frontier, {scope, generation}, queue) > 0

        _ ->
          false
      end

    if failed_owner? and not pending? do
      ResourceManager.remove_page(state, key)
    else
      state
    end
  end

  defp resource_execution_current?(state, lease, worker) do
    case state.executions[lease] do
      %{worker: ^worker, preparation?: true, deadline: deadline} ->
        Process.alive?(worker) and Crawler.Deadline.check(deadline) == :ok

      _ ->
        Authority.execution_current?(lease, worker)
    end
  end

  defp acquire_execution(
         state,
         opts,
         deadline,
         from,
         worker,
         lease,
         run,
         options,
         preparation? \\ false
       ) do
    case Resources.acquire(
           state.resources,
           run,
           lease,
           worker,
           ResourceManager.envelope(opts),
           options
         ) do
      {{:ok, arena}, resources, effects} ->
        monitor = Process.monitor(worker)
        if not preparation?, do: Authority.put_execution(lease, worker, deadline, opts)

        timer =
          Process.send_after(
            self(),
            {:expire_execution, lease},
            Crawler.Deadline.remaining(deadline)
          )

        record = %{
          preparation?: preparation?,
          control_sequence: 0,
          control_active: 0,
          control_terminal_debited?: false,
          control_entity_bytes: 0,
          max_body: opts.max_body,
          max_control_bytes: opts.max_control_bytes,
          max_control_documents: opts.max_control_documents,
          worker: worker,
          observer: opts[:execution_observer],
          arena: arena,
          monitor: monitor,
          deadline: deadline,
          timer: timer,
          opts: Map.take(opts, [:scope, :generation, :queue, :scheduler_claim, :scheduler_kind])
        }

        state = %{
          state
          | executions: Map.put(state.executions, lease, record),
            execution_monitors: Map.put(state.execution_monitors, monitor, lease),
            execution_workers: Map.put(state.execution_workers, worker, lease),
            execution_runs:
              Map.update(
                state.execution_runs,
                run,
                Crawler.Frontier.Ring.put(Crawler.Frontier.Ring.new(), lease),
                &Crawler.Frontier.Ring.put(&1, lease)
              ),
            execution_claims:
              if(opts[:scheduler_claim],
                do: Map.put(state.execution_claims, opts.scheduler_claim, lease),
                else: state.execution_claims
              )
        }

        {_, state} = ResourceManager.transition(state, {{:ok, arena}, resources, effects})
        {:reply, {:ok, lease}, state}

      {{:blocked, _key}, _resources, _effects} ->
        cond do
          preparation? -> {:reply, {:error, {:limit, :max_retained_bytes}}, state}
          ResourceManager.releasable?(state) -> defer_execution(state, opts, deadline, from)
          true -> {:reply, {:error, {:limit, :production_headroom}}, state}
        end

      {reason, _resources, _effects} ->
        reason =
          execution_acquisition_error(reason)

        {:reply, reason, state}
    end
  end

  defp execution_acquisition_error(reason) do
    case reason do
      {:limited, key} ->
        {:error, {:limit, key}}

      error ->
        error
    end
  end

  defp complete_owned_css(state, lease, worker, key, record, revision, outcome) do
    if Authority.execution_current?(lease, worker) do
      current? =
        record.revision == revision and not match?({:superseded, _}, outcome) and
          outcome != :superseded

      record = %{
        record
        | owner: nil,
          active_revision: nil,
          committed:
            if(current? and match?({:ok, _}, outcome),
              do: revision,
              else: record.committed
            ),
          settled: if(current?, do: revision, else: record.settled),
          outcome: if(current?, do: outcome, else: record.outcome)
      }

      keys =
        Map.get(state.css_executions, lease, Crawler.Frontier.Ring.new())
        |> Crawler.Frontier.Ring.delete(key)

      pending =
        if current? and not record.refresh_pending?,
          do: state.css_pending,
          else: Crawler.Frontier.Ring.put(state.css_pending, key)

      state = put_css_record(state, key, record)

      state = %{
        state
        | css_executions: Map.put(state.css_executions, lease, keys),
          css_pending: pending
      }

      if not current? or record.refresh_pending?, do: send(self(), :css_pending)
      {:reply, if(current?, do: :ok, else: :superseded), state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  defp reply_robots_reader(state, scope, origin, pid, rules) do
    {reply, state} = fund_robots_reader(state, scope, origin, pid)
    {:reply, if(reply == :ok, do: {:ready, rules}, else: reply), state}
  end

  defp finish_owned_robots(state, scope, origin, rules, pid, queue, receipt) do
    {waiters, state} = State.finish_robots(state, scope, origin, rules, pid, queue)
    run = {scope, State.generation(state, scope)}

    state =
      if receipt do
        {_, state} =
          ResourceManager.transition(state, Resources.adopt(state.resources, receipt, self()))

        %{
          state
          | robots_receipts:
              Map.update(
                state.robots_receipts,
                run,
                %{origin => receipt},
                &Map.put(&1, origin, receipt)
              ),
            retained_pages:
              Map.update(
                state.retained_pages,
                scope,
                Crawler.Frontier.Ring.put(Crawler.Frontier.Ring.new(), receipt),
                &Crawler.Frontier.Ring.put(&1, receipt)
              )
        }
      else
        state
      end

    state =
      Enum.reduce(waiters, state, fn {from, _}, state ->
        {worker, _} = from
        {reply, state} = fund_robots_reader(state, scope, origin, worker)
        GenServer.reply(from, if(reply == :ok, do: {:ready, rules}, else: reply))
        state
      end)

    {:reply, :ok, state}
  end

  defp charge_control_entity(record, scope, opts, sequence, bytes) do
    bytes = if bytes == :unknown_failure, do: record.max_body, else: bytes

    if is_integer(bytes) and bytes >= 0 do
      {reply, record, scope} = charge_control(record, scope, bytes, opts)
      {reply, %{record | control_sequence: sequence, control_entity_bytes: bytes}, scope}
    else
      {{:error, :invalid_control_bytes}, record, scope}
    end
  end

  defp retire_scheduler_claim(state, claim) do
    state =
      case state.execution_claims[claim] do
        nil ->
          state

        lease ->
          state
          |> notify_execution_revocation(lease, {:error, :stale})
          |> debit_and_revoke_execution(lease)
      end

    case state.scheduler_workers[claim] do
      %{worker: worker} -> Process.exit(worker, :kill)
      _ -> :ok
    end

    state
  end

  defp reply_consumed_resource(state, receipt) do
    case Resources.receipt(state.resources, receipt) do
      %{holders: holders} ->
        if match?(%{status: status} when status in [:pending, :abandoned], holders[self()]) do
          {_, state} =
            ResourceManager.transition(
              state,
              Resources.release(state.resources, receipt, self())
            )

          {:noreply, state}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp notify_direct_waiter(state, reference, target, remaining) do
    record = state.direct_waiters[reference]
    outcome = Crawler.Frontier.outcome(state.scheduler.frontier, target)

    reply =
      if outcome,
        do: {:terminal, outcome, %{target_handle: target}},
        else: {:error, :stale}

    GenServer.reply(record.from, reply)
    state = remove_direct(state, reference)

    scheduler = Crawler.Store.Scheduler.requeue_notification(state.scheduler, target)

    notify_direct(%{state | scheduler: scheduler}, remaining - 1)
  end

  defp fail_execution_waiter(state, remaining) do
    case Index.take(state.resource_waiters, -1) do
      :empty ->
        state

      {:ok, reference, _} ->
        record = state.pending_executions[reference]
        GenServer.reply(record.from, {:error, {:limit, :production_headroom}})
        resume_execution_waiters(remove_execution_waiter(state, reference), remaining - 1)
    end
  end

  defp resume_representation_fork(state, job, id, remaining) do
    opts = job.opts

    if current_work?(state, opts[:scope], opts[:generation], opts[:queue]) do
      state = reattempt_representation(state, job, id)
      resume_representation_forks(state, remaining - 1)
    else
      resume_representation_forks(state, remaining - 1)
    end
  end

  defp reattempt_representation(state, job, id) do
    opts = job.opts

    {{:ok, observation}, state} =
      Crawler.Store.CookieProof.validate(
        state,
        opts.scope,
        opts.generation,
        opts,
        opts[:cookie_proof]
      )

    scheduler =
      Crawler.Store.Scheduler.reattempt(state.scheduler, id, observation.proof)

    state = %{state | scheduler: scheduler}

    case Crawler.Frontier.outcome(scheduler.frontier, id) do
      %{status: :limited, reason: reason} ->
        note_limit(state, opts.scope, opts.generation, reason)

      _ ->
        state
    end
  end

  defp dispose_scope_pages(state, record, reference, order, remaining) do
    case Crawler.Frontier.Ring.take(record.pages) do
      {:ok, receipt, pages} ->
        state = ResourceManager.drop_ordinary(state, receipt)

        state = %{
          state
          | scope_disposals: Map.put(state.scope_disposals, reference, %{record | pages: pages}),
            disposal_order: Crawler.Frontier.Ring.put(order, reference)
        }

        drain_scope_disposals(state, remaining - 1)

      :empty ->
        drain_scope_disposals(
          %{
            state
            | scope_disposals: Map.delete(state.scope_disposals, reference),
              disposal_order: order
          },
          remaining - 1
        )
    end
  end

  defp scope_retirement_result(state, scope, generation) do
    case state.scopes[scope] do
      %{outcome: {:limited, reason}} ->
        if State.generation(state, scope) == generation,
          do: {:error, reason},
          else: {:error, :stale}

      _ ->
        {:error, :stale}
    end
  end

  defp dispatch_css_record(state, remaining, key, record, revision) do
    {run, group} = key
    {scope, generation} = run

    opts =
      Map.drop(record.opts, [
        :execution_lease,
        :crawler_deadline,
        :scheduler_claim,
        :prepared_request
      ])

    if Authority.current?(scope, generation, opts[:queue]) do
      owner = self()

      {:ok, pid} =
        start_css_runner(opts, group, revision, owner, key)

      ref = Process.monitor(pid)

      state = %{
        state
        | css_runners: Map.put(state.css_runners, ref, key),
          css_jobs:
            Map.put(state.css_jobs, key, %{
              record
              | queued?: true,
                runner: pid,
                active_refresh?: record.refresh_pending?,
                refresh_pending?: false
            })
      }

      dispatch_css(state, remaining - 1)
    else
      dispatch_css(state, remaining - 1)
    end
  end

  defp start_css_runner(opts, group, revision, owner, key) do
    Task.start(fn ->
      result =
        Crawler.Store.Execution.run_css(opts, fn owned ->
          with {:ok, _} = result <-
                 apply(Crawler.Parser.CssSheets, :run_settlement, [owned, group, revision]),
               :ok <- Crawler.Export.Producer.refresh(owned),
               do: result
        end)

      completed =
        case result do
          {:ok, actual} -> actual
          _ -> revision
        end

      send(owner, {:css_runner_finished, self(), key, completed, result})
    end)
  end

  defp clear_css_runner(state, key, pid) do
    case state.css_jobs[key] do
      %{runner: ^pid} = record ->
        put_css_record(state, key, %{
          record
          | runner: nil,
            queued?: false,
            active_refresh?: false,
            refresh_pending?: record.refresh_pending? or record.active_refresh?
        })

      _ ->
        state
    end
  end

  defp clear_css_owner_record(state, key, record) do
    record = %{record | owner: nil, active_revision: nil, queued?: false}

    pending =
      if record.settled != record.revision or record.refresh_pending?,
        do: Crawler.Frontier.Ring.put(state.css_pending, key),
        else: state.css_pending

    send(self(), :css_pending)
    %{put_css_record(state, key, record) | css_pending: pending}
  end

  defp write_cookies(state, scope, url, headers, generation, context, expected) do
    lease = context[:execution_lease] || Process.get(:crawler_current_execution)
    execution = state.executions[lease]

    limits =
      Map.merge(Crawler.Cookies.limits(), Map.take(context, Map.keys(Crawler.Cookies.limits())))

    count =
      Enum.reduce_while(headers, 0, fn _, count ->
        if count >= limits.max_cookie_updates, do: {:halt, count}, else: {:cont, count + 1}
      end)

    previous = Crawler.Cookies.Jar.retained_cost(state.cookies[scope])
    scratch = previous + 8192 + count * (4096 + 8 * (limits.max_cookie_bytes + 1024))

    case cookie_arena(state, scope, generation, lease, execution, scratch) do
      {{:ok, arena, token, temporary?}, state} ->
        reserve_cookie_write(
          state,
          scope,
          url,
          headers,
          generation,
          context,
          expected,
          execution,
          scratch,
          arena,
          token,
          temporary?
        )

      {_error, state} ->
        {{:error, {:limit, :max_retained_bytes}}, state}
    end
  end

  defp reserve_cookie_write(
         state,
         scope,
         url,
         headers,
         generation,
         context,
         expected,
         execution,
         scratch,
         arena,
         token,
         temporary?
       ) do
    case ResourceManager.transition(
           state,
           Resources.reserve(state.resources, arena, token, :scratch, scratch)
         ) do
      {{:ok, receipt}, state} ->
        commit_cookie_write(
          state,
          scope,
          url,
          headers,
          generation,
          context,
          expected,
          execution,
          receipt,
          arena,
          token,
          temporary?
        )

      {_error, state} ->
        state =
          if temporary?,
            do:
              elem(
                ResourceManager.transition(state, Resources.close(state.resources, arena)),
                1
              ),
            else: state

        {{:error, {:limit, :max_retained_bytes}}, state}
    end
  end

  defp commit_cookie_write(
         state,
         scope,
         url,
         headers,
         generation,
         context,
         expected,
         execution,
         receipt,
         arena,
         token,
         temporary?
       ) do
    {reply, candidate} =
      Crawler.Store.CookieProof.save(
        state,
        scope,
        url,
        headers,
        generation,
        context,
        expected
      )

    {_, state} =
      ResourceManager.transition(
        state,
        Resources.release(
          state.resources,
          receipt,
          if(execution, do: execution.worker, else: self())
        )
      )

    delta = candidate.cookie_bytes - state.cookie_bytes

    {funded, state} =
      if delta > 0 do
        ResourceManager.transition(
          state,
          Resources.transfer_external(state.resources, arena, token, delta)
        )
      else
        {:ok, state}
      end

    state =
      if funded == :ok do
        %{
          state
          | scopes: candidate.scopes,
            cookies: candidate.cookies,
            cookie_outcomes: candidate.cookie_outcomes,
            cookie_bytes: candidate.cookie_bytes
        }
      else
        state
      end

    state =
      if funded == :ok do
        case Crawler.Store.CookieProof.outcome(state, scope) do
          %{status: :limited, limits: [key | _]} ->
            note_limit(state, scope, State.generation(state, scope), {:limit, key})

          _ ->
            state
        end
      else
        state
      end

    state =
      if temporary?,
        do:
          elem(
            ResourceManager.transition(state, Resources.close(state.resources, arena)),
            1
          ),
        else: state

    {if(funded == :ok, do: reply, else: {:error, {:limit, :max_retained_bytes}}), state}
  end

  defp apply_control_transition(state, scope, lease, record, transition) do
    {reply, record, run, resources} =
      case transition.(record, Map.fetch!(state.scopes, scope)) do
        {reply, record, run} -> {reply, record, run, nil}
        {reply, record, run, resources} -> {reply, record, run, resources}
      end

    run =
      case reply do
        {:error, {:limit, _} = reason} ->
          %{run | reported_limit: run.reported_limit || reason}

        _ ->
          run
      end

    state = %{
      state
      | executions: Map.put(state.executions, lease, record),
        scopes: Map.put(state.scopes, scope, run)
    }

    state =
      case resources do
        nil ->
          state

        {ledger, effects} ->
          elem(ResourceManager.transition(state, {:ok, ledger, effects}), 1)
      end

    {:reply, reply, state}
  end

  defp ensure_page_grant(state, ref, lease, worker) do
    case {Resources.receipt(state.resources, ref), state.executions[lease]} do
      {%{holders: holders}, %{arena: arena}} ->
        if Map.has_key?(holders, self()) or not Authority.resource_current?(ref, lease, worker) do
          state
        else
          elem(
            ResourceManager.transition(
              state,
              Resources.retain_from(state.resources, ref, arena, lease, worker, self())
            ),
            1
          )
        end

      _ ->
        state
    end
  end

  defp retain_robots_reader(state, receipt, arena, lease, worker) do
    {reply, state} =
      ResourceManager.transition(
        state,
        Resources.retain_from(state.resources, receipt, arena, lease, self(), worker)
      )

    if reply == :ok do
      ResourceManager.transition(state, Resources.adopt(state.resources, receipt, worker))
    else
      {reply, state}
    end
  end

  defp debit_current_control(state, scope, generation, lease, record, run, active) do
    if State.generation(state, scope) == generation do
      bytes = min(record.max_control_bytes, run.control_bytes + active * record.max_body)

      %{
        state
        | scopes: Map.put(state.scopes, scope, %{run | control_bytes: bytes}),
          executions:
            Map.put(state.executions, lease, %{record | control_terminal_debited?: true})
      }
    else
      state
    end
  end
end
