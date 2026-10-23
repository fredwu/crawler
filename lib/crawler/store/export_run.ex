defmodule Crawler.Store.ExportRun do
  @moduledoc false

  alias Crawler.Export.Filesystem
  alias Crawler.Export.Session
  alias Crawler.Export.StagedIO
  alias Crawler.Export.StagedIO.Ack
  alias Crawler.Frontier
  alias Crawler.Frontier.Ring
  alias Crawler.Job.Outcome
  alias Crawler.Store.Authority
  alias Crawler.Store.Export
  alias Crawler.Store.ResourceManager
  alias Crawler.Store.Resources
  alias Crawler.Store.Retained

  @owner_bytes 131_072
  @driver_bytes 16_384
  @refresh_bytes 8_192

  def refresh_bytes, do: @refresh_bytes

  def status(state, opts, paused?) do
    key = {opts[:scope], opts[:generation]}

    case state.exports[key] do
      nil ->
        {:ok, nil}

      record ->
        public = Session.status(record.helper.session)
        phase = public_phase(record, paused?)
        run = state.scopes[opts[:scope]]

        {:ok,
         Map.merge(public, %{
           state: phase,
           reason: record.cleanup_failure || record.failure,
           ready?: phase == :ready,
           running?: phase in [:admitting, :finalizing] and not paused?,
           paused?: paused?,
           reported_limit: if(run, do: run.reported_limit)
         })}
    end
  end

  def retired_status(state, opts, paused?) do
    key = {opts[:scope], opts[:generation]}

    if readable_publication?(state, opts) or
         (not Map.has_key?(state.scopes, opts[:scope]) and
            match?(%{retired?: true, phase: :cleanup_failed}, state.exports[key])) or
         (not Map.has_key?(state.scopes, opts[:scope]) and not published?(state.exports[key]) and
            match?(%{retired?: true}, state.exports[key])),
       do: status(state, opts, paused?),
       else: {:error, :stale}
  end

  defp readable_publication?(state, opts) do
    scope = opts[:scope]

    Map.has_key?(state.scopes, scope) and
      Crawler.Store.State.generation(state, scope) === opts[:generation] and
      Crawler.Store.State.queue_active?(state, scope, opts[:queue]) and
      published?(state.exports[{scope, opts[:generation]}])
  end

  defp published?(%{helper: %{session: %{manifest: %{state: :ready}}}}), do: true
  defp published?(_record), do: false

  defp public_phase(%{phase: :finishing}, _paused?), do: :finalizing
  defp public_phase(%{phase: :cleanup_failed}, _paused?), do: :failed
  defp public_phase(%{failure: {:limit, _}}, _paused?), do: :limited
  defp public_phase(%{failure: {:deadline, _}}, _paused?), do: :limited
  defp public_phase(%{failure: :stale}, _paused?), do: :cancelled
  defp public_phase(%{failure: failure}, _paused?) when not is_nil(failure), do: :failed
  defp public_phase(%{helper: %{session: %{manifest: %{state: :ready}}}}, _paused?), do: :ready

  defp public_phase(%{helper: %{phase: phase}}, _paused?) when phase in [:preparing, :sealed],
    do: :finalizing

  defp public_phase(_record, true), do: :paused
  defp public_phase(_record, false), do: :admitting

  def close(state, opts) do
    key = {opts[:scope], opts.generation}

    if Crawler.Store.State.current?(state, opts[:scope], opts.generation) do
      case state.exports[key] do
        nil -> {{:error, :missing_export}, state}
        %{failure: failure} when not is_nil(failure) -> {{:error, failure}, state}
        %{helper: %{phase: phase}} when phase != :admitting -> {{:error, :closed_export}, state}
        record -> close_current(state, opts, record)
      end
    else
      {{:error, :stale}, state}
    end
  end

  defp close_current(state, opts, record) do
    if quiescent?(state, record.run) do
      opts = Map.put(opts, :run_deadline, state.scopes[opts[:scope]].run_deadline)
      opts = finalizer_options(opts, record)

      with :ok <- Crawler.Deadline.check(opts.run_deadline),
           {:accepted, target, scheduler} <-
             Crawler.Store.Scheduler.admit(state.scheduler, opts, nil, :finalize),
           :ok <- close_headroom(state, scheduler, opts),
           %{job: job} = scheduler.frontier.jobs[target],
           proof = %{
             close_token: make_ref(),
             seal_token: make_ref(),
             owner_css_epoch: record.css_epoch,
             quiescent?: true
           },
           {:ok, token, helper} <- Export.close(record.helper, record.epoch, proof, job),
           {:ok, frontier} <- Frontier.wait(scheduler.frontier, target, :finalizer_driver) do
        record = %{record | helper: helper}
        state = put(%{state | scheduler: %{scheduler | frontier: frontier}}, record.run, record)
        Authority.put_export_writer(opts[:scope], opts.generation, record.epoch, :closed)
        {{:ok, %{epoch: record.epoch, close_token: token, target_handle: target}}, state}
      else
        {:busy, _helper} -> {:busy, state}
        {:limited, key, _scheduler} -> {{:error, {:limit, key}}, state}
        {:error, reason, _scheduler} -> {{:error, reason}, state}
        {:error, reason} -> {{:error, reason}, state}
      end
    else
      {:busy, state}
    end
  end

  defp close_headroom(state, scheduler, opts) do
    candidate = %{state | scheduler: scheduler}

    case Resources.admission(
           state.resources,
           {opts[:scope], opts.generation},
           0,
           0,
           ResourceManager.options(candidate, opts)
         ) do
      :ok -> :ok
      {:limited, key} -> {:error, {:limit, key}}
      {:blocked, _} -> {:error, {:limit, :max_retained_bytes}}
      error -> error
    end
  end

  defp finalizer_options(opts, record) do
    opts
    |> Map.take(
      Map.keys(Crawler.Limits.defaults()) ++ [:scope, :generation, :run_deadline, :save_to]
    )
    |> Map.merge(%{
      url: "crawler:finalize:" <> record.id,
      queue: nil,
      count_page: false,
      force: false
    })
  end

  def quiescent?(state, key) do
    Frontier.pending(state.scheduler.frontier, key) == 0 and
      Crawler.Store.State.count(state, :pending, elem(key, 0)) == 0 and
      Crawler.Store.State.count(state, :inflight, elem(key, 0)) == 0 and
      Map.get(state.scheduler.notification_runs, key, 0) == 0 and
      Ring.size(Map.get(state.execution_runs, key, Ring.new())) == 0 and
      Ring.size(Map.get(state.export_io_runs, key, Ring.new())) == 0 and
      Map.get(state.css_unsettled, key, 0) == 0
  end

  def css_revision(state, key, group, revision) do
    case state.exports[key] do
      %{helper: %{phase: :admitting}, failure: nil} = record ->
        invalidate_css(state, key, group, revision, record)

      _ ->
        state
    end
  end

  defp invalidate_css(state, key, group, revision, record) do
    current = record.helper.groups[group]

    if current && current.version.revision === revision do
      state
    else
      serial = record.css_epoch + 1

      case Export.invalidate(record.helper, group, %{serial: serial, revision: revision}) do
        {:ok, helper} -> put(state, key, %{record | helper: helper, css_epoch: serial})
        {:error, reason} -> fail(state, key, reason)
      end
    end
  end

  def ensure(state, opts) do
    case prepare(state, opts) do
      {{:ok, _} = reply, state} -> {reply, commit_admission(state, opts)}
      result -> result
    end
  end

  def prepare(state, opts) do
    key = {opts[:scope], opts.generation}

    case state.exports[key] do
      nil when is_nil(opts.save_to) ->
        {{:ok, nil}, state}

      nil ->
        if first_target?(state, key),
          do: create(state, opts, key),
          else: {{:error, {:snapshot, :export_configuration_changed}}, state}

      %{failure: reason} when not is_nil(reason) ->
        {{:error, reason}, state}

      record ->
        with :ok <- destination(record, opts.save_to),
             true <- record.helper.phase == :admitting or {:error, :closed_export},
             {:ok, record} <- prepare_automatic(record, opts) do
          {{:ok, context(record)}, put(state, key, record)}
        else
          error -> {error, state}
        end
    end
  end

  def commit_admission(state, opts) do
    case state.exports[{opts[:scope], opts.generation}] do
      %{helper: %{phase: :admitting}, failure: nil} = record ->
        Authority.put_export_writer(opts[:scope], opts.generation, record.epoch, :open)
        progress(state, record.run)

      _ ->
        state
    end
  end

  def merge_admission(retired, candidate, key) do
    case candidate.exports[key] do
      nil ->
        retired

      record ->
        %{
          retired
          | exports: Map.put(retired.exports, key, record),
            export_bytes: retired.export_bytes + record.reserved_bytes
        }
    end
  end

  defp first_target?(state, key) do
    case state.scheduler.frontier.runs[key] do
      nil -> true
      run -> MapSet.size(run.jobs) == 0
    end
  end

  def context(record) do
    Map.take(record, [:id, :epoch, :run, :root, :destination, :filesystem, :receipt, :limits])
  end

  @context_bytes 65_536
  @max_waiters 16

  def filesystem(state, opts, epoch, reference, receipt) do
    key = {opts[:scope], opts.generation}
    worker = state.executions[opts.execution_lease].worker

    waiter = %{
      worker: worker,
      lease: opts.execution_lease,
      queue: opts.queue,
      deadline: opts.crawler_deadline,
      receipt: receipt
    }

    case state.exports[key] do
      %{epoch: ^epoch, filesystem: pid, receipt: recovery} = record
      when is_pid(pid) and not is_nil(recovery) ->
        funded_context(state, key, record, waiter)

      %{epoch: ^epoch, phase: :failed, failure: reason} ->
        {{:error, reason}, state}

      %{epoch: ^epoch} = record when map_size(record.waiters) < @max_waiters ->
        with true <- Authority.resource_current?(receipt, opts.execution_lease, worker),
             %{actual: nil, capacity: capacity} when capacity >= @context_bytes <-
               Resources.receipt(state.resources, receipt),
             {:ok, record, state} <- start_filesystem(record, state, opts) do
          record = %{record | waiters: Map.put(record.waiters, reference, waiter)}
          state = put(state, key, record)

          state = %{
            state
            | export_waiters: Map.put(state.export_waiters, reference, key),
              export_waiter_leases:
                Map.put(state.export_waiter_leases, opts.execution_lease, {reference, worker})
          }

          {{:pending, reference}, state}
        else
          false -> {{:error, :stale}, state}
          {:error, _} = error -> {error, state}
          _ -> {{:error, {:limit, :max_retained_bytes}}, state}
        end

      %{epoch: ^epoch} ->
        {{:error, {:limit, :export_waiters}}, state}

      _ ->
        {{:error, :stale_export}, state}
    end
  end

  def activate(state, key, nonce, pid) do
    case state.exports[key] do
      %{nonce: ^nonce, filesystem: ^pid, phase: :dormant} = record ->
        if live_run?(state, record) do
          send(pid, {:crawler_filesystem_activate, nonce, self()})
          put(state, key, %{record | phase: :acquiring})
        else
          retire(state, key)
        end

      _ ->
        state
    end
  end

  def acquired(state, nonce, pid, result) do
    case state.export_actors[pid] do
      nil -> state
      key -> acquired_run(state, key, nonce, pid, result)
    end
  end

  def cancel_waiter(state, reference, worker) do
    case state.export_waiters[reference] do
      nil ->
        state

      key ->
        record = state.exports[key]

        case record.waiters[reference] do
          %{worker: ^worker, lease: lease} ->
            record = %{record | waiters: Map.delete(record.waiters, reference)}

            %{
              put(state, key, record)
              | export_waiters: Map.delete(state.export_waiters, reference),
                export_waiter_leases: Map.delete(state.export_waiter_leases, lease)
            }

          _ ->
            state
        end
    end
  end

  def down(state, monitor, pid, reason) do
    case state.export_monitors[monitor] do
      {key, ^pid} ->
        record = state.exports[key]

        state = %{
          state
          | export_monitors: Map.delete(state.export_monitors, monitor),
            export_actors: Map.delete(state.export_actors, pid)
        }

        filesystem_down(state, key, record, reason)

      _ ->
        state
    end
  end

  def terminal_result(state, pid, nonce, operation, result) do
    with key when not is_nil(key) <- state.export_actors[pid],
         %{terminal: %{pid: ^pid, nonce: ^nonce, operation: ^operation, result: nil} = terminal} =
           record <- state.exports[key],
         true <- result in [{:ok, :promoted}, {:ok, :aborted}, {:error, :cleanup_failed}] do
      terminal_progress(put(state, key, %{record | terminal: %{terminal | result: result}}), key)
    else
      _ -> state
    end
  end

  defp filesystem_down(state, key, %{phase: :unacquired} = record, _reason) do
    state = put(state, key, %{record | filesystem: nil, phase: :failed})
    if record.retired?, do: drop(state, key), else: state
  end

  defp filesystem_down(state, key, %{terminal: terminal} = record, _reason)
       when not is_nil(terminal) do
    result = terminal.result || {:error, :cleanup_failed}
    terminal = %{terminal | down?: true, result: result}
    record = %{record | filesystem: nil, terminal: terminal}
    terminal_progress(put(state, key, record), key)
  end

  defp filesystem_down(state, key, %{phase: :dormant} = record, _reason) do
    failure = record.failure || :stale
    record = %{record | filesystem: nil, phase: :failed, failure: failure}
    state = reply_waiters(put(state, key, record), key, {:error, failure})
    if record.retired?, do: drop(state, key), else: state
  end

  defp filesystem_down(state, key, record, reason) do
    failure = record.failure || failure_reason({:filesystem_down, reason})
    {scope, generation} = key

    if Crawler.Store.State.current?(state, scope, generation),
      do: Authority.put_export_writer(scope, generation, record.epoch, :closed)

    record = %{
      record
      | filesystem: nil,
        phase: :cleanup_failed,
        failure: failure,
        cleanup_failure: {:snapshot, :cleanup_failed}
    }

    reply_waiters(put(state, key, record), key, {:error, failure})
  end

  defp terminal_progress(state, key) do
    record = state.exports[key]

    if record.terminal.down? do
      terminal_complete(state, key, record)
    else
      state
    end
  end

  defp terminal_complete(state, key, record) do
    case {record.terminal.operation, record.terminal.result} do
      {:finish, {:ok, :promoted}} ->
        terminal_succeeded(state, key, record)

      {:abort, {:ok, outcome}} when outcome in [:promoted, :aborted] ->
        terminal_succeeded(state, key, record)

      _ ->
        put(state, key, %{
          record
          | phase: :cleanup_failed,
            cleanup_failure: {:snapshot, :cleanup_failed}
        })
    end
  end

  defp terminal_succeeded(state, key, record) do
    phase = if published?(record), do: :complete, else: :failed
    record = %{record | phase: phase, cleanup_failure: nil}
    state = put(state, key, record)

    if record.retired? and
         (not published?(record) or disposable_publication?(state, record)),
       do: drop(state, key),
       else: state
  end

  defp disposable_publication?(state, %{run: {scope, generation}, retired?: true}) do
    not Map.has_key?(state.scopes, scope) or
      Crawler.Store.State.generation(state, scope) !== generation
  end

  defp disposable_publication?(_state, _record), do: false

  def fail(state, key, reason) do
    reason = failure_reason(reason)

    case state.exports[key] do
      %{helper: %{session: %{manifest: %{state: :ready}}}} ->
        state

      %{failure: nil} = record ->
        {scope, generation} = key

        if Crawler.Store.State.current?(state, scope, generation),
          do: Authority.put_export_writer(scope, generation, record.epoch, :closed)

        record = %{record | failure: reason}
        state = put(state, key, record)
        state = reply_waiters(state, key, {:error, reason})
        state = Crawler.Store.ExportSource.wake_all(state, key)

        if is_pid(record.filesystem) and Process.alive?(record.filesystem),
          do: stop_filesystem(state, key, record),
          else: state

      _ ->
        state
    end
  end

  def retire(state, key, dispose? \\ true) do
    case state.exports[key] do
      nil ->
        state

      %{helper: %{session: %{manifest: %{state: :ready}}}} = record ->
        state = put(state, key, %{record | retired?: true})
        if dispose? and is_nil(record.filesystem), do: drop(state, key), else: state

      %{retired?: true} ->
        state

      record ->
        record = %{record | retired?: true, failure: record.failure || :stale}
        state = put(state, key, record)
        state = reply_waiters(state, key, {:error, :stale})
        state = Crawler.Store.ExportSource.wake_all(state, key)
        if record.driver && is_pid(record.driver.pid), do: Process.exit(record.driver.pid, :kill)

        if is_nil(record.filesystem),
          do: drop(state, key),
          else: stop_filesystem(state, key, record)
    end
  end

  defp stop_filesystem(state, _key, %{phase: :dormant, filesystem: pid}) do
    Process.exit(pid, :shutdown)
    state
  end

  defp stop_filesystem(state, _key, %{phase: :unacquired}), do: state

  defp stop_filesystem(state, key, record), do: start_terminal(state, key, record, :abort)

  defp start_terminal(state, key, %{terminal: nil} = record, operation) do
    nonce = make_ref()

    terminal = %{
      pid: record.filesystem,
      nonce: nonce,
      operation: operation,
      result: nil,
      down?: false
    }

    Filesystem.terminate_owned(record.filesystem, operation, nonce)
    put(state, key, %{record | terminal: terminal})
  end

  defp start_terminal(state, _key, _record, _operation), do: state

  def execution_ended(state, lease) do
    state = Crawler.Store.ExportSource.execution_ended(state, lease)
    state = elem(release_refresh(state, lease), 1)

    state =
      case state.executions[lease] do
        %{export_operation: {epoch, operation}, opts: opts} ->
          elem(
            abandon_reserved(state, Map.put(opts, :execution_lease, lease), epoch, operation),
            1
          )

        _ ->
          state
      end

    case state.export_waiter_leases[lease] do
      nil -> state
      {reference, worker} -> cancel_waiter(state, reference, worker)
    end
  end

  defp start_filesystem(%{filesystem: nil} = record, state, opts) do
    nonce = make_ref()

    with {:ok, pid, monitor} <-
           Filesystem.spawn_acquisition(
             record.root,
             record.destination,
             nonce,
             Crawler.Limits.filesystem(opts)
           ) do
      record = %{record | filesystem: pid, nonce: nonce, phase: :dormant}

      state = %{
        state
        | export_monitors: Map.put(state.export_monitors, monitor, {record.run, pid}),
          export_actors: Map.put(state.export_actors, pid, record.run)
      }

      send(self(), {:activate_export_filesystem, record.run, nonce, pid})
      {:ok, record, state}
    end
  end

  defp start_filesystem(record, state, _opts), do: {:ok, record, state}

  defp acquired_run(state, key, nonce, pid, result) do
    case state.exports[key] do
      %{nonce: ^nonce, filesystem: ^pid, phase: :acquiring} = record ->
        acquired_result(state, key, record, result)

      _ ->
        state
    end
  end

  defp acquired_result(state, key, record, {:ok, receipt}) do
    with true <-
           receipt.root == record.root and receipt.destination == record.destination and
             receipt.mode == :managed,
         {:ok, _} <- Retained.bytes(receipt, @context_bytes) do
      record = %{record | receipt: receipt}
      state = put(state, key, record)

      if live_run?(state, record) do
        state = put(state, key, %{record | phase: :ready})
        reply_waiters(state, key, :ready)
      else
        retire(state, key)
      end
    else
      _ -> retire(state, key)
    end
  end

  defp acquired_result(state, {scope, generation} = key, record, {:error, :unclaimed, reason}) do
    failure = failure_reason(reason)

    if Crawler.Store.State.current?(state, scope, generation),
      do: Authority.put_export_writer(scope, generation, record.epoch, :closed)

    state = put(state, key, %{record | phase: :unacquired, failure: record.failure || failure})
    state = reply_waiters(state, key, {:error, failure})
    Crawler.Store.ExportSource.wake_all(state, key)
  end

  defp acquired_result(state, key, record, {:error, :partial, reason}) do
    record = partial_receipt(record, reason)
    fail(put(state, key, record), key, reason)
  end

  defp acquired_result(state, key, _record, {:error, reason}), do: fail(state, key, reason)

  defp partial_receipt(record, {:setup, _reason, receipt}) do
    if receipt.root == record.root and receipt.destination == record.destination and
         receipt.mode == :managed and match?({:ok, _}, Retained.bytes(receipt, @context_bytes)),
       do: %{record | receipt: receipt},
       else: record
  end

  defp partial_receipt(record, _reason), do: record

  defp failure_reason({:limit, key}) when is_atom(key), do: {:limit, key}

  defp failure_reason({:limit, {domain, key}}) when is_atom(domain) and is_atom(key),
    do: {:limit, {domain, key}}

  defp failure_reason({:deadline, kind}) when kind in [:run, :attempt], do: {:deadline, kind}
  defp failure_reason({:snapshot, reason}) when is_atom(reason), do: {:snapshot, reason}

  defp failure_reason({:filesystem_down, reason}) when reason in [:normal, :shutdown, :killed],
    do: {:filesystem_down, reason}

  defp failure_reason(:stale), do: :stale
  defp failure_reason(reason) when is_atom(reason), do: {:snapshot, reason}
  defp failure_reason(_reason), do: {:snapshot, :export_failed}

  defp reply_waiters(state, key, result) do
    record = state.exports[key]

    Enum.reduce(record.waiters, state, fn {reference, waiter}, state ->
      {reply, state} =
        if result == :ready,
          do: funded_context(state, key, state.exports[key], waiter),
          else: {result, state}

      send(waiter.worker, {:crawler_export_filesystem, reference, reply})
      cancel_waiter(state, reference, waiter.worker)
    end)
  end

  defp funded_context(state, {scope, generation}, record, waiter) do
    with true <- Authority.current?(scope, generation, waiter.queue, waiter.lease),
         true <- Authority.execution_current?(waiter.lease, waiter.worker),
         :ok <- Crawler.Deadline.check(waiter.deadline),
         true <- Authority.resource_current?(waiter.receipt, waiter.lease, waiter.worker),
         {:ok, bytes} <- Retained.bytes(context(record), @context_bytes),
         {:ok, state} <-
           ResourceManager.transition(
             state,
             Resources.commit(state.resources, waiter.receipt, waiter.lease, bytes)
           ) do
      {{:ok, context(record)}, state}
    else
      false -> {{:error, :stale}, state}
      {:error, _} = error -> {error, state}
    end
  end

  defp live_run?(state, %{run: {scope, generation}, retired?: retired?}) do
    not retired? and Crawler.Store.State.current?(state, scope, generation) and
      case state.scopes[scope].run_deadline do
        nil -> true
        deadline -> Crawler.Deadline.check(deadline) == :ok
      end
  end

  def source_drained(state, key) do
    case state.exports[key] do
      %{retired?: true, filesystem: nil} -> drop(state, key)
      _ -> state
    end
  end

  defp drop(state, key) do
    case state.exports[key] do
      %{filesystem: filesystem} when is_pid(filesystem) ->
        state

      %{cleanup_failure: failure} when not is_nil(failure) ->
        state

      %{driver: driver} when not is_nil(driver) ->
        state

      record ->
        if Ring.size(record.source_waiters) == 0,
          do: drop_record(state, key, record),
          else: Crawler.Store.ExportSource.wake_all(state, key)
    end
  end

  defp drop_record(state, key, record) do
    %{
      state
      | exports: Map.delete(state.exports, key),
        export_pending: Ring.delete(state.export_pending, key),
        export_bytes: state.export_bytes - record.reserved_bytes
    }
  end

  def reserve(state, opts, epoch, operation, plan) do
    case state.executions[opts.execution_lease][:export_operation] do
      nil ->
        {reply, state} =
          session_change(state, opts, epoch, &Session.reserve(&1, epoch, operation, plan))

        {reply, if(reply == :ok, do: set_operation(state, opts, {epoch, operation}), else: state)}

      _ ->
        {{:error, :operation_pending}, state}
    end
  end

  def written(state, opts, epoch, operation, %Ack{ticket: ticket} = ack)
      when is_reference(ticket) do
    {reply, state} =
      change(state, opts, epoch, fn record ->
        with true <- is_reference(ack.ticket) or {:error, :invalid_acknowledgement},
             {:ok, session} <- Session.written(record.helper.session, epoch, operation, ack),
             {:ok, bytes} <-
               StagedIO.measure({operation, ack.ticket}, record.limits.max_manifest_bytes),
             session = %{session | descriptor_bytes: session.descriptor_bytes + bytes},
             {:ok, helper} <- replace_session(record.helper, session) do
          {:reply, :ok,
           %{
             record
             | helper: helper,
               acknowledgements: Map.put(record.acknowledgements, operation, ack.ticket)
           }}
        end
      end)

    state =
      if reply == :ok and
           state.executions[opts.execution_lease][:export_operation] === {epoch, operation},
         do: set_operation(state, opts, nil),
         else: state

    {reply, state}
  end

  def written(state, _opts, _epoch, _operation, _ack),
    do: {{:error, :invalid_acknowledgement}, state}

  def abandon_reserved(state, opts, epoch, operation) do
    key = {opts[:scope], opts.generation}

    with %{export_operation: {^epoch, ^operation}} <- state.executions[opts.execution_lease],
         %{epoch: ^epoch, helper: %{session: %{pending: pending}}} <- state.exports[key],
         true <- Map.has_key?(pending, operation) do
      {:ok, fail(state, key, :export_io_failed)}
    else
      _ -> {{:error, :stale_operation}, state}
    end
  end

  defp set_operation(state, opts, operation) do
    execution = Map.put(state.executions[opts.execution_lease], :export_operation, operation)
    %{state | executions: Map.put(state.executions, opts.execution_lease, execution)}
  end

  def finalizer(state, opts, job, epoch, callback) do
    change(state, opts, epoch, fn record ->
      if job.kind == :finalize and record.helper.finalizer &&
           record.helper.finalizer.id === job.id,
         do: callback.(record),
         else: {:error, :stale_finalizer}
    end)
  end

  def prepare_next(state, opts, job, receipt, epoch, token, cursor, limit)
      when is_integer(limit) and limit > 0 and limit <= 16 do
    funded_finalizer(state, opts, job, receipt, epoch, fn record, _capacity ->
      case Export.prepare_next(record.helper, token, cursor, limit) do
        {:ok, batch, next} ->
          batch = Enum.map(batch, &preparation(record, &1))
          {:payload, {:batch, batch, next}, record}

        :done ->
          {:reply, :done, record}

        error ->
          error
      end
    end)
  end

  def prepare_next(state, _opts, _job, _receipt, _epoch, _token, _cursor, _limit),
    do: {{:error, :invalid_batch_limit}, state}

  defp preparation(record, row) do
    staged = record.helper.session.staged
    descriptor = row.descriptor

    Map.put(row, :plans, %{
      source: staged[descriptor.source_operation],
      lexical: staged[descriptor.lexical_operation],
      bound: staged[row.bound.operation]
    })
  end

  def prepared(state, opts, job, epoch, token, target, operation, edges) do
    finalizer(state, opts, job, epoch, fn record ->
      with ticket when is_reference(ticket) <- record.acknowledgements[operation],
           plan when not is_nil(plan) <- record.helper.session.staged[operation],
           {status, helper} when status in [:ok, :existing] <-
             Export.prepared(
               record.helper,
               token,
               target,
               %{operation: operation, ack: %Ack{plan: plan, ticket: ticket}},
               edges
             ) do
        {:reply, :ok, %{record | helper: helper}}
      else
        nil -> {:error, :unstaged_metadata}
        error -> error
      end
    end)
  end

  def seal(state, opts, job, receipt, epoch, token) do
    funded_finalizer(state, opts, job, receipt, epoch, fn record, capacity ->
      session = record.helper.session
      bound = 4096 + 4 * (session.manifest.metadata_bytes + session.descriptor_bytes)

      available =
        record.limits.max_manifest_bytes - session.manifest.metadata_bytes -
          session.descriptor_bytes

      with true <- bound <= capacity or {:error, {:limit, :max_retained_bytes}},
           true <- bound <= available or {:error, {:limit, :max_manifest_bytes}},
           {:ok, snapshot, helper} <- Export.seal(record.helper, token),
           {:ok, bytes} <- Retained.copy_bytes(snapshot, bound),
           session = %{helper.session | descriptor_bytes: helper.session.descriptor_bytes + bytes},
           {:ok, helper} <- replace_session(helper, session) do
        {:payload, %{snapshot: snapshot, staged: session.staged, manifest_capacity: bound},
         %{record | helper: helper}}
      else
        false -> {:error, {:limit, :max_retained_bytes}}
        error -> error
      end
    end)
  end

  def rendered(state, opts, job, epoch, seal, target, operation) do
    finalizer(state, opts, job, epoch, fn record ->
      with {:ok, session} <-
             Session.rendered(record.helper.session, epoch, seal, target, operation),
           {:ok, helper} <- replace_session(record.helper, session),
           do: {:reply, :ok, %{record | helper: helper}}
    end)
  end

  def commit(state, opts, job, epoch, token, seal, prepared, operation) do
    result =
      finalizer(state, opts, job, epoch, fn record ->
        with true <- record.helper.phase == :sealed or {:error, :unsealed_export},
             true <- is_nil(record.terminal) or {:error, :terminal_pending},
             true <- record.helper.close_proof.close_token === token or {:error, :stale_close},
             true <-
               record.helper.close_proof.owner_css_epoch === record.css_epoch or
                 {:error, :stale_css},
             true <- record.helper.close_proof.seal_token === seal or {:error, :stale_seal},
             true <- Map.get(state.css_unsettled, record.run, 0) == 0 or {:error, :pending_css},
             true <-
               finalizer_io_idle?(state, record.run, opts.execution_lease) or
                 {:error, :pending_io},
             true <-
               Filesystem.prepared_for?(prepared, record.receipt) or
                 {:error, :foreign_preparation},
             :ok <-
               Session.validate_commit(record.helper.session, epoch, seal, job.id, operation),
             {:ok, session} <-
               Session.promoted(record.helper.session, operation, Outcome.new(:succeeded)),
             {:ok, helper} <- replace_session(record.helper, session),
             :ok <- Filesystem.promote(prepared) do
          {:reply, :promoted, %{record | helper: helper}}
        end
      end)

    case result do
      {:promoted, state} ->
        state = start_finish(state, opts)
        observer = state.executions[opts.execution_lease].observer

        send(observer, {
          :crawler_export_published,
          self(),
          job.id,
          epoch,
          token
        })

        {{:ok, :committed}, state}

      error ->
        cancel_preparation(state, opts, prepared)

        error
    end
  end

  defp cancel_preparation(state, opts, prepared) do
    case state.exports[{opts[:scope], opts.generation}] do
      %{receipt: receipt} ->
        if Filesystem.prepared_for?(prepared, receipt), do: Filesystem.cancel(prepared)

      _ ->
        :ok
    end
  end

  defp finalizer_io_idle?(state, run, lease) do
    ring = Map.get(state.export_io_runs, run, Ring.new())

    Ring.size(ring) == 0 or
      (Ring.size(ring) == 1 and Map.has_key?(ring.members, lease) and
         match?(%{status: :idle}, state.export_io[lease]))
  end

  defp start_finish(state, opts) do
    key = {opts[:scope], opts.generation}
    record = %{state.exports[key] | phase: :finishing}
    start_terminal(state, key, record, :finish)
  end

  defp funded_finalizer(state, opts, job, receipt, epoch, callback) do
    worker = state.executions[opts.execution_lease].worker

    with true <- Authority.resource_current?(receipt, opts.execution_lease, worker),
         %{kind: :snapshot, actual: nil, capacity: capacity} <-
           Resources.receipt(state.resources, receipt),
         key = {opts[:scope], opts.generation},
         %{epoch: ^epoch, failure: nil, helper: %{finalizer: %{id: target}}} = record <-
           state.exports[key],
         true <- job.kind == :finalize and job.id === target do
      case callback.(record, capacity) do
        {:payload, payload, record} ->
          with {:ok, bytes} <- Retained.copy_bytes(payload, capacity) do
            case ResourceManager.transition(
                   state,
                   Resources.commit(state.resources, receipt, opts.execution_lease, bytes)
                 ) do
              {:ok, state} -> {{:ok, payload}, put(state, key, record)}
              {error, state} -> {error, state}
            end
          else
            error -> {error, state}
          end

        {:reply, reply, _record} ->
          {reply, state}

        error ->
          {error, state}
      end
    else
      _ -> {{:error, :stale_finalizer}, state}
    end
  end

  def target_reply(state, opts, job, receipt, command) do
    worker = state.executions[opts.execution_lease].worker
    key = {opts[:scope], opts.generation}

    with true <- Authority.resource_current?(receipt, opts.execution_lease, worker),
         %{kind: :snapshot, actual: nil, capacity: capacity} <-
           Resources.receipt(state.resources, receipt),
         {:ok, payload} <- target_payload(state.exports[key], job, command),
         payload =
           if(command == :context and is_map(payload),
             do: Map.put(payload, :context_receipt, receipt),
             else: payload
           ),
         {:ok, retained} <- Retained.bytes(payload, capacity),
         {:ok, copy} <- Retained.copy_bytes(payload, capacity),
         true <- max(retained, copy) + 512 <= capacity or {:error, {:limit, :max_retained_bytes}} do
      case ResourceManager.transition(
             state,
             Resources.commit(
               state.resources,
               receipt,
               opts.execution_lease,
               max(retained, copy) + 512
             )
           ) do
        {:ok, state} -> {{:ok, payload}, state}
        {error, state} -> {error, state}
      end
    else
      false -> {{:error, :stale_resource}, state}
      {:error, _} = error -> {error, state}
      _ -> {{:error, :unfunded_export_reply}, state}
    end
  end

  defp target_payload(nil, _job, :context), do: {:ok, nil}

  defp target_payload(%{failure: reason}, _job, _command) when not is_nil(reason),
    do: {:error, reason}

  defp target_payload(
         %{helper: %{finalizer: %{id: id}}} = record,
         %{kind: :finalize, id: id} = job,
         :context
       ),
       do: context_payload(record, job)

  defp target_payload(_record, %{kind: :finalize}, :context),
    do: {:error, :stale_finalizer}

  defp target_payload(record, job, :context), do: context_payload(record, job)

  defp target_payload(%{epoch: epoch} = record, job, {:source_info, epoch}) do
    response = record.helper.session.manifest.responses[job.representation_id]

    info =
      if response,
        do: %{response: response, plan: record.helper.session.staged[response.source_handle]}

    {:ok, info}
  end

  defp target_payload(_record, _job, _command), do: {:error, :stale_export}

  defp context_payload(record, job) do
    payload =
      Map.put(context(record), :job, %{job | opts: %{}, prepared_request: nil, logical_key: nil})

    if job.kind in [:fetch, :interpret],
      do: {:ok, Map.put(payload, :assignment, assignment(record, job))},
      else: {:ok, payload}
  end

  defp assignment(record, job) do
    case record.target_contexts[job.id] do
      nil ->
        public = opaque_id(record.id, job.id)
        row = record.helper.targets[job.id]

        %{
          target: job.id,
          discovery_mode: Map.get(job.opts, :discovery_mode, :parse),
          public_id: public,
          version: if(row, do: row.version, else: 0),
          candidate: if(row, do: row.descriptor),
          bound: if(row, do: row.bound),
          source_path: "sources/" <> opaque_id(record.id, job.representation_id),
          lexical_path: "metadata/lexical/" <> public,
          bound_prefix: "metadata/bound/" <> public <> "/",
          dispatch_context: nil
        }

      assignment ->
        row = record.helper.targets[job.id]
        %{assignment | version: row.version, candidate: row.descriptor, bound: row.bound}
    end
  end

  defp opaque_id(export, target) do
    :crypto.mac(:hmac, :sha256, export, :erlang.term_to_binary(target))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end

  defp remember_context(record, job, final_url) do
    if Map.has_key?(record.target_contexts, job.id) do
      {:ok, record}
    else
      dispatch =
        job.opts
        |> Map.drop([
          :prepared_request,
          :scheduler_claim,
          :scheduler_mode,
          :scheduler_kind,
          :execution_lease,
          :crawler_deadline,
          :return_reservation,
          :return_workspace,
          :analysis,
          :interpretation,
          :headers,
          :content_type,
          :css_tokens,
          :css_references,
          :document_styles,
          :body_resource,
          :page_resource,
          :before_publish,
          :source_revision,
          :source_entity_bytes
        ])
        |> Map.put(:force, false)
        |> Map.put(:depth, job.opts.depth + 1)
        |> Map.put(:referrer_url, final_url)
        |> Map.put(:alias_url, final_url)
        |> Crawler.Cookies.assign_landed_site(final_url)

      dispatch =
        if dispatch[:worker_base] === job.opts.url,
          do: Map.put(dispatch, :worker_base, final_url),
          else: dispatch

      assigned = %{assignment(record, job) | dispatch_context: dispatch}
      session = record.helper.session

      available =
        record.limits.max_manifest_bytes - session.manifest.metadata_bytes -
          session.descriptor_bytes

      with {:ok, bytes} <- Retained.copy_bytes(assigned, max(available - 4096, 0)),
           true <- bytes + 4096 <= available or {:error, {:limit, :max_manifest_bytes}},
           session = %{session | descriptor_bytes: session.descriptor_bytes + bytes + 4096},
           {:ok, helper} <- replace_session(record.helper, session) do
        {:ok,
         %{
           record
           | helper: helper,
             target_contexts: Map.put(record.target_contexts, job.id, assigned)
         }}
      end
    end
  end

  def source(state, opts, epoch, job, operation, content_type, final_url) do
    {reply, state} = register_source(state, opts, epoch, job, operation, content_type, final_url)

    if reply == :ok,
      do: {:ok, Crawler.Store.ExportSource.registered(state, opts, job.representation_id)},
      else: {reply, state}
  end

  defp register_source(state, opts, epoch, job, operation, content_type, final_url) do
    change(state, opts, epoch, fn record ->
      with %{source_revision: revision} when is_reference(revision) <-
             state.executions[opts.execution_lease],
           %{source_revision: ^revision} = plan <- record.helper.session.staged[operation],
           :ok <-
             validate_source_witness(
               state.executions[opts.execution_lease],
               record,
               job,
               operation,
               plan,
               content_type,
               final_url
             ),
           {:ok, helper} <- admit(record.helper, epoch, job),
           {:ok, session} <-
             register_response(helper.session, epoch, job, operation, content_type, final_url),
           {:ok, helper} <- replace_session(helper, session),
           {:ok, record} <- remember_context(%{record | helper: helper}, job, final_url) do
        {:reply, :ok, record}
      else
        {:error, _} = error -> error
        _ -> {:error, :source_revision_mismatch}
      end
    end)
  end

  defp validate_source_witness(execution, record, job, operation, plan, content_type, final_url) do
    case record.helper.session.manifest.responses[job.representation_id] do
      %{source_handle: ^operation} ->
        Crawler.Store.SourceWitness.validate_existing(execution, plan, content_type, final_url)

      _ ->
        Crawler.Store.SourceWitness.validate_registration(
          execution,
          plan,
          content_type,
          final_url
        )
    end
  end

  defp register_response(session, epoch, job, operation, content_type, final_url) do
    case session.manifest.responses[job.representation_id] do
      nil ->
        Session.response(session, epoch, job.id, operation, content_type, final_url)

      response ->
        with {:ok, online} <- Crawler.Export.Paths.online(final_url),
             true <-
               (response.source_handle === operation and
                  response.source_revision === session.staged[operation].source_revision and
                  response.content_type === Crawler.Export.Paths.content_type(content_type) and
                  response.url === online) or {:error, :source_witness_mismatch},
             do: {:ok, session}
    end
  end

  def candidate(state, opts, epoch, target, version, descriptor, memberships, owner \\ nil) do
    case candidate_once(state, opts, epoch, target, version, descriptor, memberships, owner) do
      {{:error, :stale_group_version}, state} when is_nil(owner) ->
        retry_initial_candidate(state, opts, epoch, target, version, descriptor, memberships)

      result ->
        result
    end
  end

  defp retry_initial_candidate(state, opts, epoch, target, version, descriptor, memberships) do
    execution = state.executions[opts.execution_lease]

    with {:ok, bytes} <- Retained.copy_bytes(memberships, opts.max_manifest_bytes) do
      case ResourceManager.transition(
             state,
             Resources.reserve(
               state.resources,
               execution.arena,
               opts.execution_lease,
               :scratch,
               bytes + 4096,
               self()
             )
           ) do
        {{:ok, receipt}, state} ->
          case adopt_owner(state, receipt, execution.worker) do
            {:ok, ^receipt, state} ->
              {result, state} =
                retry_current_memberships(
                  state,
                  opts,
                  epoch,
                  target,
                  version,
                  descriptor,
                  memberships
                )

              {result, ResourceManager.release_owner(state, receipt)}

            {error, state} ->
              {error, state}
          end

        result ->
          result
      end
    else
      error -> {error, state}
    end
  end

  defp retry_current_memberships(state, opts, epoch, target, version, descriptor, memberships) do
    groups = state.exports[{opts[:scope], opts.generation}].helper.groups

    current =
      Enum.reduce_while(memberships, {:ok, %{}}, fn {id, _}, {:ok, found} ->
        case groups[id] do
          %{version: version} -> {:cont, {:ok, Map.put(found, id, version)}}
          _ -> {:halt, {:error, :unknown_css_group}}
        end
      end)

    with {:ok, current} <- current do
      case candidate_once(state, opts, epoch, target, version, descriptor, current, nil) do
        {{:ok, _}, state} -> {:superseded, state}
        result -> result
      end
    else
      error -> {error, state}
    end
  end

  defp candidate_once(state, opts, epoch, target, version, descriptor, memberships, owner) do
    change(state, opts, epoch, fn record ->
      with %{public_id: public} <- record.target_contexts[target],
           true <-
             (is_map(descriptor) and descriptor[:public_id] === public) or
               {:error, :invalid_public_id} do
        case Export.candidate(record.helper, target, version, descriptor, memberships, owner) do
          {status, next_version, helper} when status in [:ok, :existing] ->
            {:reply, {:ok, next_version}, %{record | helper: helper}}

          error ->
            error
        end
      else
        nil -> {:error, :missing_target_source}
        error -> error
      end
    end)
  end

  def refresh_batch(state, opts, job, receipt, epoch, limit, metadata)
      when is_integer(limit) and limit in 1..16 do
    key = {opts[:scope], opts.generation}
    worker = state.executions[opts.execution_lease].worker

    with true <- job.kind in [:fetch, :interpret, :css_settlement],
         %{epoch: ^epoch, failure: nil} = record <- state.exports[key],
         true <- receipt !== metadata,
         true <- Authority.resource_current?(receipt, opts.execution_lease, worker),
         true <- is_nil(state.executions[opts.execution_lease][:export_refresh]),
         %{kind: :snapshot, actual: nil, capacity: capacity} <-
           Resources.receipt(state.resources, receipt) do
      refresh_reply(state, opts, key, record, receipt, capacity, limit, metadata)
    else
      _ -> {{:error, :stale_export}, state}
    end
  end

  def refresh_batch(state, _opts, _job, _receipt, _epoch, _limit, _metadata),
    do: {{:error, :invalid_batch_limit}, state}

  def group_versions(state, opts, epoch, groups, receipt) do
    worker = state.executions[opts.execution_lease].worker

    with %{epoch: ^epoch, failure: nil, helper: %{phase: :admitting} = helper} <-
           state.exports[{opts[:scope], opts.generation}],
         true <- Authority.resource_current?(receipt, opts.execution_lease, worker),
         %{kind: :snapshot, actual: nil, capacity: capacity} <-
           Resources.receipt(state.resources, receipt),
         {:ok, versions} <- selected_group_versions(helper, groups, capacity - 4096, 16, %{}),
         {:ok, bytes} <- Retained.copy_bytes(versions, capacity) do
      case ResourceManager.transition(
             state,
             Resources.commit(state.resources, receipt, opts.execution_lease, bytes)
           ) do
        {:ok, state} -> {{:ok, versions}, state}
        {error, state} -> {error, state}
      end
    else
      {:error, _} = error -> {error, state}
      _ -> {{:error, :stale_export}, state}
    end
  end

  defp selected_group_versions(_helper, [], _remaining, _count, versions), do: {:ok, versions}

  defp selected_group_versions(helper, [id | ids], remaining, count, versions)
       when remaining >= 0 and count > 0 do
    with %{version: version} <- helper.groups[id],
         {:ok, bytes} <- Retained.copy_bytes({id, version}, remaining),
         true <- bytes + 128 <= remaining or {:error, {:limit, :max_retained_bytes}} do
      selected_group_versions(
        helper,
        ids,
        remaining - bytes - 128,
        count - 1,
        Map.put(versions, id, version)
      )
    else
      nil -> {:error, :unknown_css_group}
      error -> error
    end
  end

  defp selected_group_versions(_helper, _ids, _remaining, _count, _versions),
    do: {:error, {:limit, :max_retained_bytes}}

  defp refresh_reply(state, opts, key, record, receipt, capacity, limit, metadata) do
    case reserve_refresh(state, opts, metadata) do
      {:ok, metadata, state} ->
        {reply, state} =
          select_refresh(state, opts, key, record, receipt, capacity, limit, metadata)

        if state.executions[opts.execution_lease][:export_refresh],
          do: {reply, state},
          else: {reply, ResourceManager.release_owner(state, metadata)}

      {error, state} ->
        {error, state}
    end
  end

  defp reserve_refresh(state, opts, receipt) do
    execution = state.executions[opts.execution_lease]
    lease = opts.execution_lease
    arena = execution.arena
    worker = execution.worker

    with true <- Authority.resource_current?(receipt, lease, worker),
         %{
           kind: :snapshot,
           lease: ^lease,
           arena: ^arena,
           executor: ^worker,
           actual: nil,
           capacity: @refresh_bytes,
           holders: holders
         } <- Resources.receipt(state.resources, receipt),
         %{status: :pending, lease: ^lease, arena: ^arena, origin: ^worker} <- holders[self()] do
      adopt_owner(state, receipt, worker)
    else
      _ -> {{:error, :unfunded_export_reply}, state}
    end
  end

  defp adopt_owner(state, receipt, worker) do
    case ResourceManager.transition(state, Resources.adopt(state.resources, receipt, self())) do
      {:ok, state} ->
        {_, state} =
          ResourceManager.transition(state, Resources.release(state.resources, receipt, worker))

        {:ok, receipt, state}

      {error, state} ->
        state = ResourceManager.release_owner(state, receipt)

        {_, state} =
          ResourceManager.transition(state, Resources.release(state.resources, receipt, worker))

        {error, state}
    end
  end

  defp select_refresh(state, opts, key, record, receipt, capacity, limit, metadata) do
    eligible = fn target ->
      match?(%{status: :succeeded}, Frontier.outcome(state.scheduler.frontier, target))
    end

    owner = {opts.execution_lease, receipt}

    case Export.refresh_batch(record.helper, limit, eligible, owner) do
      {:ok, ids, visited, helper} ->
        with {:ok, rows} <- refresh_rows(record, helper, ids, capacity),
             payload = {:batch, rows, visited},
             {:ok, bytes} <- Retained.copy_bytes(payload, capacity) do
          case ResourceManager.transition(
                 state,
                 Resources.commit(state.resources, receipt, opts.execution_lease, bytes)
               ) do
            {:ok, state} ->
              state = put(state, key, %{record | helper: helper})
              remember_refresh(state, opts, receipt, metadata, owner, ids, helper, payload)

            {error, state} ->
              {error, state}
          end
        else
          error -> {error, state}
        end

      {status, helper} when status in [:waiting, :done] ->
        {status, put(state, key, %{record | helper: helper})}

      error ->
        {error, state}
    end
  end

  defp remember_refresh(state, _opts, _receipt, _metadata, _owner, [], _helper, payload),
    do: {{:ok, payload}, state}

  defp remember_refresh(state, opts, receipt, metadata, owner, ids, helper, payload) do
    selected = Map.new(ids, &{&1, helper.targets[&1].version})
    run = {opts[:scope], opts.generation}

    batch = %{
      owner: owner,
      receipt: receipt,
      metadata: metadata,
      selected: selected,
      epoch: state.exports[run].epoch,
      css_epoch: state.exports[run].css_epoch,
      run: run
    }

    case Retained.bytes(batch, @refresh_bytes) do
      {:ok, _} ->
        execution = Map.put(state.executions[opts.execution_lease], :export_refresh, batch)

        {{:ok, payload},
         %{state | executions: Map.put(state.executions, opts.execution_lease, execution)}}

      {:error, reason} ->
        state =
          case Export.release_refresh(helper, owner, Map.to_list(selected)) do
            {:ok, helper} -> put(state, run, %{state.exports[run] | helper: helper})
            {:error, cleanup_reason} -> fail(state, run, cleanup_reason)
          end

        {{:error, reason}, state}
    end
  end

  def release_refresh(state, opts, epoch, receipt) do
    case state.executions[opts.execution_lease] do
      %{export_refresh: %{epoch: ^epoch, receipt: ^receipt}} ->
        release_refresh(state, opts.execution_lease)

      _ ->
        {{:ok, false}, state}
    end
  end

  defp release_refresh(state, lease) do
    case state.executions[lease] do
      %{export_refresh: batch} = execution when not is_nil(batch) ->
        state = %{
          state
          | executions: Map.put(state.executions, lease, Map.delete(execution, :export_refresh))
        }

        {reply, state} = requeue_refresh(state, batch)
        {reply, ResourceManager.release_owner(state, batch.metadata)}

      _ ->
        {{:ok, false}, state}
    end
  end

  defp requeue_refresh(state, batch) do
    case state.exports[batch.run] do
      %{epoch: epoch, failure: nil, helper: %{phase: :admitting} = helper} = record
      when epoch === batch.epoch ->
        progressed? =
          record.css_epoch != batch.css_epoch or
            Enum.any?(batch.selected, fn {target, version} ->
              row = helper.targets[target]
              not row.dirty? or row.version != version
            end)

        case Export.release_refresh(helper, batch.owner, Map.to_list(batch.selected)) do
          {:ok, helper} -> {{:ok, progressed?}, put(state, batch.run, %{record | helper: helper})}
          {:error, reason} -> {{:error, reason}, fail(state, batch.run, reason)}
        end

      _ ->
        {{:ok, false}, state}
    end
  end

  defp refresh_rows(record, helper, ids, capacity) do
    Enum.reduce_while(ids, {:ok, [], 4096}, fn id, {:ok, rows, used} ->
      row = helper.targets[id]
      descriptor = row.descriptor
      staged = helper.session.staged
      source = staged[descriptor.source_operation]
      lexical = staged[descriptor.lexical_operation]
      bound = if row.bound, do: staged[row.bound.operation]

      assignment = %{
        record.target_contexts[id]
        | version: row.version,
          candidate: row.descriptor,
          bound: row.bound
      }

      raw = {descriptor, row.memberships, source, lexical, bound, row.bound, assignment}

      with {:ok, bytes} <- Retained.copy_bytes(raw, max(div(capacity - used, 2), 0)),
           next = used + 4096 + 2 * bytes,
           true <- next <= capacity or {:error, {:limit, :max_retained_bytes}} do
        groups =
          Map.new(row.memberships, fn {group, _} -> {group, helper.groups[group].version} end)

        payload = %{
          target: id,
          version: row.version,
          descriptor: descriptor,
          source: source,
          lexical: lexical,
          bound: bound,
          bound_descriptor: row.bound,
          assignment: assignment,
          groups: groups
        }

        {:cont, {:ok, [payload | rows], next}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows, _} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  def refresh_candidate(state, opts, job, epoch, target, version, descriptor, memberships) do
    with {:ok, owner} <- refresh_target(state, opts, job, epoch, target, version) do
      {reply, state} =
        candidate(state, opts, epoch, target, version, descriptor, memberships, owner)

      state =
        case reply do
          {:ok, version} -> update_refresh_version(state, opts.execution_lease, target, version)
          _ -> state
        end

      {reply, state}
    else
      error -> {error, state}
    end
  end

  def refresh_discovered(state, opts, job, epoch, target, version, groups, bound) do
    with {:ok, _owner} <- refresh_target(state, opts, job, epoch, target, version) do
      discovered(state, opts, epoch, target, version, groups, bound)
    else
      error -> {error, state}
    end
  end

  defp refresh_target(state, opts, job, epoch, target, version) do
    run = {opts[:scope], opts.generation}

    with true <- job.kind in [:fetch, :interpret, :css_settlement],
         %{epoch: ^epoch, failure: nil, helper: %{phase: :admitting, targets: targets}} <-
           state.exports[run],
         %{epoch: ^epoch, selected: selected, owner: owner} <-
           state.executions[opts.execution_lease][:export_refresh],
         true <- selected[target] === version,
         %{job: canonical} <- state.scheduler.frontier.jobs[target],
         true <- canonical.kind in [:fetch, :interpret],
         true <- Frontier.run_key(canonical) === run do
      case targets[target] do
        %{dirty?: true, version: ^version, refresh_owner: ^owner} -> {:ok, owner}
        _ -> :superseded
      end
    else
      _ -> {:error, :stale_refresh}
    end
  end

  defp update_refresh_version(state, lease, target, version) do
    execution = state.executions[lease]
    batch = execution.export_refresh
    batch = %{batch | selected: Map.put(batch.selected, target, version)}
    %{state | executions: Map.put(state.executions, lease, %{execution | export_refresh: batch})}
  end

  def discovered(state, opts, epoch, target, version, groups, bound) do
    change(state, opts, epoch, fn record ->
      case Export.discovered(record.helper, target, version, groups, bound) do
        {status, helper} when status in [:ok, :existing] ->
          {:reply, :ok, %{record | helper: helper}}

        {:superseded, helper} ->
          {:reply, :superseded, %{record | helper: helper}}

        error ->
          error
      end
    end)
  end

  def settle(state, %{kind: kind} = job, outcome) when kind in [:fetch, :interpret] do
    key = Crawler.Frontier.run_key(job)

    case state.exports[key] do
      nil ->
        {:ok, state}

      record ->
        with {:ok, helper} <- admit(record.helper, record.epoch, job),
             {:ok, helper} <- settle_helper(helper, record.epoch, job.id, outcome) do
          {:ok, progress(put(state, key, %{record | helper: helper}), key)}
        else
          error -> error
        end
    end
  end

  def settle(state, %{kind: :finalize} = job, %Outcome{status: status} = outcome) do
    key = Frontier.run_key(job)

    case state.exports[key] do
      %{helper: %{finalizer: %{id: target}}} = record when target === job.id ->
        if status == :succeeded and record.helper.session.manifest.state == :ready,
          do: {:ok, state},
          else: {:ok, fail(state, key, outcome.reason || :finalizer_failed)}

      _ ->
        {:ok, state}
    end
  end

  def settle(state, job, _outcome), do: {:ok, progress(state, Frontier.run_key(job))}

  def change(state, opts, epoch, callback) do
    key = {opts[:scope], opts.generation}

    case state.exports[key] do
      %{epoch: ^epoch, failure: reason} when not is_nil(reason) ->
        {{:error, reason}, state}

      %{epoch: ^epoch} = record ->
        case callback.(record) do
          {:reply, reply, next} -> {reply, put(state, key, next)}
          {:superseded, _helper} -> {:superseded, state}
          {:error, _reason} = error -> {error, state}
        end

      _ ->
        {{:error, :stale_export}, state}
    end
  end

  defp create(state, opts, key) do
    with {:ok, root, destination} <- path(opts.save_to),
         limits = Crawler.Limits.export(opts),
         bytes = limits.max_manifest_bytes + @owner_bytes,
         :ok <-
           Resources.admission(
             state.resources,
             key,
             bytes,
             0,
             ResourceManager.options(state, opts)
           ),
         id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower),
         epoch = make_ref(),
         {:ok, session} <- Session.new(id, key, epoch, limits),
         {:ok, helper} <- Export.new(session),
         {:ok, automatic} <- automatic_options(opts) do
      record = %{
        id: id,
        epoch: epoch,
        run: key,
        root: root,
        destination: destination,
        limits: limits,
        helper: helper,
        filesystem: nil,
        receipt: nil,
        nonce: nil,
        phase: :unopened,
        retired?: false,
        failure: nil,
        cleanup_failure: nil,
        waiters: %{},
        css_epoch: 0,
        acknowledgements: %{},
        target_contexts: %{},
        source_owners: %{},
        source_waiters: Ring.new(),
        source_ready: Ring.new(),
        source_scheduled?: false,
        automatic: automatic,
        driver: nil,
        terminal: nil,
        reserved_bytes: bytes
      }

      state = %{
        state
        | exports: Map.put(state.exports, key, record),
          export_bytes: state.export_bytes + bytes
      }

      {{:ok, context(record)}, state}
    else
      {:limited, reason} -> {{:error, {:limit, reason}}, state}
      {:blocked, _} -> {{:error, {:limit, :max_retained_bytes}}, state}
      {:error, _} = error -> {error, state}
    end
  end

  defp prepare_automatic(%{automatic: nil} = record, opts) do
    with {:ok, automatic} <- automatic_options(opts),
         do: {:ok, %{record | automatic: automatic}}
  end

  defp prepare_automatic(record, _opts), do: {:ok, record}

  defp automatic_options(%{queue: queue} = opts) when is_pid(queue),
    do: finalizer_projection(opts)

  defp automatic_options(_opts), do: {:ok, nil}

  defp finalizer_projection(opts) do
    options =
      Map.take(
        opts,
        Map.keys(Crawler.Limits.defaults()) ++ [:scope, :generation, :run_deadline, :save_to]
      )

    with {:ok, retained} <- Retained.bytes(options, @driver_bytes),
         {:ok, copy} <- Retained.copy_bytes(options, @driver_bytes),
         true <-
           retained + copy <= @driver_bytes or {:error, {:limit, :max_retained_bytes}},
         do: {:ok, options}
  end

  def arm(state, opts, job, epoch) do
    key = {opts[:scope], opts.generation}

    with true <- job.kind in [:fetch, :interpret],
         %{epoch: ^epoch, failure: nil, helper: %{phase: :admitting} = helper} = record <-
           state.exports[key],
         %{dirty?: false, bound: bound} when not is_nil(bound) <- helper.targets[job.id],
         :ok <- destination(record, opts.save_to),
         {:ok, options} <- finalizer_projection(opts) do
      record = %{record | automatic: record.automatic || options}
      {:ok, progress(put(state, key, record), key)}
    else
      {:error, _} = error -> {error, state}
      _ -> {{:error, :unstaged_export}, state}
    end
  end

  def automatic_pending?(state, scope) do
    case state.scopes[scope] do
      nil ->
        false

      _ ->
        automatic_run_pending?(
          state.exports[{scope, Crawler.Store.State.generation(state, scope)}]
        )
    end
  end

  defp automatic_run_pending?(%{phase: :finishing}), do: true

  defp automatic_run_pending?(%{automatic: options, failure: nil, retired?: false} = record)
       when not is_nil(options),
       do: record.helper.session.manifest.state not in [:ready, :failed, :cancelled]

  defp automatic_run_pending?(_record), do: false

  def progress(state, key) do
    case state.exports[key] do
      %{
        automatic: automatic,
        driver: nil,
        failure: nil,
        retired?: false,
        helper: %{phase: :admitting}
      }
      when not is_nil(automatic) ->
        pending = Ring.put(state.export_pending, key)
        if not state.export_scheduled?, do: send(self(), :export_pending)
        %{state | export_pending: pending, export_scheduled?: true}

      _ ->
        state
    end
  end

  def schedule_pending(state) do
    if Ring.size(state.export_pending) > 0 and not state.export_scheduled? do
      send(self(), :export_pending)
      %{state | export_scheduled?: true}
    else
      state
    end
  end

  def run_driver(owner, nonce, options, closed) do
    owner_monitor = Process.monitor(owner)

    receive do
      {:activate_export_driver, ^nonce, monitor} when is_reference(monitor) ->
        result = apply(Crawler.Export.Runner, :finalize, [options, closed])

        result =
          case result do
            {:ok, :committed} -> :committed
            {:error, reason} -> failure_reason(reason)
            _ -> {:snapshot, :finalizer_failed}
          end

        send(owner, {:crawler_export_finalized, monitor, nonce, self(), result})

      {:DOWN, ^owner_monitor, :process, ^owner, _} ->
        :ok
    after
      Crawler.Deadline.remaining(options.run_deadline) -> :ok
    end
  end

  def driver_result(state, monitor, nonce, pid, result) do
    case state.export_drivers[monitor] do
      {key, ^pid} ->
        case state.exports[key] do
          %{driver: %{nonce: ^nonce, pid: ^pid} = driver} = record ->
            put(state, key, %{record | driver: %{driver | result: result}})

          _ ->
            state
        end

      _ ->
        state
    end
  end

  def next_driver(state) do
    case Ring.take(state.export_pending) do
      :empty ->
        {:empty, %{state | export_scheduled?: false}}

      {:ok, key, pending} ->
        state = %{state | export_pending: pending}
        reserve_driver(state, key)
    end
  end

  defp reserve_driver(state, key) do
    case state.exports[key] do
      %{
        automatic: options,
        driver: nil,
        failure: nil,
        retired?: false,
        helper: %{phase: :admitting}
      }
      when not is_nil(options) ->
        case close(state, options) do
          {{:ok, closed}, state} ->
            nonce = make_ref()

            record = %{
              state.exports[key]
              | driver: %{nonce: nonce, pid: nil, monitor: nil, result: nil}
            }

            {{:launch, key, nonce, options, closed}, put(state, key, record)}

          {:busy, state} ->
            {:skip, state}

          {{:error, reason}, state} ->
            {:skip, fail(state, key, reason)}
        end

      _ ->
        {:skip, state}
    end
  end

  def driver_started(state, key, nonce, pid, monitor)
      when is_pid(pid) and is_reference(monitor) do
    case state.exports[key] do
      %{driver: %{nonce: ^nonce, pid: nil} = driver} = record ->
        record = %{record | driver: %{driver | pid: pid, monitor: monitor}}

        state = %{
          put(state, key, record)
          | export_drivers: Map.put(state.export_drivers, monitor, {key, pid})
        }

        send(pid, {:activate_export_driver, nonce, monitor})
        state

      _ ->
        Process.exit(pid, :kill)
        state
    end
  end

  def driver_failed(state, key, nonce) do
    case state.exports[key] do
      %{driver: %{nonce: ^nonce, pid: nil}} = record ->
        state = put(state, key, %{record | driver: nil})
        fail_finalizer(state, key, :finalizer_start_failed)

      _ ->
        state
    end
  end

  def driver_down(state, monitor, pid, _reason) do
    case state.export_drivers[monitor] do
      {key, ^pid} ->
        state = %{state | export_drivers: Map.delete(state.export_drivers, monitor)}
        record = state.exports[key]
        state = put(state, key, %{record | driver: nil})

        state =
          if record.helper.session.manifest.state == :ready,
            do: state,
            else: fail_finalizer(state, key, driver_failure(record))

        if disposable_publication?(state, record) and is_nil(record.filesystem),
          do: drop(state, key),
          else: state

      _ ->
        state
    end
  end

  defp driver_failure(%{retired?: true}), do: :stale

  defp driver_failure(%{driver: %{result: result}})
       when not is_nil(result) and result != :committed,
       do: result

  defp driver_failure(_record), do: :finalizer_failed

  defp fail_finalizer(state, key, reason) do
    state = fail(state, key, reason)
    target = state.exports[key].helper.finalizer.id
    outcome = Outcome.from_result({:error, state.exports[key].failure})
    {_status, frontier} = Frontier.settle_job(state.scheduler.frontier, target, outcome)
    scheduler = %{state.scheduler | frontier: frontier}
    scheduler = Crawler.Store.Scheduler.observe_terminal(scheduler, target, :local)
    %{state | scheduler: scheduler}
  end

  defp path(value) when is_binary(value) and byte_size(value) in 1..4096 do
    if String.valid?(value) and not String.contains?(value, <<0>>) do
      value = Path.expand(value)
      {:ok, Path.dirname(value), Path.basename(value)}
    else
      {:error, :invalid_export_path}
    end
  end

  defp path(_value), do: {:error, :invalid_export_path}

  defp destination(_record, nil), do: :ok

  defp destination(record, value) do
    case path(value) do
      {:ok, root, destination} when root == record.root and destination == record.destination ->
        :ok

      _ ->
        {:error, :export_destination_changed}
    end
  end

  defp session_change(state, opts, epoch, callback) do
    change(state, opts, epoch, fn record ->
      with {:ok, session} <- callback.(record.helper.session),
           {:ok, helper} <- replace_session(record.helper, session),
           do: {:reply, :ok, %{record | helper: helper}}
    end)
  end

  defp admit(helper, epoch, job) do
    case Export.admit(helper, epoch, job) do
      {status, helper} when status in [:ok, :existing] -> {:ok, helper}
      error -> error
    end
  end

  defp settle_helper(helper, epoch, target, outcome) do
    case Export.settle(helper, epoch, target, outcome) do
      {status, helper} when status in [:ok, :existing] -> {:ok, helper}
      error -> error
    end
  end

  defp replace_session(helper, session) do
    case Export.put_session(helper, session) do
      {status, helper} when status in [:ok, :existing] -> {:ok, helper}
      error -> error
    end
  end

  defp put(state, key, record), do: %{state | exports: Map.put(state.exports, key, record)}
end
