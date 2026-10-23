defmodule Crawler.Store.ResourceManager do
  @moduledoc false

  alias Crawler.Frontier
  alias Crawler.Store.Authority
  alias Crawler.Store.DB
  alias Crawler.Store.Page
  alias Crawler.Store.Resources
  alias Crawler.Store.State

  def envelope(opts), do: max(2 * opts.max_body, opts.max_body + opts.max_analysis_bytes) + 65_536

  def releasable?(state),
    do:
      state.resources.open_arenas > 0 or state.resources.pending_grants > 0 or
        Crawler.Frontier.Ring.size(state.retiring_runs) > 0

  def options(state, opts) do
    bytes = Frontier.bytes(state.scheduler.frontier)
    key = {opts[:scope], opts[:generation]}
    run = Frontier.bytes(state.scheduler.frontier, key)
    run_bytes = run.metadata_bytes + run.payload_bytes

    Map.merge(opts, %{
      external_frontier_bytes:
        bytes.metadata + bytes.payload +
          state.waiting_bytes + state.cookie_bytes + state.export_bytes + state.source_cache_bytes,
      external_run_bytes:
        run_bytes + Crawler.Cookies.Jar.retained_cost(state.cookies[opts[:scope]]) +
          Map.get(state.source_cache_run_bytes, key, 0) +
          case state.exports[key] do
            nil -> 0
            export -> export.reserved_bytes
          end
    })
  end

  def owner_needed?(state, receipt),
    do:
      MapSet.member?(state.source_resources, receipt) or
        MapSet.member?(state.persistent_resources, receipt) or
        Map.get(state.source_cache_resources, receipt, 0) > 0 or
        Map.get(state.export_io_resources, receipt, 0) > 0

  def release_owner(state, receipt) do
    cond do
      MapSet.member?(state.source_resources, receipt) or
        MapSet.member?(state.persistent_resources, receipt) or
          Map.get(state.source_cache_resources, receipt, 0) > 0 ->
        state

      Map.get(state.export_io_resources, receipt, 0) > 0 ->
        Crawler.Store.ExportIO.defer_owner_release(state, receipt)

      true ->
        elem(transition(state, Resources.release(state.resources, receipt, self())), 1)
    end
  end

  def page_receipts(opts) when is_map(opts),
    do:
      [opts[:page_resource], opts[:body_resource]] |> Enum.filter(&is_reference/1) |> MapSet.new()

  def page_receipts(_opts), do: MapSet.new()

  def remove_page(state, {_, scope} = key) do
    refs =
      case Registry.lookup(DB, key) do
        [{_, %Page{opts: opts}}] -> page_receipts(opts)
        _ -> MapSet.new()
      end

    Registry.unregister(DB, key)
    state = if Map.has_key?(state.scopes, scope), do: State.forget_page(state, key), else: state
    Enum.reduce(refs, state, &release_persistent(&2, &1))
  end

  def retain_persistent(state, receipt, scope, role \\ :ordinary)
      when role in [:ordinary, :issued] do
    {:ok, state} = transition(state, Resources.adopt(state.resources, receipt, self()))
    counts = Map.get(state.persistent_counts, receipt, {0, 0})
    state = put_persistent_counts(state, receipt, increment_persistent(counts, role))

    if role == :ordinary do
      %{
        state
        | retained_pages:
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
  end

  def release_persistent(state, receipt, role \\ :ordinary)
      when role in [:ordinary, :issued] do
    case {state.persistent_counts[receipt], role} do
      {{ordinary, issued}, :ordinary} when ordinary > 0 ->
        put_persistent_counts(state, receipt, {ordinary - 1, issued})

      {{ordinary, issued}, :issued} when issued > 0 ->
        put_persistent_counts(state, receipt, {ordinary, issued - 1})

      _ ->
        state
    end
  end

  def drop_ordinary(state, receipt) do
    case state.persistent_counts[receipt] do
      {_ordinary, issued} -> put_persistent_counts(state, receipt, {0, issued})
      nil -> release_owner(state, receipt)
    end
  end

  defp increment_persistent({ordinary, issued}, :ordinary), do: {ordinary + 1, issued}
  defp increment_persistent({ordinary, issued}, :issued), do: {ordinary, issued + 1}

  defp put_persistent_counts(state, receipt, {ordinary, issued} = counts) do
    retained =
      case {ordinary, Resources.receipt(state.resources, receipt)} do
        {0, %{run: {scope, _}}} -> forget_retained(state.retained_pages, scope, receipt)
        _ -> state.retained_pages
      end

    if ordinary + issued == 0 do
      state = %{
        state
        | retained_pages: retained,
          persistent_counts: Map.delete(state.persistent_counts, receipt),
          persistent_resources: MapSet.delete(state.persistent_resources, receipt)
      }

      release_owner(state, receipt)
    else
      %{
        state
        | retained_pages: retained,
          persistent_counts: Map.put(state.persistent_counts, receipt, counts),
          persistent_resources: MapSet.put(state.persistent_resources, receipt)
      }
    end
  end

  defp forget_retained(retained, scope, receipt) do
    case retained[scope] do
      nil ->
        retained

      ring ->
        ring = Crawler.Frontier.Ring.delete(ring, receipt)

        if Crawler.Frontier.Ring.size(ring) == 0,
          do: Map.delete(retained, scope),
          else: Map.put(retained, scope, ring)
    end
  end

  def credit(state), do: effect(:credit, state)

  def transition(state, {reply, resources, effects}) do
    state = %{state | resources: resources}
    state = Enum.reduce(effects, state, &effect/2)
    {reply, state}
  end

  def holder_down(state, pid) do
    {result, state} = transition(state, Resources.holder_down(state.resources, pid, 32))
    if match?({:more, _}, result), do: send(self(), {:release_resource_holder, pid})
    state
  end

  defp effect({:monitor, pid}, state) do
    if Map.has_key?(state.resource_monitors, pid) do
      state
    else
      ref = Process.monitor(pid)

      %{
        state
        | resource_monitors: Map.put(state.resource_monitors, pid, ref),
          resource_refs: Map.put(state.resource_refs, ref, pid)
      }
    end
  end

  defp effect({:demonitor, pid}, state) do
    case Map.pop(state.resource_monitors, pid) do
      {nil, _} ->
        state

      {ref, monitors} ->
        Process.demonitor(ref, [:flush])

        %{
          state
          | resource_monitors: monitors,
            resource_refs: Map.delete(state.resource_refs, ref)
        }
    end
  end

  defp effect({:put_arena, arena, lease, executor, run}, state) do
    Authority.put_arena(arena, lease, executor, run)
    state
  end

  defp effect({:put_grant, ref, lease, pid, run, arena}, state) do
    Authority.put_resource(ref, lease, pid, run, arena)
    state
  end

  defp effect({:delete_grant, ref, pid}, state) do
    Authority.delete_resource(ref, pid)
    send(self(), {:resource_delivery_consumed, ref, pid})
    state
  end

  defp effect({:revoke_arena, arena}, state) do
    Authority.revoke_arena(arena)
    state
  end

  defp effect({:drop_arena, arena}, state) do
    Authority.delete_arena(arena)
    state
  end

  defp effect({:revoke_run, run}, state) do
    if state.resources.runs[run],
      do: Authority.revoke_resource_run(run),
      else: Authority.delete_resource_run(run)

    state
  end

  defp effect({:drop_run, run}, state) do
    Authority.delete_resource_run(run)
    state
  end

  defp effect({:abandon, pid, ref, lease}, state) do
    send(pid, {:crawler_resource_abandon, ref, lease})
    state
  end

  defp effect(:credit, %{resource_credit_scheduled?: true} = state), do: state

  defp effect(:credit, state) do
    send(self(), :resource_credit)
    %{state | resource_credit_scheduled?: true}
  end
end
