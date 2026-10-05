defmodule Crawler.Store.State do
  @moduledoc false

  alias Crawler.Cookies
  alias Crawler.Store.Budget
  alias Crawler.Store.Claims
  alias Crawler.Store.Scope
  alias Crawler.Store.Settlements
  alias Crawler.Store.Work

  @enforce_keys [:incarnation]
  defstruct incarnation: nil,
            scopes: %{},
            owners: %{},
            closing: MapSet.new(),
            monitors: %{},
            claims: %Claims{},
            settlements: %Settlements{},
            cookies: %{},
            robots: %{}

  def new, do: %__MODULE__{incarnation: make_ref()}

  def generation(state, scope), do: {state.incarnation, get_scope(state, scope).revision}

  def current?(_state, _scope, nil), do: true
  def current?(state, scope, generation), do: generation(state, scope) == generation

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

  def deferred_scopes(state) do
    for {name, _scope} <- state.scopes, deferred?(state, name), do: name
  end

  def deferred?(state, scope) do
    state
    |> get_scope(scope)
    |> Map.fetch!(:work)
    |> Map.values()
    |> Enum.any?(fn work -> not :queue.is_empty(work.deferred) end)
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

  def start_work(state, opts) do
    scope = opts[:scope]
    queue = opts[:queue]

    case budget_status(state, scope, opts[:max_pages]) do
      :ok ->
        {:ok, increment(state, :inflight, scope, queue)}

      :wait when is_pid(queue) ->
        {:deferred, update_work(state, scope, queue, &Work.defer(&1, opts))}

      _full ->
        {:full, state}
    end
  end

  def resume_deferred(state, scope_name) do
    scope = get_scope(state, scope_name)
    inflight = count(state, :inflight, scope_name)

    {work, events, _count} =
      Enum.reduce(scope.work, {%{}, [], 0}, fn {queue, work}, {work_by_queue, events, count} ->
        {work, ready, count} = Work.resume(work, scope.ops, inflight, count)
        {Map.put(work_by_queue, queue, work), [ready | events], count}
      end)

    state = %{state | scopes: Map.put(state.scopes, scope_name, %{scope | work: work})}
    {events |> Enum.reverse() |> List.flatten(), state}
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

    {work, pages} =
      Enum.reduce(scope.work, {%{}, MapSet.new()}, fn
        {queue, %Work{pending: 0, inflight: 0} = work}, {queues, pages} when is_pid(queue) ->
          {Map.put(queues, queue, %{work | pages: MapSet.new()}), MapSet.union(pages, work.pages)}

        {queue, work}, {queues, pages} ->
          {Map.put(queues, queue, work), pages}
      end)

    {pages, %{state | scopes: Map.put(state.scopes, name, %{scope | work: work})}}
  end

  def drop_scope(state, scope) do
    waiters =
      state.robots
      |> Map.get(scope, %{})
      |> Map.values()
      |> Enum.flat_map(&loading_waiters/1)

    state =
      state
      |> update_scope(scope, &%Scope{revision: &1.revision + 1})
      |> Map.update!(:cookies, &Map.delete(&1, scope))
      |> Map.update!(:robots, &Map.delete(&1, scope))

    {waiters, state}
  end

  def save_cookies(state, nil, _url, _headers, _generation), do: state

  def save_cookies(state, scope, url, headers, generation) do
    if current?(state, scope, generation) do
      jar = Cookies.store(Map.get(state.cookies, scope, []), url, headers)
      %{state | cookies: Map.put(state.cookies, scope, jar)}
    else
      state
    end
  end

  def cookie_header(_state, nil, _url, _generation), do: nil

  def cookie_header(state, scope, url, generation) do
    if current?(state, scope, generation) do
      state.cookies
      |> Map.get(scope, [])
      |> Cookies.header(url)
    end
  end

  def claim_robots(state, scope, origin, from, pid) do
    case robot(state, scope, origin) do
      {:ready, rules} ->
        {{:reply, {:ready, rules}}, state}

      {:loading, ref, owner, waiters} ->
        entry = {:loading, ref, owner, [from | waiters]}
        {{:noreply, :wait}, put_robot(state, scope, origin, entry)}

      nil ->
        ref = Process.monitor(pid)
        {{:reply, :owner}, put_robot(state, scope, origin, {:loading, ref, pid, []})}
    end
  end

  def finish_robots(state, scope, origin, rules, pid) do
    case robot(state, scope, origin) do
      {:loading, ref, ^pid, waiters} ->
        Process.demonitor(ref, [:flush])
        {waiters, put_robot(state, scope, origin, {:ready, rules})}

      _ ->
        {[], state}
    end
  end

  def forget_robots(state, scope, origin, pid) do
    case robot(state, scope, origin) do
      {:loading, ref, ^pid, waiters} ->
        Process.demonitor(ref, [:flush])
        {waiters, delete_robot(state, scope, origin)}

      _ ->
        {[], state}
    end
  end

  def robots_down(state, ref) do
    Enum.find_value(state.robots, {[], state}, fn {scope, origins} ->
      Enum.find_value(origins, fn
        {origin, {:loading, ^ref, _pid, waiters}} ->
          state = delete_robot(state, scope, origin)
          {waiters, state}

        _ ->
          nil
      end)
    end)
  end

  defp loading_waiters({:loading, ref, _pid, waiters}) do
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
        {scope, removed} = release_scope_queue(scope, queue)
        {Map.put(scopes, name, scope), MapSet.union(pages, removed)}
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
        revision = if map_size(work) == 0, do: scope.revision + 1, else: scope.revision
        {%{scope | work: work, revision: revision}, removed.pages}
    end
  end

  defp get_scope(state, scope), do: Map.get(state.scopes, scope, %Scope{})

  defp update_scope(state, scope, fun) do
    %{state | scopes: Map.put(state.scopes, scope, fun.(get_scope(state, scope)))}
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
