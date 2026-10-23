defmodule Crawler.Store.ExportIO do
  @moduledoc false

  alias Crawler.Deadline
  alias Crawler.Export.StagedIO
  alias Crawler.Export.StagedIO.Ack
  alias Crawler.Export.StagedIO.Funding
  alias Crawler.Export.StagedIO.Plan
  alias Crawler.Frontier.Ring
  alias Crawler.Store.Authority
  alias Crawler.Store.ExportRun
  alias Crawler.Store.ResourceManager
  alias Crawler.Store.Resources

  @metadata_bytes 32_768
  @maximum_grants 10
  @drain_batch 32

  def start(state, opts, epoch, nonce, metadata) when is_reference(nonce) do
    with {:ok, execution, export} <- current(state, opts, epoch),
         :ok <- metadata(state, opts, execution, metadata),
         :ok <- actor_deadline(execution.deadline) do
      case state.export_io[opts.execution_lease] do
        nil ->
          start_actor(state, opts, epoch, nonce, metadata, execution, export)

        %{startup_nonce: ^nonce, down?: false, status: status, io: io}
        when status != :poisoned ->
          {{:ok, io}, unused_pregrant(state, metadata, opts, :source)}

        _ ->
          {{:error, :already_running}, unused_pregrant(state, metadata, opts, :source)}
      end
    else
      {:error, _} = error -> {error, unused_pregrant(state, metadata, opts, :source)}
    end
  end

  def start(state, opts, _epoch, _nonce, metadata),
    do: {{:error, :invalid_start}, unused_pregrant(state, metadata, opts, :source)}

  def ready(state, lease, nonce, io) do
    case state.export_io[lease] do
      %{io: ^io, startup_nonce: ^nonce, down?: false, status: status} = row
      when status in [:starting, :idle] ->
        if row_current?(state, lease, row),
          do: {:ok, put_row(state, lease, %{row | status: :idle})},
          else: {{:error, :stale_export}, poison(state, lease, :stale_execution)}

      _ ->
        {{:error, :stale_start}, state}
    end
  end

  def activate(state, lease, nonce, io) do
    case state.export_io[lease] do
      %{io: ^io, startup_nonce: ^nonce, status: :starting} = row ->
        if row_current?(state, lease, row) do
          send(io, {:crawler_export_io_activate, nonce, self()})
          state
        else
          poison(state, lease, :stale_execution)
        end

      _ ->
        state
    end
  end

  def render_funding(state, opts, job, epoch, %Funding{} = supplied, action) do
    with {:ok, execution, export} <- current(state, opts, epoch),
         %{phase: :sealed, finalizer: %{id: target}} <- export.helper,
         true <- job.kind == :finalize and job.id === target,
         {:ok, fresh} <-
           funding(state, opts, execution, StagedIO.credit_spec(supplied), execution.worker),
         true <- fresh === supplied,
         %{actual: nil, kind: :snapshot, holders: holders} <-
           Resources.receipt(state.resources, fresh.overlap),
         true <- map_size(holders) == 1 and Map.has_key?(holders, execution.worker),
         true <- not holding?(state, fresh.overlap) do
      render_transition(state, opts, fresh, action)
    else
      {:error, _} = error -> {error, state}
      _ -> {{:error, :invalid_render_funding}, state}
    end
  end

  def render_funding(state, _opts, _job, _epoch, _funding, _action),
    do: {{:error, :invalid_render_funding}, state}

  defp render_transition(state, _opts, funding, :check), do: {{:ok, funding}, state}

  defp render_transition(state, opts, funding, {:commit, bytes})
       when is_integer(bytes) and bytes >= 0 do
    case transition(
           state,
           Resources.commit(state.resources, funding.overlap, funding.lease, bytes)
         ) do
      {:ok, state} ->
        result =
          StagedIO.funding(
            state.resources,
            StagedIO.credit_spec(funding),
            opts.execution_lease,
            funding.holder
          )

        {result, state}

      {error, state} ->
        {error, state}
    end
  end

  defp render_transition(state, _opts, _funding, _action),
    do: {{:error, :invalid_render_funding}, state}

  defp actor_deadline(%Deadline{at: at, kind: kind})
       when is_integer(at) and at >= -9_223_372_036_854_775_808 and
              at <= 9_223_372_036_854_775_807 and kind in [:attempt, :run],
       do: :ok

  defp actor_deadline(_), do: {:error, :invalid_deadline}

  defp start_actor(state, opts, epoch, nonce, metadata, execution, export) do
    case transition(state, Resources.adopt(state.resources, metadata, self())) do
      {:ok, state} ->
        lease = opts.execution_lease

        {io, monitor} =
          spawn_monitor(Crawler.Export.Runtime, :companion_start, [
            execution.worker,
            self(),
            export.filesystem,
            execution.deadline,
            nonce,
            lease
          ])

        row =
          new_row(export.run, epoch, io, monitor, execution.worker, export.filesystem, metadata)

        row = %{row | status: :starting, startup_nonce: nonce}
        state = index_row(state, lease, row) |> hold(lease, metadata, true)
        send(self(), {:activate_export_io, lease, nonce, io})
        {{:ok, io}, state}

      {error, state} ->
        {error, unused_pregrant(state, metadata, opts, :source)}
    end
  end

  def custody(state, opts, epoch, operation, io, credit, metadata_receipt) do
    with {:ok, execution, export} <- current(state, opts, epoch),
         true <- is_reference(operation) or {:error, :invalid_operation},
         %Plan{} <- export.helper.session.pending[operation],
         :ok <- companion(state, opts.execution_lease, execution, export, io),
         {:ok, funding} <- funding(state, opts, execution, credit, execution.worker),
         true <-
           not Map.has_key?(funding.grants, metadata_receipt) or {:error, :unfunded_metadata},
         :ok <- available(state.export_io[opts.execution_lease], epoch, operation, io),
         :ok <- metadata(state, opts, execution, metadata_receipt) do
      begin_custody(state, opts, epoch, operation, io, funding, metadata_receipt, export)
    else
      {:error, reason} ->
        {{:error, reason}, unused_pregrant(state, metadata_receipt, opts, :source)}

      _ ->
        {{:error, :invalid_operation}, unused_pregrant(state, metadata_receipt, opts, :source)}
    end
  end

  def deliver(state, opts, epoch, io, credit, payload_receipt, payload) do
    lease = opts[:execution_lease]

    with {:ok, execution, export} <- current(state, opts, epoch),
         %{status: :custody, epoch: ^epoch, io: ^io} = row <- state.export_io[lease],
         true <- row.credit == credit or {:error, :changed_delivery_credit},
         {:ok, fresh} <- funding(state, opts, execution, credit, execution.worker),
         true <- fresh == row.funding or {:error, :changed_delivery_credit},
         :ok <- payload(state, row, execution, export, payload_receipt, payload) do
      deliver_funded(state, lease, payload_receipt, payload, execution)
    else
      {:error, reason} ->
        reject_delivery(state, opts, epoch, io, payload_receipt, reason)

      _ ->
        reject_delivery(state, opts, epoch, io, payload_receipt, :invalid_delivery)
    end
  end

  def settled(state, opts, epoch, operation, result, from) do
    lease = opts[:execution_lease]

    with {:ok, execution, export} <- current(state, opts, epoch),
         %{status: :delivered, epoch: ^epoch, operation: ^operation} = row <-
           state.export_io[lease],
         true <- is_nil(row.settled_from) or {:error, :settlement_pending},
         true <- elem(from, 0) == execution.worker or {:error, :wrong_executor},
         {:ok, %Ack{plan: plan, ticket: ticket}} <- result,
         true <- is_reference(ticket) or {:error, :invalid_acknowledgement},
         true <- export.helper.session.staged[operation] === plan or {:error, :stale_write},
         true <- row.plan === plan or {:error, :invalid_acknowledgement} do
      row = %{row | ack?: true}
      state = put_row(state, lease, row)

      if released?(row) do
        {:reply, :ok, finish_operation(state, lease)}
      else
        {:noreply, put_row(state, lease, %{row | settled_from: from})}
      end
    else
      {:error, reason} ->
        {:reply, {:error, redact(reason)},
         poison_matching(state, lease, epoch, operation, reason)}

      _ ->
        reason = :invalid_acknowledgement
        {:reply, {:error, reason}, poison_matching(state, lease, epoch, operation, reason)}
    end
  end

  def abandon(state, opts, epoch, operation, reason) do
    lease = opts[:execution_lease]

    case state.export_io[lease] do
      %{epoch: ^epoch, operation: ^operation} ->
        {:ok, poison(state, lease, reason)}

      %{epoch: ^epoch, status: :poisoned} ->
        {:ok, state}

      _ ->
        {reply, state} = ExportRun.abandon_reserved(state, opts, epoch, operation)
        state = if reply == :ok, do: poison(state, lease, :export_io_failed), else: state
        {reply, state}
    end
  end

  def resource_event(state, :adopted, receipt, holder) do
    case event_row(state, receipt, holder) do
      {lease, row} ->
        adopt_delivery_receipt(state, lease, row, receipt, holder)

      nil ->
        state
    end
  end

  def resource_event(state, :released, receipt, holder) do
    case event_row(state, receipt, holder) do
      {lease, row} ->
        cond do
          MapSet.member?(row.released, receipt) ->
            state

          grant(state, receipt, holder) != nil ->
            state

          not MapSet.member?(row.adopted, receipt) ->
            poison(state, lease, :release_before_adoption)

          true ->
            row = %{row | released: MapSet.put(row.released, receipt)}
            state = put_row(state, lease, row)

            finish_released_delivery(state, lease, row)
        end

      nil ->
        state
    end
  end

  def resource_event(state, _kind, _receipt, _holder), do: state

  defp adopt_delivery_receipt(state, lease, row, receipt, holder) do
    case Resources.receipt(state.resources, receipt) do
      %{holders: holders} ->
        case holders[holder] do
          %{status: status, lease: ^lease, arena: arena}
          when status in [:adopted, :retained] and arena == row.funding.arena ->
            put_row(state, lease, %{row | adopted: MapSet.put(row.adopted, receipt)})

          _ ->
            state
        end

      _ ->
        state
    end
  end

  defp finish_released_delivery(state, lease, row) do
    if row.status == :delivered and row.ack? and released?(row) do
      settle_released_delivery(state, lease, row)
    else
      cleanup_lease(state, lease)
    end
  end

  defp settle_released_delivery(state, lease, row) do
    if row_current?(state, lease, row) do
      if row.settled_from, do: GenServer.reply(row.settled_from, :ok)
      finish_operation(state, lease)
    else
      poison(state, lease, :stale_execution)
    end
  end

  def execution_ended(state, lease) do
    case state.export_io[lease] do
      nil ->
        state

      row ->
        state = put_row(state, lease, %{row | ended?: true})
        state = if row.status == :idle, do: state, else: poison(state, lease, :execution_ended)
        cleanup_lease(state, lease)
    end
  end

  def down(state, monitor, pid, reason) do
    case state.export_io_monitors[monitor] do
      nil ->
        execution_or_resource_down(state, monitor, pid, reason)

      lease ->
        monitored_companion_down(state, lease, monitor, pid, reason)
    end
  end

  defp execution_or_resource_down(state, monitor, pid, reason) do
    cond do
      lease = state.execution_monitors[monitor] ->
        execution_down(state, lease, reason)

      state.resource_refs[monitor] == pid ->
        resource_holder_down(state, pid, reason)

      true ->
        state
    end
  end

  defp resource_holder_down(state, pid, reason) do
    cond do
      lease = state.export_io_holders[pid] ->
        row = state.export_io[lease]

        state =
          if row.status == :idle and reason == :normal,
            do: state,
            else: poison(state, lease, :companion_down)

        state = ResourceManager.holder_down(state, pid)
        cleanup_lease(state, lease)

      lease = state.execution_workers[pid] ->
        execution_down(state, lease, reason)

      true ->
        state
    end
  end

  defp monitored_companion_down(state, lease, monitor, pid, reason) do
    case state.export_io[lease] do
      %{io: ^pid, monitor: ^monitor} = row ->
        row = %{row | down?: true}
        state = put_row(state, lease, row)

        state =
          if row.status == :idle and reason == :normal,
            do: state,
            else: poison(state, lease, :companion_down)

        state = ResourceManager.holder_down(state, pid)
        cleanup_lease(state, lease)

      _ ->
        state
    end
  end

  defp execution_down(state, lease, reason) do
    state =
      if reason == :normal or state.export_io[lease] == nil,
        do: state,
        else: poison(state, lease, :producer_down)

    execution_ended(state, lease)
  end

  def filesystem_down(state, run, pid) do
    if state.export_actors[pid] == run and not Process.alive?(pid),
      do: schedule_drain(state, run),
      else: state
  end

  def holding?(state, receipt), do: Map.get(state.export_io_resources, receipt, 0) > 0

  def defer_owner_release(state, receipt) do
    with %{lease: lease} <- grant(state, receipt, self()),
         %{held: held, deferred_owner_releases: deferred} = row <- state.export_io[lease],
         true <- MapSet.member?(held, receipt),
         true <- MapSet.member?(deferred, receipt) or MapSet.size(deferred) < @maximum_grants + 1 do
      put_row(state, lease, %{row | deferred_owner_releases: MapSet.put(deferred, receipt)})
    else
      _ -> state
    end
  end

  def drain(state, run, batch) when is_integer(batch) and batch > 0 do
    case first_row(state, run) do
      nil ->
        state

      {lease, row} ->
        remaining =
          if row.drain_remaining > 0,
            do: row.drain_remaining,
            else: Ring.size(state.export_io_runs[run])

        state = put_row(state, lease, %{row | drain_remaining: 0})
        count = min(min(batch, @drain_batch), remaining)
        state = sweep_batch(state, run, count)
        continue_drain(state, run, remaining - count)
    end
  end

  def drain(state, _run, _batch), do: state

  defp current(state, opts, epoch) do
    lease = opts[:execution_lease]
    run = {opts[:scope], opts[:generation]}

    with %{worker: worker, arena: arena, opts: owned, deadline: deadline} = execution <-
           state.executions[lease],
         true <-
           {owned[:scope], owned[:generation], owned[:queue]} ===
             {opts[:scope], opts[:generation], opts[:queue]},
         true <- Authority.execution_current?(lease, worker),
         true <- Authority.current?(opts[:scope], opts[:generation], opts[:queue], lease),
         :ok <- Deadline.check(deadline),
         %{open?: true, lease: ^lease, run: ^run} <- state.resources.arenas[arena],
         %{
           epoch: ^epoch,
           run: ^run,
           retired?: false,
           failure: nil,
           phase: :ready,
           filesystem: filesystem
         } =
           export <-
           state.exports[run],
         true <- is_pid(filesystem) and Process.alive?(filesystem) do
      {:ok, execution, export}
    else
      {:error, _} = error -> error
      _ -> {:error, :stale_export}
    end
  end

  defp companion(state, lease, execution, export, io) do
    if is_pid(io) and node(io) == node() and Process.alive?(io) and
         io not in [self(), execution.worker, export.filesystem] and
         Map.get(state.export_io_holders, io, lease) == lease,
       do: :ok,
       else: {:error, :invalid_companion}
  end

  defp available(nil, _epoch, _operation, _io), do: :ok
  defp available(%{status: :idle, epoch: epoch, io: io}, epoch, _operation, io), do: :ok
  defp available(%{status: :poisoned}, _epoch, _operation, _io), do: {:error, :abandoned_io}
  defp available(_row, _epoch, _operation, _io), do: {:error, :operation_pending}

  defp funding(state, opts, execution, credit, holder) do
    with {:ok, %Funding{} = funding} <-
           StagedIO.funding(state.resources, credit, opts.execution_lease, holder),
         true <- funding.arena == execution.arena,
         true <- funding.run === {opts[:scope], opts.generation},
         true <- map_size(funding.grants) < @maximum_grants do
      {:ok, funding}
    else
      _ -> {:error, :unfunded}
    end
  end

  defp metadata(state, opts, execution, receipt) do
    with %{
           kind: :source,
           lease: lease,
           arena: arena,
           actual: @metadata_bytes,
           capacity: @metadata_bytes,
           executor: worker,
           holders: holders
         } <-
           Resources.receipt(state.resources, receipt),
         true <-
           lease == opts.execution_lease and arena == execution.arena and
             worker == execution.worker,
         %{status: :pending, lease: ^lease, arena: ^arena, origin: ^worker} <- holders[self()],
         true <- not holding?(state, receipt),
         true <- Authority.resource_current?(receipt, lease, self()) do
      :ok
    else
      _ -> {:error, :unfunded_metadata}
    end
  end

  defp begin_custody(state, opts, epoch, operation, io, funding, metadata, export) do
    lease = opts.execution_lease

    case state.export_io[lease] do
      nil ->
        case transition(state, Resources.adopt(state.resources, metadata, self())) do
          {:ok, state} ->
            monitor = Process.monitor(io)

            row =
              new_row(
                funding.run,
                epoch,
                io,
                monitor,
                funding.holder,
                export.filesystem,
                metadata
              )

            row = %{
              row
              | operation: operation,
                credit: StagedIO.credit_spec(funding),
                funding: funding,
                plan: export.helper.session.pending[operation],
                status: :custody
            }

            state = index_row(state, lease, row)
            state = hold(state, lease, metadata, true)
            retain_custody(state, lease)

          {error, state} ->
            {error, unused_pregrant(state, metadata, opts, :source)}
        end

      row ->
        state = unused_pregrant(state, metadata, opts, :source)

        row = %{
          row
          | operation: operation,
            funding: funding,
            credit: StagedIO.credit_spec(funding),
            plan: export.helper.session.pending[operation],
            status: :custody
        }

        retain_custody(put_row(state, lease, row), lease)
    end
  end

  defp new_row(run, epoch, io, monitor, worker, filesystem, metadata) do
    %{
      run: run,
      epoch: epoch,
      operation: nil,
      io: io,
      monitor: monitor,
      worker: worker,
      filesystem: filesystem,
      credit: nil,
      funding: nil,
      metadata_receipt: metadata,
      payload_receipt: nil,
      delivery_ref: nil,
      plan: nil,
      released: MapSet.new(),
      adopted: MapSet.new(),
      expected: MapSet.new(),
      store_created: MapSet.new(),
      deferred_owner_releases: MapSet.new(),
      io_created: MapSet.new(),
      held: MapSet.new(),
      settled_from: nil,
      ack?: false,
      status: :idle,
      ended?: false,
      down?: false,
      reason: nil,
      drain_remaining: 0,
      startup_nonce: nil
    }
  end

  defp retain_custody(state, lease) do
    row = state.export_io[lease]

    result =
      Enum.reduce_while(Map.keys(row.funding.grants), {:ok, state}, fn receipt, {:ok, state} ->
        case store_grant(state, receipt, row) do
          {:ok, state, created?} -> {:cont, {:ok, hold(state, lease, receipt, created?)}}
          {error, state} -> {:halt, {error, state}}
        end
      end)

    case result do
      {:ok, state} -> {:ok, state}
      {{:error, reason}, state} -> {{:error, reason}, poison(state, lease, reason)}
    end
  end

  defp store_grant(state, receipt, row) do
    case grant(state, receipt, self()) do
      nil ->
        with {:ok, state} <-
               transition(
                 state,
                 Resources.retain_from(
                   state.resources,
                   receipt,
                   row.funding.arena,
                   row.funding.lease,
                   row.worker,
                   self()
                 )
               ),
             {:ok, state} <- transition(state, Resources.adopt(state.resources, receipt, self())) do
          {:ok, state, true}
        else
          {error, state} -> {error, state}
        end

      %{status: :pending, lease: lease, arena: arena, origin: origin}
      when lease === row.funding.lease and arena === row.funding.arena and origin === row.worker ->
        case transition(state, Resources.adopt(state.resources, receipt, self())) do
          {:ok, state} -> {:ok, state, true}
          {error, state} -> {error, state}
        end

      %{status: status, lease: lease, arena: arena}
      when status in [:owned, :adopted, :retained] ->
        if lease == row.funding.lease and arena == row.funding.arena and
             Authority.resource_current?(receipt, lease, self()),
           do: {:ok, state, false},
           else: {{:error, :invalid_store_grant}, state}

      _ ->
        {{:error, :invalid_store_grant}, state}
    end
  end

  defp payload(state, row, execution, export, receipt, {:write, %Plan{} = plan, bytes})
       when is_binary(bytes) do
    lease = row.funding.lease
    arena = execution.arena
    run = row.run
    worker = execution.worker

    with true <- not Map.has_key?(row.funding.grants, receipt),
         true <- receipt != row.metadata_receipt and not holding?(state, receipt),
         true <- row.plan === plan and export.helper.session.pending[row.operation] === plan,
         true <- byte_size(bytes) == plan.bytes,
         %{
           kind: :response,
           lease: ^lease,
           arena: ^arena,
           run: ^run,
           executor: ^worker,
           actual: actual,
           copy_bytes: copy,
           holders: holders
         } <- Resources.receipt(state.resources, receipt),
         true <-
           is_integer(actual) and actual >= 0 and is_integer(copy) and copy >= 0 and
             copy <= actual,
         %{status: :pending, lease: ^lease, arena: ^arena, origin: ^worker} <- holders[self()],
         true <- Authority.resource_current?(receipt, lease, self()),
         true <- Authority.resource_current?(receipt, lease, worker) do
      :ok
    else
      _ -> {:error, :unfunded_payload}
    end
  end

  defp payload(_state, _row, _execution, _export, _receipt, _payload),
    do: {:error, :invalid_io_payload}

  defp deliver_funded(state, lease, payload_receipt, payload, execution) do
    case transition(state, Resources.adopt(state.resources, payload_receipt, self())) do
      {:ok, state} ->
        state = hold(state, lease, payload_receipt, true)
        row = %{state.export_io[lease] | payload_receipt: payload_receipt}
        state = put_row(state, lease, row)
        receipts = Map.keys(row.funding.grants) ++ [payload_receipt]

        result =
          Enum.reduce_while(receipts, {:ok, state}, fn receipt, {:ok, state} ->
            retain_companion_grant(state, lease, receipt, row.io, execution.arena)
          end)

        complete_delivery(result, lease, payload_receipt, payload, receipts)

      {{:error, reason}, state} ->
        opts = %{execution_lease: lease}

        {{:error, reason},
         poison(unused_pregrant(state, payload_receipt, opts, :response), lease, reason)}
    end
  end

  defp retain_companion_grant(state, lease, receipt, io, arena) do
    if grant(state, receipt, io) == nil do
      case transition(
             state,
             Resources.retain_from(state.resources, receipt, arena, lease, self(), io)
           ) do
        {:ok, state} ->
          current = state.export_io[lease]

          state =
            put_row(state, lease, %{
              current
              | io_created: MapSet.put(current.io_created, receipt)
            })

          {:cont, {:ok, state}}

        {error, state} ->
          {:halt, {error, state}}
      end
    else
      {:halt, {{:error, :existing_companion_grant}, state}}
    end
  end

  defp complete_delivery({:ok, state}, lease, receipt, payload, receipts) do
    row = state.export_io[lease]

    with {:ok, %Funding{} = funding} <-
           StagedIO.funding(state.resources, row.credit, lease, row.io),
         true <- same_roles?(row.funding, funding),
         %{actual: capacity, run: run, holders: holders} <-
           Resources.receipt(state.resources, receipt),
         %{status: :pending, lease: ^lease, arena: arena} <- holders[row.io],
         true <- arena == funding.arena and run == funding.run,
         true <- Authority.resource_current?(receipt, lease, row.io),
         true <- Authority.execution_current?(lease, row.worker) do
      grant = %{capacity: capacity, run: run, arena: arena}
      funding = %{funding | grants: Map.put(funding.grants, receipt, grant)}
      reference = make_ref()
      expected = MapSet.new(Enum.map(receipts, &{&1, row.io}))
      row = %{row | expected: expected, delivery_ref: reference, status: :delivered}
      state = put_row(state, lease, row)
      send(row.io, {:crawler_resource_delivery, receipt, lease, row.worker, reference, payload})
      {{:ok, reference, funding}, state}
    else
      _ -> {{:error, :invalid_delivery_funding}, poison(state, lease, :invalid_delivery_funding)}
    end
  end

  defp complete_delivery({{:error, reason}, state}, lease, _receipt, _payload, _receipts),
    do: {{:error, reason}, poison(state, lease, reason)}

  defp same_roles?(left, right) do
    StagedIO.credit_spec(left) == StagedIO.credit_spec(right) and
      Map.take(left, [
        :arena,
        :run,
        :lease,
        :retained_capacity,
        :backing_capacity,
        :overlap_capacity
      ]) ==
        Map.take(right, [
          :arena,
          :run,
          :lease,
          :retained_capacity,
          :backing_capacity,
          :overlap_capacity
        ]) and
      left.grants == right.grants
  end

  defp reject_delivery(state, opts, epoch, io, receipt, reason) do
    state = unused_pregrant(state, receipt, opts, :response)
    lease = opts[:execution_lease]

    state =
      case state.export_io[lease] do
        %{epoch: ^epoch, io: ^io} -> poison(state, lease, reason)
        _ -> state
      end

    {{:error, reason}, state}
  end

  defp poison_matching(state, lease, epoch, operation, reason) do
    case state.export_io[lease] do
      %{epoch: ^epoch, operation: ^operation} -> poison(state, lease, reason)
      _ -> state
    end
  end

  defp poison(state, lease, reason, cleanup? \\ true) do
    case state.export_io[lease] do
      nil ->
        state

      %{status: :poisoned} ->
        if cleanup?, do: cleanup_lease(state, lease), else: state

      row ->
        reason = redact(reason)
        if row.settled_from, do: GenServer.reply(row.settled_from, {:error, reason})
        row = %{row | status: :poisoned, reason: reason, settled_from: nil}
        state = put_row(state, lease, row)
        if Process.alive?(row.io), do: Process.exit(row.io, :kill)
        state = ExportRun.fail(state, row.run, reason)
        if cleanup?, do: cleanup_lease(state, lease), else: state
    end
  end

  defp event_row(state, receipt, holder) do
    with lease when not is_nil(lease) <- state.export_io_holders[holder],
         %{delivery_ref: reference} = row <- state.export_io[lease],
         true <- is_reference(reference),
         true <- MapSet.member?(row.expected, {receipt, holder}) do
      {lease, row}
    else
      _ -> nil
    end
  end

  defp released?(row),
    do: MapSet.size(row.expected) > 0 and MapSet.size(row.released) == MapSet.size(row.expected)

  defp finish_operation(state, lease) do
    state = release_operation(state, lease)
    row = state.export_io[lease]

    row = %{
      row
      | operation: nil,
        credit: nil,
        funding: nil,
        payload_receipt: nil,
        delivery_ref: nil,
        plan: nil,
        released: MapSet.new(),
        adopted: MapSet.new(),
        expected: MapSet.new(),
        io_created: MapSet.new(),
        settled_from: nil,
        ack?: false,
        status: :idle
    }

    put_row(state, lease, row)
  end

  defp release_operation(state, lease) do
    row = state.export_io[lease]

    Enum.reduce(row.held, state, fn receipt, state ->
      if receipt == row.metadata_receipt, do: state, else: unhold(state, lease, receipt)
    end)
  end

  defp unused_pregrant(state, receipt, opts, kind) do
    lease = opts[:execution_lease]
    execution = state.executions[lease]

    if holding?(state, receipt) do
      state
    else
      with %{kind: ^kind, lease: ^lease, executor: executor, arena: arena, holders: holders} =
             record <-
             Resources.receipt(state.resources, receipt),
           true <-
             is_nil(execution) or (execution.worker == executor and execution.arena == arena),
           true <-
             kind != :source or
               (record.capacity == @metadata_bytes and record.actual == @metadata_bytes),
           %{status: :pending, lease: ^lease, arena: ^arena, origin: ^executor} <- holders[self()] do
        elem(transition(state, Resources.release(state.resources, receipt, self())), 1)
      else
        _ -> state
      end
    end
  end

  defp hold(state, lease, receipt, created?) do
    row = state.export_io[lease]

    if MapSet.member?(row.held, receipt) do
      state
    else
      created = if created?, do: MapSet.put(row.store_created, receipt), else: row.store_created
      row = %{row | held: MapSet.put(row.held, receipt), store_created: created}

      %{
        put_row(state, lease, row)
        | export_io_resources: Map.update(state.export_io_resources, receipt, 1, &(&1 + 1))
      }
    end
  end

  defp unhold(state, lease, receipt) do
    row = state.export_io[lease]

    releasable? =
      MapSet.member?(row.store_created, receipt) or
        MapSet.member?(row.deferred_owner_releases, receipt)

    row = %{
      row
      | held: MapSet.delete(row.held, receipt),
        store_created: MapSet.delete(row.store_created, receipt),
        deferred_owner_releases: MapSet.delete(row.deferred_owner_releases, receipt)
    }

    counts =
      case Map.fetch!(state.export_io_resources, receipt) do
        1 -> Map.delete(state.export_io_resources, receipt)
        count -> Map.put(state.export_io_resources, receipt, count - 1)
      end

    state = %{put_row(state, lease, row) | export_io_resources: counts}
    if releasable?, do: ResourceManager.release_owner(state, receipt), else: state
  end

  defp index_row(state, lease, row) do
    ring = state.export_io_runs |> Map.get(row.run, Ring.new()) |> Ring.put(lease)

    %{
      put_row(state, lease, row)
      | export_io_monitors: Map.put(state.export_io_monitors, row.monitor, lease),
        export_io_holders: Map.put(state.export_io_holders, row.io, lease),
        export_io_runs: Map.put(state.export_io_runs, row.run, ring)
    }
  end

  defp put_row(state, lease, row), do: %{state | export_io: Map.put(state.export_io, lease, row)}

  defp grant(state, receipt, holder) do
    case Resources.receipt(state.resources, receipt) do
      %{holders: holders} -> holders[holder]
      _ -> nil
    end
  end

  defp transition(state, result), do: ResourceManager.transition(state, result)

  defp first_row(state, run) do
    case state.export_io_runs[run] do
      nil ->
        nil

      ring ->
        case Ring.take(ring) do
          :empty -> nil
          {:ok, lease, _} -> {lease, Map.fetch!(state.export_io, lease)}
        end
    end
  end

  defp schedule_drain(state, run) do
    case first_row(state, run) do
      nil ->
        state

      {lease, row} ->
        if row.drain_remaining == 0, do: send(self(), {:export_io_drain, run})
        put_row(state, lease, %{row | drain_remaining: Ring.size(state.export_io_runs[run])})
    end
  end

  defp continue_drain(state, run, remaining) when remaining > 0 do
    case first_row(state, run) do
      nil ->
        state

      {lease, row} ->
        send(self(), {:export_io_drain, run})

        put_row(state, lease, %{
          row
          | drain_remaining: min(remaining, Ring.size(state.export_io_runs[run]))
        })
    end
  end

  defp continue_drain(state, _run, _remaining), do: state

  defp sweep_batch(state, _run, 0), do: state

  defp sweep_batch(state, run, count) do
    case state.export_io_runs[run] do
      nil ->
        state

      ring ->
        sweep_next_lease(state, run, count, ring)
    end
  end

  defp sweep_next_lease(state, run, count, ring) do
    case Ring.take(ring) do
      :empty ->
        state

      {:ok, lease, ring} ->
        state = %{state | export_io_runs: Map.put(state.export_io_runs, run, ring)}
        state = sweep(state, lease)

        state =
          case state.export_io[lease] do
            nil ->
              state

            _ ->
              %{
                state
                | export_io_runs: Map.update!(state.export_io_runs, run, &Ring.put(&1, lease))
              }
          end

        state =
          if Ring.size(Map.get(state.export_io_runs, run, Ring.new())) == 0,
            do: %{state | export_io_runs: Map.delete(state.export_io_runs, run)},
            else: state

        sweep_batch(state, run, count - 1)
    end
  end

  defp cleanup_lease(state, lease) do
    if Map.has_key?(state.export_io, lease), do: sweep(state, lease), else: state
  end

  defp sweep(state, lease) do
    row = state.export_io[lease]
    ended? = row.ended? or not Map.has_key?(state.executions, lease)
    state = put_row(state, lease, %{row | ended?: ended?})

    state =
      if row.status != :idle and row.status != :poisoned and
           (ended? or not Authority.execution_current?(lease, row.worker) or
              not Process.alive?(row.filesystem)),
         do: poison(state, lease, :stale_execution, false),
         else: state

    row = state.export_io[lease]
    safe? = is_nil(row.delivery_ref) or released?(row) or not Process.alive?(row.filesystem)
    state = if row.status == :poisoned and safe?, do: release_operation(state, lease), else: state
    row = state.export_io[lease]

    if ended? and safe? and row.down? and
         Enum.all?(row.io_created, &(grant(state, &1, row.io) == nil)) do
      drop_row(state, lease)
    else
      state
    end
  end

  defp drop_row(state, lease) do
    row = state.export_io[lease]
    state = release_operation(state, lease)
    state = unhold(state, lease, row.metadata_receipt)
    Process.demonitor(row.monitor, [:flush])

    ring = state.export_io_runs |> Map.get(row.run, Ring.new()) |> Ring.delete(lease)

    runs =
      if Ring.size(ring) == 0,
        do: Map.delete(state.export_io_runs, row.run),
        else: Map.put(state.export_io_runs, row.run, ring)

    state = %{
      state
      | export_io: Map.delete(state.export_io, lease),
        export_io_monitors: Map.delete(state.export_io_monitors, row.monitor),
        export_io_holders: Map.delete(state.export_io_holders, row.io),
        export_io_runs: runs
    }

    state =
      case first_row(state, row.run) do
        {next_lease, next} when row.drain_remaining > 0 ->
          put_row(state, next_lease, %{
            next
            | drain_remaining: min(row.drain_remaining, Ring.size(ring))
          })

        _ ->
          state
      end

    Crawler.Store.ExportRun.progress(state, row.run)
  end

  defp row_current?(state, lease, row) do
    case state.executions[lease] do
      %{opts: opts} ->
        match?({:ok, _, _}, current(state, Map.put(opts, :execution_lease, lease), row.epoch))

      _ ->
        false
    end
  end

  defp redact({:error, reason}), do: redact_reason(reason)
  defp redact(reason), do: redact_reason(reason)
  defp redact_reason({:deadline, kind}) when kind in [:attempt, :run], do: {:deadline, kind}

  defp redact_reason({:limit, reason})
       when reason in [:max_retained_bytes, :arena_capacity, :receipt_capacity],
       do: {:limit, reason}

  defp redact_reason(reason)
       when reason in [
              :execution_ended,
              :companion_down,
              :producer_down,
              :filesystem_down,
              :stale_execution,
              :release_before_adoption,
              :invalid_acknowledgement,
              :stale_write,
              :changed_delivery_credit,
              :invalid_delivery,
              :invalid_delivery_funding,
              :unfunded,
              :unfunded_payload,
              :invalid_io_payload,
              :invalid_store_grant,
              :existing_companion_grant
            ],
       do: reason

  defp redact_reason(_reason), do: :export_io_failed
end
