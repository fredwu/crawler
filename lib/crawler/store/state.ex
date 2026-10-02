defmodule Crawler.Store.State do
  @moduledoc false

  alias Crawler.Store.Budget
  alias Crawler.Store.Claims
  alias Crawler.Store.Scope
  alias Crawler.Store.Settlements
  alias Crawler.Store.Work

  defstruct scopes: %{},
            owners: %{},
            closing: MapSet.new(),
            monitors: %{},
            claims: %Claims{},
            settlements: %Settlements{}

  def generation(state, scope), do: get_scope(state, scope).generation

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
    update_scope(state, scope, &%Scope{generation: &1.generation + 1})
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
        generation = if map_size(work) == 0, do: scope.generation + 1, else: scope.generation
        {%{scope | work: work, generation: generation}, removed.pages}
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
