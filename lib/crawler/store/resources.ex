defmodule Crawler.Store.Resources do
  @moduledoc """
  Pure retained-resource accounting. Store must fence run/lease admission, validate live
  PIDs, and apply the returned effects before it replies or dispatches another job.

  An envelope includes all pipeline backing bytes and receipt/holder metadata. Reserve
  and retain only spend that envelope; neither requests global credit. Close refunds
  unused credit, but does not assert that an executor dropped its references. Release
  is an explicit assertion that a holder dropped all references for that receipt.
  Callers must budget complete binary backing (including sub-binary parents), copied
  analysis structures, and concurrent scratch/snapshots before materializing them.

  External grants are issued before sending backing references. The target checks the
  protected grant view and execution lease at its mutation boundary, then reports
  `adopt/3` asynchronously. On abandonment Store revokes the grant before sending the
  probe. A target must reject a late registration and answer `settle/4` after checking
  both its retained state and queued registration protocol. No synchronous cache to
  Store call is needed. Holder DOWN is authoritative even if run authority is gone.

  Effects are `{:monitor, pid}`, `{:demonitor, pid}`,
  `{:put_arena, arena, lease, executor, run}`, `{:put_grant, ref, lease, pid,
  run, arena}`, `{:delete_grant, ref, pid}`, `{:revoke_run, run}`,
  `{:revoke_arena, arena}`, `{:abandon, pid, ref, lease}`, and `:credit`.
  Store coalesces credit wakes and maintains its fitting pending-handle index outside
  the executor pool. `admission/5` must also guard frontier metadata admission with a
  minimum production envelope, including arena bookkeeping. `arena_cost/4` supplies
  a conservative complete cost (including a new run root). Unknown external bytes
  are not assumed reclaimable. Admission options must contain normalized numeric
  limits and non-negative external byte counts. Absent run records are not a stale
  capability check: Store must reject retired leases before acquiring an arena.

  Every successful transition returns `{result, ledger, effects}`. Errors use
  `{{:error, reason}, ledger, []}`. Batches return `{{:done | :more, visited}, ...}`.
  Byte estimates deliberately overcharge map/index/monitor/grant bookkeeping.
  """

  @kinds [
    :response,
    :decoded,
    :analysis,
    :css_facts,
    :css_snapshot,
    :snapshot,
    :source,
    :scratch,
    :return_copy,
    :control
  ]
  @unit 4_096
  defstruct limit: 67_108_864,
            used: 0,
            open_arenas: 0,
            pending_grants: 0,
            runs: %{},
            arenas: %{},
            receipts: %{},
            holders: %{},
            stats: %{visited: 0, released: 0}

  def new(opts \\ %{}) do
    limit = Map.get(Map.new(opts), :max_retained_bytes, 67_108_864)
    if not is_integer(limit) or limit < 1, do: raise(ArgumentError, "invalid retained cap")
    %__MODULE__{limit: limit}
  end

  def bytes(state), do: state.used
  def stats(state), do: state.stats
  def holder_size(state, holder), do: set_size(get_in(state.holders, [holder, :entries]))

  def receipt(state, ref), do: state.receipts[ref]

  def capacity(state, run, opts \\ %{}) do
    opts = Map.new(opts)
    record = state.runs[run]
    limit = min(state.limit, Map.get(opts, :max_retained_bytes, state.limit))
    limit = if record, do: min(limit, record.limit), else: limit

    %{
      global: state.limit - state.used - Map.get(opts, :external_frontier_bytes, 0),
      run: limit - if(record, do: record.used, else: 0) - Map.get(opts, :external_run_bytes, 0)
    }
  end

  def arena_cost(run, lease, executor, envelope) do
    envelope + charge({run, lease, executor}) + charge(run)
  end

  @doc "Check metadata admission while preserving one minimum production arena."
  def admission(state, run, metadata, envelope, opts \\ %{})
      when is_integer(metadata) and metadata >= 0 and is_integer(envelope) and envelope >= 0 do
    opts = Map.new(opts)
    limit = min(state.limit, Map.get(opts, :max_retained_bytes, state.limit))
    external = Map.get(opts, :external_frontier_bytes, 0)
    run_external = Map.get(opts, :external_run_bytes, 0)
    record = state.runs[run]
    limit = if record, do: min(limit, record.limit), else: limit
    root = if record, do: 0, else: charge(run)
    cost = metadata + envelope + root
    run_used = if record, do: record.used, else: 0

    cond do
      record && record.retired? ->
        {:error, :stale}

      cost > state.limit or cost > limit ->
        {:limited, :pipeline_envelope}

      external + state.used + cost <= state.limit and run_external + run_used + cost <= limit ->
        :ok

      external + cost > state.limit or run_external + cost > limit ->
        {:limited, :production_headroom}

      true ->
        {:blocked, :resource_credit}
    end
  end

  def acquire(state, run, lease, executor, envelope, opts \\ %{})
      when is_reference(lease) and is_pid(executor) and is_integer(envelope) and envelope >= 0 do
    metadata = charge({run, lease, executor})

    case admission(state, run, metadata, envelope, opts) do
      :ok ->
        if holder_down?(state, executor) do
          error(state, :holder_down)
        else
          acquire_arena(state, run, lease, executor, envelope, opts, metadata)
        end

      reason ->
        {reason, state, []}
    end
  end

  defp acquire_arena(state, run, lease, executor, envelope, opts, metadata) do
    arena = make_ref()
    root = if state.runs[run], do: 0, else: charge(run)

    record = %{
      run: run,
      lease: lease,
      executor: executor,
      free: envelope,
      metadata: metadata,
      count: 0,
      open?: true
    }

    run_record =
      state.runs[run] ||
        %{
          retired?: false,
          used: 0,
          arenas: 0,
          root: root,
          limit: min(state.limit, Map.get(Map.new(opts), :max_retained_bytes, state.limit))
        }

    run_record = %{run_record | arenas: run_record.arenas + 1}

    state = %{
      state
      | open_arenas: state.open_arenas + 1,
        runs: Map.put(state.runs, run, run_record),
        arenas: Map.put(state.arenas, arena, record)
    }

    state = account(state, run, envelope + metadata + root)
    {state, effects} = index_put(state, executor, {:arena, arena}, [])
    {{:ok, arena}, state, effects([{:put_arena, arena, lease, executor, run} | effects])}
  end

  @doc "Transfer funded arena bytes to a separately counted persistent owner."
  def transfer_external(state, arena, lease, bytes) when is_integer(bytes) and bytes >= 0 do
    case live_arena(state, arena, lease) do
      %{free: free} = record when free >= bytes ->
        state = %{state | arenas: Map.put(state.arenas, arena, %{record | free: free - bytes})}
        {:ok, account(state, record.run, -bytes), []}

      nil ->
        error(state, :stale)

      _ ->
        error(state, {:limit, :arena_capacity})
    end
  end

  def reserve(state, arena, lease, kind, capacity, holder \\ nil)
      when kind in @kinds and is_integer(capacity) and capacity >= 0 do
    case live_arena(state, arena, lease) do
      nil -> error(state, :stale)
      record -> reserve_in(state, arena, record, kind, capacity, holder || record.executor)
    end
  end

  def reserve_up_to(state, arena, lease, kind, maximum, holder \\ nil)
      when kind in @kinds and is_integer(maximum) and maximum >= 0 do
    case live_arena(state, arena, lease) do
      nil ->
        error(state, :stale)

      record ->
        holder = holder || record.executor

        overhead =
          charge({kind, make_ref()}) + grant_cost(record.executor, nil) +
            if(holder == record.executor, do: 0, else: grant_cost(holder, record.executor))

        if record.free < overhead do
          error(state, {:limit, :arena_capacity})
        else
          capacity = min(maximum, record.free - overhead)

          case reserve_in(state, arena, record, kind, capacity, holder) do
            {{:ok, receipt}, state, effects} -> {{:ok, receipt, capacity}, state, effects}
            error -> error
          end
        end
    end
  end

  def commit(state, ref, lease, actual) when is_integer(actual) and actual >= 0 do
    case state.receipts[ref] do
      %{lease: ^lease, actual: nil} = record ->
        cond do
          is_nil(live_arena(state, record.arena, lease)) ->
            error(state, :stale)

          actual > record.capacity ->
            error(state, {:limit, :receipt_capacity})

          true ->
            state = refund(state, record.arena, record.capacity - actual)
            record = %{record | actual: actual}
            {:ok, %{state | receipts: Map.put(state.receipts, ref, record)}, []}
        end

      _ ->
        error(state, :stale)
    end
  end

  def commit_response(state, ref, lease, actual, copy_bytes)
      when is_integer(actual) and actual >= 0 and is_integer(copy_bytes) and copy_bytes >= 0 and
             copy_bytes <= actual do
    case state.receipts[ref] do
      %{kind: :response} ->
        case commit(state, ref, lease, actual) do
          {:ok, state, effects} ->
            record = Map.put(state.receipts[ref], :copy_bytes, copy_bytes)
            {:ok, %{state | receipts: Map.put(state.receipts, ref, record)}, effects}

          error ->
            error
        end

      _ ->
        error(state, :invalid_backing_receipt)
    end
  end

  def commit_response(state, _ref, _lease, _actual, _copy_bytes),
    do: error(state, :invalid_response_charge)

  def retain(state, ref, lease, executor, holder) when is_pid(holder) do
    case state.receipts[ref] do
      %{lease: ^lease, executor: ^executor} = record ->
        retain_from(state, ref, record.arena, lease, executor, holder)

      _ ->
        error(state, :stale)
    end
  end

  @doc """
  Retain a value using a live arena. Each new holder reserves its structural copy.
  Explicit same-run response backing transfers share the original body binary,
  while reserving the measured response structure separately.
  """
  def retain_from(state, ref, arena, lease, origin, holder, role \\ :copy) when is_pid(holder) do
    record = state.receipts[ref]
    target = live_arena(state, arena, lease)

    cond do
      is_nil(record) or is_nil(target) ->
        error(state, :stale)

      role not in [:copy, :backing] or
          (role == :backing and (record.kind != :response or not is_integer(record[:copy_bytes]))) ->
        error(state, :invalid_backing_receipt)

      not match?(
        %{status: status} when status in [:owned, :adopted, :retained],
        record.holders[origin]
      ) ->
        error(state, :not_owner)

      Map.has_key?(record.holders, holder) ->
        error(state, :already_retained)

      holder_down?(state, holder) or holder_down?(state, origin) ->
        error(state, :holder_down)

      true ->
        cost =
          grant_cost(holder, origin) +
            if(role == :backing and target.run === record.run,
              do: record.copy_bytes,
              else: record.actual || record.capacity
            )

        if target.free < cost do
          error(state, {:limit, :arena_capacity})
        else
          state = spend(state, arena, cost)
          state = if arena == record.arena, do: state, else: dependency(state, arena, 1)
          grant = %{status: :pending, origin: origin, metadata: cost, arena: arena, lease: lease}
          record = %{record | holders: Map.put(record.holders, holder, grant)}

          state = %{
            state
            | receipts: Map.put(state.receipts, ref, record),
              pending_grants: state.pending_grants + 1
          }

          {state, effects} = index_put(state, holder, {:grant, ref}, [])
          {state, effects} = index_put(state, origin, {:probe, ref, holder}, effects)
          {:ok, state, effects(publish(state, record, ref, holder, effects))}
        end
    end
  end

  @doc "Report adoption already linearized by the holder's nonblocking grant check."
  def adopt(state, ref, holder), do: settle(state, ref, holder, :retained)

  def settle(state, ref, holder, :released), do: release(state, ref, holder)

  def settle(state, ref, holder, :retained) do
    case state.receipts[ref] do
      %{holders: holders} = record ->
        case holders[holder] do
          %{status: status} = grant when status in [:pending, :abandoned, :adopted, :retained] ->
            retain_grant(state, ref, holder, record, grant, status)

          _ ->
            error(state, :unknown_grant)
        end

      nil ->
        error(state, :unknown_grant)
    end
  end

  defp retain_grant(state, ref, holder, record, grant, status) do
    status = if status in [:abandoned, :retained], do: :retained, else: :adopted
    decrement = if grant.status in [:pending, :abandoned], do: 1, else: 0
    grant = %{grant | status: status}
    record = %{record | holders: Map.put(record.holders, holder, grant)}

    {:ok,
     %{
       state
       | receipts: Map.put(state.receipts, ref, record),
         pending_grants: state.pending_grants - decrement
     }, []}
  end

  def release(state, ref, holder) do
    case state.receipts[ref] do
      %{holders: holders} = record ->
        case holders[holder] do
          nil ->
            error(state, :unknown_grant)

          grant ->
            {state, effects} = remove_grant(state, ref, record, holder, grant, [])
            {:ok, state, effects(effects)}
        end

      nil ->
        error(state, :unknown_grant)
    end
  end

  def current?(state, ref, lease, holder) do
    case state.receipts[ref] do
      %{holders: holders} ->
        case holders[holder] do
          %{lease: ^lease, arena: arena, status: status}
          when status in [:owned, :pending, :adopted] ->
            not is_nil(live_arena(state, arena, lease)) and not holder_down?(state, holder)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  @doc "Refund unused arena credit. Live holder references remain charged."
  def close(state, arena) do
    case state.arenas[arena] do
      %{open?: true} = record ->
        state = account(state, record.run, -record.free)
        record = %{record | open?: false, free: 0}

        state = %{
          state
          | arenas: Map.put(state.arenas, arena, record),
            open_arenas: state.open_arenas - 1
        }

        {state, effects} = maybe_drop_arena(state, arena, [{:revoke_arena, arena}, :credit])
        {:ok, state, effects(effects)}

      _ ->
        {:ok, state, []}
    end
  end

  def retire_run(state, run) do
    case state.runs[run] do
      nil ->
        {:ok, state, [{:revoke_run, run}]}

      record ->
        record = %{record | retired?: true}
        {:ok, %{state | runs: Map.put(state.runs, run, record)}, [{:revoke_run, run}]}
    end
  end

  @doc "Process only this holder's indexed entries; call again while result is :more."
  def holder_down(state, holder, batch \\ 64), do: release_holder(state, holder, batch)

  def release_holder(state, holder, batch \\ 64) when is_integer(batch) and batch > 0 do
    case state.holders[holder] do
      nil ->
        {{:done, 0}, state, []}

      record ->
        state = %{state | holders: Map.put(state.holders, holder, %{record | down?: true})}
        release_batch(state, holder, batch, 0, [])
    end
  end

  defp reserve_in(state, arena, record, kind, capacity, holder) when is_pid(holder) do
    ref = make_ref()
    metadata = charge({kind, ref})

    cost =
      metadata + capacity + grant_cost(record.executor, nil) +
        if(holder == record.executor, do: 0, else: grant_cost(holder, record.executor))

    cond do
      holder_down?(state, holder) or holder_down?(state, record.executor) ->
        error(state, :holder_down)

      record.free < cost ->
        error(state, {:limit, :arena_capacity})

      true ->
        grant = %{
          status: :owned,
          origin: nil,
          metadata: grant_cost(record.executor, nil),
          arena: arena,
          lease: record.lease
        }

        receipt = %{
          arena: arena,
          run: record.run,
          lease: record.lease,
          executor: record.executor,
          kind: kind,
          capacity: capacity,
          actual: nil,
          metadata: metadata,
          holders: %{record.executor => grant}
        }

        receipt =
          if holder == record.executor,
            do: receipt,
            else: %{
              receipt
              | holders:
                  Map.put(receipt.holders, holder, %{
                    status: :pending,
                    origin: record.executor,
                    metadata: grant_cost(holder, record.executor),
                    arena: arena,
                    lease: record.lease
                  })
            }

        state = spend(state, arena, cost)
        record = state.arenas[arena]

        state = %{
          state
          | pending_grants: state.pending_grants + if(holder == record.executor, do: 0, else: 1),
            arenas: Map.put(state.arenas, arena, %{record | count: record.count + 1}),
            receipts: Map.put(state.receipts, ref, receipt)
        }

        {state, effects} = index_put(state, record.executor, {:grant, ref}, [])
        effects = publish(state, receipt, ref, record.executor, effects)

        {state, effects} =
          if holder == record.executor,
            do: {state, effects},
            else: index_put(state, holder, {:grant, ref}, effects)

        {state, effects} =
          if holder == record.executor,
            do: {state, effects},
            else: index_put(state, record.executor, {:probe, ref, holder}, effects)

        effects =
          if holder == record.executor,
            do: effects,
            else: publish(state, receipt, ref, holder, effects)

        {{:ok, ref}, state, effects(effects)}
    end
  end

  defp release_batch(state, holder, remaining, count, effects) do
    entries = get_in(state.holders, [holder, :entries])

    cond do
      set_size(entries) == 0 ->
        {{:done, count}, state, effects(effects)}

      remaining == 0 ->
        {{:more, count}, state, effects(effects)}

      true ->
        entry = :gb_sets.smallest(entries)
        {state, effects} = index_delete(state, holder, entry, effects)
        {state, effects} = release_entry(state, holder, entry, effects)
        state = %{state | stats: Map.update!(state.stats, :visited, &(&1 + 1))}
        release_batch(state, holder, remaining - 1, count + 1, effects)
    end
  end

  defp release_entry(state, _holder, {:arena, arena}, effects) do
    {:ok, state, more} = close(state, arena)
    {state, more ++ effects}
  end

  defp release_entry(state, holder, {:grant, ref}, effects) do
    case state.receipts[ref] do
      %{holders: holders} = record ->
        remove_grant(state, ref, record, holder, holders[holder], effects)

      nil ->
        {state, effects}
    end
  end

  defp release_entry(state, _holder, {:probe, ref, target}, effects) do
    case state.receipts[ref] do
      %{holders: holders} = record ->
        case holders[target] do
          %{status: :pending} = grant ->
            record = %{record | holders: Map.put(holders, target, %{grant | status: :abandoned})}
            state = %{state | receipts: Map.put(state.receipts, ref, record)}

            {state,
             [{:delete_grant, ref, target}, {:abandon, target, ref, grant.lease} | effects]}

          _ ->
            {state, effects}
        end

      nil ->
        {state, effects}
    end
  end

  defp remove_grant(state, _ref, _record, _holder, nil, effects), do: {state, effects}

  defp remove_grant(state, ref, record, holder, grant, effects) do
    {state, effects} = index_delete(state, holder, {:grant, ref}, effects)

    {state, effects} =
      if grant.origin,
        do: index_delete(state, grant.origin, {:probe, ref, holder}, effects),
        else: {state, effects}

    record = %{record | holders: Map.delete(record.holders, holder)}

    state =
      if grant.status in [:pending, :abandoned],
        do: %{state | pending_grants: state.pending_grants - 1},
        else: state

    state = refund(state, grant.arena, grant.metadata)

    {state, effects} =
      if grant.arena == record.arena,
        do: {state, effects},
        else: maybe_drop_arena(dependency(state, grant.arena, -1), grant.arena, effects)

    effects = [{:delete_grant, ref, holder}, :credit | effects]

    if map_size(record.holders) == 0 do
      state = refund(state, record.arena, record.metadata + (record.actual || record.capacity))
      arena = state.arenas[record.arena]

      state = %{
        state
        | receipts: Map.delete(state.receipts, ref),
          arenas: Map.put(state.arenas, record.arena, %{arena | count: arena.count - 1}),
          stats: Map.update!(state.stats, :released, &(&1 + 1))
      }

      maybe_drop_arena(state, record.arena, effects)
    else
      {%{state | receipts: Map.put(state.receipts, ref, record)}, effects}
    end
  end

  defp maybe_drop_arena(state, arena, effects) do
    case state.arenas[arena] do
      %{open?: false, count: 0} = record ->
        state = account(state, record.run, -record.metadata)
        run = state.runs[record.run]

        state = %{
          state
          | arenas: Map.delete(state.arenas, arena),
            runs: Map.put(state.runs, record.run, %{run | arenas: run.arenas - 1})
        }

        {state, effects} =
          index_delete(state, record.executor, {:arena, arena}, [{:drop_arena, arena} | effects])

        if run.arenas == 1 do
          state = account(state, record.run, -run.root)

          {%{state | runs: Map.delete(state.runs, record.run)},
           [{:drop_run, record.run} | effects]}
        else
          {state, effects}
        end

      _ ->
        {state, effects}
    end
  end

  defp live_arena(state, arena, lease) do
    case state.arenas[arena] do
      %{lease: ^lease, open?: true} = record ->
        if state.runs[record.run].retired?, do: nil, else: record

      _ ->
        nil
    end
  end

  defp spend(state, arena, bytes) do
    record = state.arenas[arena]
    %{state | arenas: Map.put(state.arenas, arena, %{record | free: record.free - bytes})}
  end

  defp refund(state, arena, bytes) do
    record = state.arenas[arena]
    if record.open?, do: spend(state, arena, -bytes), else: account(state, record.run, -bytes)
  end

  defp account(state, run, delta) do
    record = state.runs[run]

    %{
      state
      | used: state.used + delta,
        runs: Map.put(state.runs, run, %{record | used: record.used + delta})
    }
  end

  defp index_put(state, holder, entry, effects) do
    record = state.holders[holder]
    effects = if record, do: effects, else: [{:monitor, holder} | effects]
    record = record || %{entries: :gb_sets.empty(), down?: false}
    record = %{record | entries: :gb_sets.add(entry, record.entries)}
    {%{state | holders: Map.put(state.holders, holder, record)}, effects}
  end

  defp index_delete(state, holder, entry, effects) do
    case state.holders[holder] do
      nil ->
        {state, effects}

      record ->
        entries = :gb_sets.delete_any(entry, record.entries)

        if :gb_sets.is_empty(entries) do
          {%{state | holders: Map.delete(state.holders, holder)},
           [{:demonitor, holder} | effects]}
        else
          {%{state | holders: Map.put(state.holders, holder, %{record | entries: entries})},
           effects}
        end
    end
  end

  defp publish(state, record, ref, holder, effects) do
    grant = record.holders[holder]
    arena = state.arenas[grant.arena]
    [{:put_grant, ref, grant.lease, holder, arena.run, grant.arena} | effects]
  end

  defp dependency(state, arena, delta) do
    record = state.arenas[arena]
    %{state | arenas: Map.put(state.arenas, arena, %{record | count: record.count + delta})}
  end

  defp effects(effects) do
    effects
    |> Enum.uniq()
    |> Enum.sort_by(fn
      {:monitor, _} -> 0
      {:put_arena, _, _, _, _} -> 1
      {:put_grant, _, _, _, _, _} -> 1
      {:revoke_run, _} -> 2
      {:revoke_arena, _} -> 2
      {:drop_arena, _} -> 3
      {:drop_run, _} -> 3
      {:delete_grant, _, _} -> 3
      {:demonitor, _} -> 4
      {:abandon, _, _, _} -> 5
      :credit -> 6
    end)
  end

  defp holder_down?(state, holder), do: match?(%{down?: true}, state.holders[holder])
  defp set_size(nil), do: 0
  defp set_size(set), do: :gb_sets.size(set)
  defp grant_cost(holder, origin), do: charge({holder, origin})
  defp charge(term), do: @unit + 8 * :erlang.external_size(term)
  defp error(state, reason), do: {{:error, reason}, state, []}
end
