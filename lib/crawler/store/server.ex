defmodule Crawler.Store.Server do
  @moduledoc false

  use GenServer

  alias Crawler.QueueHandler
  alias Crawler.Store.Aliases
  alias Crawler.Store.Claims
  alias Crawler.Store.DB
  alias Crawler.Store.Page
  alias Crawler.Store.Settlements
  alias Crawler.Store.State

  @impl true
  def init(_opts) do
    {:ok, _} = Registry.start_link(keys: :unique, name: DB)

    {:ok, %State{}}
  end

  @impl true
  def handle_call({:add, {url, scope} = key, generation, queue}, _from, state) do
    if current_work?(state, scope, generation, queue) do
      result =
        case Registry.lookup(DB, key) do
          [{pid, _page}] -> {:error, {:already_registered, pid}}
          [] -> Registry.register(DB, key, %Page{url: url})
        end

      state = if match?({:ok, _}, result), do: State.track_page(state, key, queue), else: state
      {:reply, result, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:register_alias, {_url, scope} = key, generation, queue}, {worker, _}, state) do
    if current_work?(state, scope, generation, queue) do
      {result, state} = Aliases.register(state, key, queue, worker)
      {:reply, result, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:retain_alias, key, source_key, body, opts}, {worker, _}, state) do
    if current_work?(state, opts[:scope], opts[:generation], opts[:queue]) do
      {reply, state} = Settlements.retain(state, key, source_key, body, opts, worker)
      {:reply, reply, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:discard_retained_alias, ref}, {worker, _}, state) do
    {:reply, :ok, Settlements.discard(state, ref, worker)}
  end

  def handle_call({:start_settlement, ref}, {worker, _}, state) do
    case Settlements.start(state, ref) do
      {:ok, candidate, state} ->
        token = Process.monitor(worker)
        opts = Map.put(candidate.opts, :page_key, candidate.key)
        claims = Claims.track(state.claims, token, worker, opts, false)
        state = Settlements.started(%{state | claims: claims}, ref, token)
        {:reply, {:ok, token, candidate.body, candidate.opts}, state}

      {:skip, state} ->
        {:reply, :skip, state}
    end
  end

  def handle_call({:complete_settlement, ref, token}, {worker, _}, state) do
    state =
      if Claims.owned?(state.claims, token, worker),
        do: Settlements.complete(state, ref, token),
        else: state

    {:reply, :ok, state}
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
        {:add_page_data, {_url, scope} = key, body, opts, generation, queue},
        _from,
        state
      ) do
    result =
      if current_work?(state, scope, generation, queue) do
        Registry.update_value(DB, key, &%{&1 | body: body, opts: opts})
      else
        {:error, :stale}
      end

    {:reply, result, state}
  end

  def handle_call({:processed, {_url, scope} = key, generation, queue}, _from, state) do
    if current_work?(state, scope, generation, queue) do
      result = Registry.update_value(DB, key, &%{&1 | processed: true})
      {:reply, result, State.forget_page(state, key)}
    else
      {:reply, :stale, state}
    end
  end

  def handle_call(
        {:complete_page, {_url, scope} = key, alias_key, generation, queue},
        {worker, _},
        state
      ) do
    if current_work?(state, scope, generation, queue) do
      state =
        case Registry.update_value(DB, key, &%{&1 | processed: true}) do
          {_page, %Page{processed: true}} ->
            state

          {_page, _previous} ->
            state
            |> State.increment(:ops, scope, queue)
            |> State.forget_page(key)
            |> complete_alias(alias_key, queue)
            |> Settlements.complete_source(key, worker)

          :error ->
            state
        end

      {:reply, :ok, state}
    else
      {:reply, :stale, state}
    end
  end

  def handle_call({:delete, {_url, scope} = key, generation, queue}, _from, state) do
    if current_work?(state, scope, generation, queue) do
      result = Registry.unregister(DB, key)
      {:reply, result, State.forget_page(state, key)}
    else
      {:reply, :stale, state}
    end
  end

  def handle_call({:drop_scope, scope}, _from, state) do
    unregister_scope(scope)
    state = discard_claims(state, Claims.retire_scope(state.claims, scope))
    state = Settlements.drop_scope(state, scope)
    state = State.drop_scope(state, scope)
    {:reply, State.generation(state, scope), state}
  end

  def handle_call({:generation, scope}, _from, state) do
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
    state = Enum.reduce(State.deferred_scopes(state), state, &settle_scope_work(&2, &1))
    {:reply, :ok, state}
  end

  def handle_call({:try_claim, scope, max_pages, generation, queue}, _from, state) do
    if current_work?(state, scope, generation, queue) do
      {reply, state} = State.try_claim(state, scope, max_pages, queue)
      {:reply, reply, state}
    else
      {:reply, :stale, state}
    end
  end

  def handle_call({:start_work, opts}, {worker, _tag}, state) do
    if current_work?(state, opts[:scope], opts[:generation], opts[:queue]) do
      {reply, state} = State.start_work(state, opts)

      if reply == :ok do
        token = Process.monitor(worker)
        claims = Claims.track(state.claims, token, worker, opts)
        {:reply, {:ok, token}, %{state | claims: claims}}
      else
        {:reply, reply, state}
      end
    else
      {:reply, :stale, state}
    end
  end

  def handle_call({:finish_claim, token}, {worker, _tag}, state) do
    {:reply, :ok, release_claim(state, token, worker)}
  end

  def handle_call({:inflight_dec, scope, generation, queue}, _from, state) do
    state =
      if current_work?(state, scope, generation, queue) do
        state = State.decrement(state, :inflight, scope, queue)
        if State.deferred?(state, scope), do: settle_scope_work(state, scope), else: state
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:inflight_count, scope}, _from, state) do
    {:reply, State.count(state, :inflight, scope), state}
  end

  def handle_call({:pending_count, scope}, _from, state) do
    {:reply, State.count(state, :pending, scope), state}
  end

  def handle_call({:work_pending?, scope, generation, queue}, _from, state) do
    pending? =
      current_work?(state, scope, generation, queue) and State.work_pending?(state, scope, queue)

    {:reply, pending?, state}
  end

  def handle_call({:note_enqueued, scope, generation, queue}, _from, state) do
    if State.current?(state, scope, generation) and queue_available?(state, queue) do
      state = state |> monitor_queue(queue) |> State.note_enqueued(scope, queue)
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

  def handle_call({:publish_file, scope, generation, dest, temp, queue}, _from, state) do
    reply =
      if current_work?(state, scope, generation, queue) do
        case File.rename(temp, dest) do
          :ok -> :ok
          {:error, reason} -> {:error, "Cannot write to file #{dest}, reason: #{reason}"}
        end
      else
        File.rm(temp)
        {:error, :stale}
      end

    {:reply, reply, state}
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
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    if state.monitors[pid] == ref do
      state = retire_queue(state, pid)
      {:noreply, %{state | monitors: Map.delete(state.monitors, pid)}}
    else
      {:noreply, release_claim(state, ref, pid)}
    end
  end

  defp release_claim(state, token, worker) do
    case Claims.take(state.claims, token, worker) do
      {nil, _claims} ->
        state

      {claim, claims} ->
        Process.demonitor(token, [:flush])
        state = Settlements.claim_finished(%{state | claims: claims}, token)

        if current_work?(state, claim.scope, claim.generation, claim.queue) do
          state
          |> State.finish_work(claim.scope, claim.reserved?, claim.queue)
          |> settle_scope_work(claim.scope)
        else
          state
        end
    end
  end

  defp discard_claims(state, {refs, claims}) do
    Enum.each(refs, &Process.demonitor(&1, [:flush]))
    %{state | claims: claims}
  end

  defp complete_alias(state, nil, _queue), do: state

  defp complete_alias(state, key, queue) do
    if State.owns_page?(state, key, queue) do
      Registry.update_value(DB, key, &%{&1 | processed: true})
      State.forget_page(state, key)
    else
      state
    end
  end

  defp retire_queue(state, queue) do
    scopes = State.queue_scopes(state, queue)
    state = discard_claims(state, Claims.retire_queue(state.claims, queue))
    state = Settlements.drop_queue(state, queue)
    {pages, state} = State.release_queue(state, queue)
    Enum.each(pages, &Registry.unregister(DB, &1))

    state = Enum.reduce(scopes, state, &settle_scope_work(&2, &1))

    if Process.alive?(queue) do
      state
    else
      %{state | closing: MapSet.delete(state.closing, queue)}
    end
  end

  defp settle_scope_work(state, scope) do
    state = if State.deferred?(state, scope), do: requeue_deferred(state, scope), else: state
    {pages, state} = State.take_idle_pages(state, scope)
    Enum.each(pages, &Registry.unregister(DB, &1))
    Settlements.schedule(state, scope)
  end

  defp requeue_deferred(state, scope) do
    {ready, state} = State.resume_deferred(state, scope)

    Enum.each(ready, fn opts ->
      if queue_available?(state, opts[:queue]), do: QueueHandler.requeue(opts)
    end)

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

  defp current_work?(state, scope, generation, queue) do
    State.current?(state, scope, generation) and queue_available?(state, queue) and
      State.queue_active?(state, scope, queue)
  end

  defp queue_available?(_state, nil), do: true

  defp queue_available?(state, queue) when is_pid(queue) do
    Process.alive?(queue) and not MapSet.member?(state.closing, queue)
  end

  defp queue_available?(_state, _queue), do: false

  defp unregister_scope(scope) do
    DB
    |> Registry.select([
      {{:"$1", :_, :_}, [{:"=:=", {:element, 2, :"$1"}, {:const, scope}}], [:"$1"]}
    ])
    |> Enum.each(&Registry.unregister(DB, &1))
  end
end
