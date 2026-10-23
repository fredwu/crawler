defmodule Crawler.Store.State do
  @moduledoc false

  alias Crawler.Store.Budget
  alias Crawler.Store.Claims
  alias Crawler.Store.CookieProof
  alias Crawler.Store.Scope
  alias Crawler.Store.Settlements
  alias Crawler.Store.Work

  @enforce_keys [:incarnation]
  defstruct incarnation: nil,
            scopes: %{},
            executions: %{},
            exports: %{},
            export_bytes: 0,
            export_monitors: %{},
            export_actors: %{},
            export_waiters: %{},
            export_waiter_leases: %{},
            export_pending: Crawler.Frontier.Ring.new(),
            export_scheduled?: false,
            export_drivers: %{},
            export_io: %{},
            export_io_monitors: %{},
            export_io_holders: %{},
            export_io_runs: %{},
            export_io_resources: %{},
            source_caches: %{},
            source_cache_bytes: 0,
            source_cache_run_bytes: %{},
            source_cache_run_refunds: %{},
            source_cache_refund_runs: Crawler.Frontier.Ring.new(),
            source_cache_workspace: 0,
            source_cache_pending: Crawler.Frontier.Ring.new(),
            source_cache_scheduled?: false,
            source_cache_refund: 0,
            source_cache_refund_scheduled?: false,
            source_cache_releases: Crawler.Frontier.Ring.new(),
            source_cache_resources: %{},
            source_cache_workspaces: %{},
            source_cache_leases: %{},
            scheduler: nil,
            resources: nil,
            resource_monitors: %{},
            resource_refs: %{},
            resource_relays: %{},
            resource_credit_scheduled?: false,
            resource_waiters: Crawler.Frontier.Index.new(),
            pending_executions: %{},
            execution_returns: %{},
            return_producers: %{},
            return_callers: %{},
            return_uses: %{},
            return_owned: MapSet.new(),
            direct_waiters: %{},
            direct_targets: %{},
            direct_owners: %{},
            direct_runs: %{},
            retired_direct_runs: Crawler.Frontier.Ring.new(),
            direct_workers: %{},
            direct_monitors: %{},
            waiting_workers: %{},
            waiting_refs: %{},
            waiting_bytes: 0,
            scheduler_scheduled?: false,
            retiring_runs: Crawler.Frontier.Ring.new(),
            retiring_queues: Crawler.Frontier.Ring.new(),
            retiring_scheduled?: false,
            scheduler_monitors: %{},
            scheduler_workers: %{},
            scope_runs: %{},
            scope_disposals: %{},
            disposal_order: Crawler.Frontier.Ring.new(),
            disposal_scheduled?: false,
            execution_monitors: %{},
            execution_workers: %{},
            execution_runs: %{},
            execution_claims: %{},
            cookie_outcomes: %{},
            cookie_bytes: 0,
            css_jobs: %{},
            css_unsettled: %{},
            css_runners: %{},
            css_run_jobs: %{},
            css_executions: %{},
            css_pending: Crawler.Frontier.Ring.new(),
            owners: %{},
            closing: MapSet.new(),
            monitors: %{},
            claims: %Claims{},
            settlements: %Settlements{},
            cookies: %{},
            retained_pages: %{},
            persistent_resources: MapSet.new(),
            persistent_counts: %{},
            source_resources: MapSet.new(),
            robots: %{},
            robots_receipts: %{}

  def new,
    do: %__MODULE__{
      incarnation: make_ref(),
      scheduler: Crawler.Store.Scheduler.new(),
      resources: Crawler.Store.Resources.new()
    }

  def register_queue(state, scope, queue), do: update_work(state, scope, queue, & &1)

  def generation(state, scope), do: {state.incarnation, scope, get_scope(state, scope).revision}

  def ensure_scope(state, scope), do: update_scope(state, scope, & &1)

  def current?(_state, _scope, nil), do: true

  def current?(state, scope, generation),
    do: generation(state, scope) === generation and get_scope(state, scope).outcome == :open

  def queue_active?(_state, _scope, nil), do: true
  def queue_active?(state, scope, queue), do: Map.has_key?(get_scope(state, scope).work, queue)

  def work_pending?(state, scope, queue) do
    work = Map.get(get_scope(state, scope).work, queue, %Work{})
    work.pending > 0 or work.inflight > 0
  end

  def count(state, :ops, scope), do: get_scope(state, scope).ops

  def count(state, counter, scope) when counter in [:pending, :inflight] do
    state
    |> get_scope(scope)
    |> Map.fetch!(:work)
    |> Map.values()
    |> Enum.reduce(0, fn work, sum -> sum + Map.fetch!(work, counter) end)
  end

  def ops_count(state),
    do: Enum.reduce(state.scopes, 0, fn {_, scope}, sum -> sum + scope.ops end)

  def reset_ops(state) do
    %{state | scopes: Map.new(state.scopes, fn {name, scope} -> {name, %{scope | ops: 0}} end)}
  end

  def increment(state, :ops, scope, _queue) do
    update_scope(state, scope, &%{&1 | ops: &1.ops + 1})
  end

  def increment(state, counter, scope, queue) do
    update_work(state, scope, queue, &Map.update!(&1, counter, fn count -> count + 1 end))
  end

  def decrement(state, counter, scope, queue) do
    update_work(state, scope, queue, &Map.update!(&1, counter, fn count -> max(count - 1, 0) end))
  end

  def try_claim(state, scope, max_pages, queue) do
    if budget_status(state, scope, max_pages) == :ok do
      {:ok, increment(state, :inflight, scope, queue)}
    else
      {:full, state}
    end
  end

  def note_enqueued(state, scope, queue), do: increment(state, :pending, scope, queue)

  def finish_work(state, scope, claimed?, queue) do
    state = if claimed?, do: decrement(state, :inflight, scope, queue), else: state
    decrement(state, :pending, scope, queue)
  end

  def track_page(state, {_, scope} = key, queue) do
    update_work(state, scope, queue, &%{&1 | pages: MapSet.put(&1.pages, key)})
  end

  def owns_page?(state, {_, scope} = key, queue) do
    work = Map.get(get_scope(state, scope).work, queue, %Work{})
    MapSet.member?(work.pages, key)
  end

  def page_owner(state, {_, scope} = key) do
    Enum.find_value(get_scope(state, scope).work, fn {queue, work} ->
      if MapSet.member?(work.pages, key), do: {:owned, queue}
    end)
  end

  def forget_page(state, {_, scope} = key) do
    update_scope(state, scope, fn scope ->
      work =
        Map.new(scope.work, fn {queue, work} ->
          {queue, %{work | pages: MapSet.delete(work.pages, key)}}
        end)

      %{scope | work: work}
    end)
  end

  def take_idle_pages(state, name) do
    scope = get_scope(state, name)
    run = {name, generation(state, name)}

    {work, pages} =
      Enum.reduce(scope.work, {%{}, MapSet.new()}, &take_idle_queue(state, run, &1, &2))

    {pages, %{state | scopes: Map.put(state.scopes, name, %{scope | work: work})}}
  end

  defp take_idle_queue(
         state,
         run,
         {queue, %Work{pending: 0, inflight: 0} = work},
         {queues, pages}
       )
       when is_pid(queue) or is_nil(queue) do
    if Crawler.Frontier.queue_pending(state.scheduler.frontier, run, queue) == 0 do
      {Map.put(queues, queue, %{work | pages: MapSet.new()}), MapSet.union(pages, work.pages)}
    else
      {Map.put(queues, queue, work), pages}
    end
  end

  defp take_idle_queue(_state, _run, {queue, work}, {queues, pages}),
    do: {Map.put(queues, queue, work), pages}

  def drop_scope(state, scope) do
    {waiters, state} = clear_scope_caches(state, scope)
    {waiters, %{state | scopes: Map.delete(state.scopes, scope)}}
  end

  def clear_scope_caches(state, scope) do
    waiters =
      state.robots
      |> Map.get(scope, %{})
      |> Map.values()
      |> Enum.flat_map(&loading_waiters/1)

    {waiters,
     %{
       state
       | cookies: Map.delete(state.cookies, scope),
         robots: Map.delete(state.robots, scope),
         cookie_outcomes: Map.delete(state.cookie_outcomes, scope),
         cookie_bytes:
           state.cookie_bytes - Crawler.Cookies.Jar.retained_cost(state.cookies[scope])
     }}
  end

  def save_cookies(state, scope, url, headers, generation, context) do
    case CookieProof.save(state, scope, url, headers, generation, context, :unbound) do
      {{:ok, _}, state} -> state
      _ -> state
    end
  end

  def cookie_header(state, scope, url, generation, context) do
    case CookieProof.snapshot(state, scope, url, generation, context, :unbound) do
      {{:ok, header, _}, state} -> {header, state}
      _ -> {nil, state}
    end
  end

  def claim_robots(state, scope, origin, from, pid, queue) do
    case robot(state, scope, origin) do
      {:ready, rules} ->
        {{:reply, {:ready, rules}}, state}

      {:loading, ref, owner, owner_queue, waiters} ->
        entry = {:loading, ref, owner, owner_queue, [{from, queue} | waiters]}
        {{:noreply, :wait}, put_robot(state, scope, origin, entry)}

      nil ->
        ref = Process.monitor(pid)
        {{:reply, :owner}, put_robot(state, scope, origin, {:loading, ref, pid, queue, []})}
    end
  end

  def finish_robots(state, scope, origin, rules, pid, queue) do
    case robot(state, scope, origin) do
      {:loading, ref, ^pid, ^queue, waiters} ->
        Process.demonitor(ref, [:flush])
        {waiters, put_robot(state, scope, origin, {:ready, rules})}

      _ ->
        {[], state}
    end
  end

  def forget_robots(state, scope, origin, pid, queue) do
    case robot(state, scope, origin) do
      {:loading, ref, ^pid, ^queue, waiters} ->
        Process.demonitor(ref, [:flush])
        {waiters, delete_robot(state, scope, origin)}

      _ ->
        {[], state}
    end
  end

  def forget_robots_owner(state, scope, pid, queue) do
    Enum.reduce(Map.get(state.robots, scope, %{}), {[], state}, fn
      {origin, {:loading, _ref, ^pid, ^queue, _waiters}}, {replies, state} ->
        {waiters, state} = forget_robots(state, scope, origin, pid, queue)
        {waiters ++ replies, state}

      _, result ->
        result
    end)
  end

  def retire_robots_queue(state, queue) do
    Enum.reduce(state.robots, {[], state}, fn {scope, origins}, acc ->
      Enum.reduce(origins, acc, &retire_robot_queue(&1, &2, scope, queue))
    end)
  end

  def robots_down(state, ref) do
    Enum.find_value(state.robots, {[], state}, fn {scope, origins} ->
      Enum.find_value(origins, fn
        {origin, {:loading, ^ref, _pid, _queue, waiters}} ->
          state = delete_robot(state, scope, origin)
          {waiters, state}

        _ ->
          nil
      end)
    end)
  end

  defp retire_robot_queue(
         {origin, {:loading, ref, _pid, queue, waiters}},
         {replies, state},
         scope,
         queue
       ) do
    Process.demonitor(ref, [:flush])
    {waiters ++ replies, delete_robot(state, scope, origin)}
  end

  defp retire_robot_queue(
         {origin, {:loading, ref, pid, owner_queue, waiters}},
         {replies, state},
         scope,
         queue
       ) do
    {retired, kept} =
      Enum.split_with(waiters, fn {_from, waiting_queue} -> waiting_queue == queue end)

    {retired ++ replies, put_robot(state, scope, origin, {:loading, ref, pid, owner_queue, kept})}
  end

  defp retire_robot_queue(_entry, acc, _scope, _queue), do: acc

  defp loading_waiters({:loading, ref, _pid, _queue, waiters}) do
    Process.demonitor(ref, [:flush])
    waiters
  end

  defp loading_waiters(_entry), do: []

  defp robot(state, scope, origin), do: get_in(state.robots, [scope, origin])

  defp put_robot(state, scope, origin, entry) do
    origins = Map.get(state.robots, scope, %{})
    %{state | robots: Map.put(state.robots, scope, Map.put(origins, origin, entry))}
  end

  defp delete_robot(state, scope, origin) do
    origins = state.robots |> Map.get(scope, %{}) |> Map.delete(origin)
    %{state | robots: Map.put(state.robots, scope, origins)}
  end

  def attach_owner(state, feeder, owner, scope) do
    %{state | owners: Map.put(state.owners, feeder, %{owner: owner, scope: scope})}
  end

  def queue_record(state, queue), do: Map.get(state.owners, queue)

  def queue_scopes(state, queue) do
    for {name, scope} <- state.scopes, Map.has_key?(scope.work, queue), do: name
  end

  def release_queue(state, queue) do
    {scopes, pages} =
      Enum.reduce(state.scopes, {%{}, MapSet.new()}, fn {name, scope}, {scopes, pages} ->
        attached? = Map.has_key?(scope.work, queue)
        {scope, removed} = release_scope_queue(scope, queue)

        scopes =
          if attached? and scope.work == %{} and scope.ops == 0,
            do: scopes,
            else: Map.put(scopes, name, scope)

        {scopes, MapSet.union(pages, removed)}
      end)

    state = %{
      state
      | scopes: scopes,
        owners: Map.delete(state.owners, queue),
        closing: MapSet.put(state.closing, queue)
    }

    {pages, state}
  end

  defp release_scope_queue(scope, queue) do
    case Map.pop(scope.work, queue) do
      {nil, _work} ->
        {scope, MapSet.new()}

      {removed, work} ->
        revision = if map_size(work) == 0, do: make_ref(), else: scope.revision
        timer = if map_size(work) == 0, do: nil, else: scope.run_timer
        {%{scope | work: work, revision: revision, run_timer: timer}, removed.pages}
    end
  end

  defp get_scope(state, scope), do: Map.get(state.scopes, scope, %Scope{})

  defp update_scope(state, scope, fun) do
    %{
      state
      | scopes:
          Map.put(state.scopes, scope, fun.(Map.get_lazy(state.scopes, scope, &Scope.new/0)))
    }
  end

  defp update_work(state, scope, queue, fun) do
    update_scope(state, scope, fn scope ->
      work = fun.(Map.get(scope.work, queue, %Work{}))
      %{scope | work: Map.put(scope.work, queue, work)}
    end)
  end

  defp budget_status(state, scope, limit) do
    Budget.status(count(state, :ops, scope), count(state, :inflight, scope), limit)
  end
end
