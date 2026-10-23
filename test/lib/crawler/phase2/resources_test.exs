defmodule Crawler.Phase2.ResourcesTest do
  use ExUnit.Case, async: true

  alias Crawler.Store.Resources

  test "a complete envelope is atomic and contention is distinct from an impossible envelope" do
    lease = make_ref()
    cost = Resources.arena_cost(:one, lease, self(), 60_000)
    state = Resources.new(max_retained_bytes: cost)
    {{:ok, arena}, state, _} = Resources.acquire(state, :one, lease, self(), 60_000)
    assert Resources.bytes(state) == cost

    assert {{:blocked, :resource_credit}, ^state, []} =
             Resources.acquire(state, :two, make_ref(), self(), 20_000)

    assert {{:limited, :pipeline_envelope}, ^state, []} =
             Resources.acquire(state, :two, make_ref(), self(), cost)

    {{:ok, ref}, state, _} = Resources.reserve(state, arena, lease, :response, 40_000)
    assert {:ok, state, []} = Resources.commit(state, ref, lease, 40_000)
    assert Resources.bytes(state) == cost
    assert_accounted(state)
  end

  test "invalid response copy charges are inert typed failures and leave fresh commits usable" do
    {state, arena, lease} = arena(100_000, 120_000)
    {{:ok, ref}, state, _} = Resources.reserve(state, arena, lease, :response, 1024)

    for {actual, copy} <- [{256, 320}, {-1, 0}, {256, -1}, {"256", 1}, {256, nil}] do
      assert {{:error, :invalid_response_charge}, ^state, []} =
               Resources.commit_response(state, ref, lease, actual, copy)
    end

    assert {:ok, state, []} = Resources.commit_response(state, ref, lease, 320, 320)
    assert Resources.receipt(state, ref).actual == 320
    assert Resources.receipt(state, ref).copy_bytes == 320
    assert_accounted(state)
  end

  test "suballocation never requests global credit after the response is held" do
    {state, arena, lease} = arena(100_000, 120_000)
    {{:ok, body}, state, _} = Resources.reserve(state, arena, lease, :response, 30_000)
    {:ok, state, []} = Resources.commit(state, body, lease, 25_000)
    before = Resources.bytes(state)
    {{:ok, analysis}, state, _} = Resources.reserve(state, arena, lease, :analysis, 30_000)
    assert Resources.bytes(state) == before

    assert {{:error, {:limit, :arena_capacity}}, ^state, []} =
             Resources.reserve(state, arena, lease, :decoded, 80_000)

    {:ok, state, []} = Resources.commit(state, analysis, lease, 1_000)
    assert_accounted(state)
  end

  test "partial reservation funds both receipt holders before returning its exact capacity" do
    cache = holder()
    {state, arena, lease} = arena(100_000, 120_000)
    before = Resources.bytes(state)

    {{:ok, ref, capacity}, state, _} =
      Resources.reserve_up_to(state, arena, lease, :analysis, 100_000, cache)

    assert capacity > 0 and capacity < 100_000
    assert Resources.bytes(state) == before
    assert state.arenas[arena].free == 0
    assert Resources.receipt(state, ref).capacity == capacity
    assert Resources.current?(state, ref, lease, self())
    assert Resources.current?(state, ref, lease, cache)
    assert_accounted(state)

    assert {{:error, {:limit, :arena_capacity}}, ^state, []} =
             Resources.reserve_up_to(state, arena, lease, :analysis, 0)

    {:ok, state, []} = Resources.commit(state, ref, lease, 1_000)
    assert state.arenas[arena].free == capacity - 1_000
    assert Resources.bytes(state) == before
    assert_accounted(state)
    {:ok, state, _} = Resources.adopt(state, ref, cache)
    state = state |> drain(self(), 100) |> drain(cache, 100)
    assert_empty(state)
  end

  test "a persistent external transfer consumes existing arena credit without double counting" do
    {state, arena, lease} = arena()
    before = Resources.bytes(state)
    {:ok, state, []} = Resources.transfer_external(state, arena, lease, 25_000)
    assert Resources.bytes(state) + 25_000 == before
    assert state.arenas[arena].free == 75_000
    assert_accounted(state)

    assert {{:error, {:limit, :arena_capacity}}, ^state, []} =
             Resources.transfer_external(state, arena, lease, 75_001)

    {{:ok, receipt, 50_000}, state, _} =
      Resources.reserve_up_to(state, arena, lease, :response, 50_000)

    {:ok, state, _} = Resources.commit(state, receipt, lease, 1_000)
    {:ok, state, _} = Resources.close(state, arena)

    assert {{:error, :stale}, ^state, []} =
             Resources.transfer_external(state, arena, lease, 0)

    {:ok, state, _} = Resources.release(state, receipt, self())
    assert_empty(state)
  end

  test "commit cannot exceed its receipt or release live backing" do
    {state, arena, lease} = arena()
    {{:ok, ref}, state, _} = Resources.reserve(state, arena, lease, :response, 12_000)

    assert {{:error, {:limit, :receipt_capacity}}, ^state, []} =
             Resources.commit(state, ref, lease, 12_001)

    {:ok, state, []} = Resources.commit(state, ref, lease, 10_000)
    {:ok, state, _} = Resources.close(state, arena)
    assert Resources.bytes(state) > 10_000
    assert Resources.receipt(state, ref).actual == 10_000
    assert {{:error, :stale}, ^state, []} = Resources.commit(state, ref, lease, 0)
    {:ok, state, _} = Resources.release(state, ref, self())
    assert_empty(state)
  end

  test "adopted cache and source survive retirement and executor release" do
    cache = holder()
    source = holder()
    {state, arena, lease} = arena()
    {{:ok, ref}, state, _} = Resources.reserve(state, arena, lease, :source, 10_000, cache)
    {:ok, state, _} = Resources.adopt(state, ref, cache)
    {:ok, state, []} = Resources.commit(state, ref, lease, 9_000)
    {:ok, state, _} = Resources.retain(state, ref, lease, self(), source)
    {:ok, state, _} = Resources.adopt(state, ref, source)
    before = Resources.bytes(state)
    {:ok, state, [{:revoke_run, :run}]} = Resources.retire_run(state, :run)
    assert Resources.bytes(state) == before
    refute Resources.current?(state, ref, lease, cache)
    {{:done, _}, state, effects} = Resources.release_holder(state, self())
    refute Enum.any?(effects, &match?({:abandon, _, _, _}, &1))
    assert Resources.receipt(state, ref).actual == 9_000
    assert_accounted(state)
    {:ok, state, _} = Resources.release(state, ref, cache)
    assert Resources.receipt(state, ref)
    {:ok, state, _} = Resources.release(state, ref, source)
    assert_empty(state)
  end

  test "pre-send executor death keeps a cache grant charged until abandonment settles" do
    cache = holder()
    {state, arena, lease} = arena()

    {{:ok, ref}, state, effects} =
      Resources.reserve(state, arena, lease, :css_snapshot, 11_000, cache)

    assert {:put_grant, ref, lease, cache, :run, arena} in effects
    {{:done, _}, state, effects} = Resources.holder_down(state, self())
    assert {:abandon, cache, ref, lease} in effects

    assert Enum.find_index(effects, &(&1 == {:delete_grant, ref, cache})) <
             Enum.find_index(effects, &(&1 == {:abandon, cache, ref, lease}))

    assert Resources.bytes(state) > 11_000
    assert Resources.receipt(state, ref).holders[cache].status == :abandoned
    refute Resources.current?(state, ref, lease, cache)
    {:ok, state, _} = Resources.settle(state, ref, cache, :released)
    assert_empty(state)
    assert {{:error, :unknown_grant}, ^state, []} = Resources.adopt(state, ref, cache)
  end

  test "registration sent before executor death can report retained after the probe" do
    cache = holder()
    {state, arena, lease} = arena()
    {{:ok, ref}, state, _} = Resources.reserve(state, arena, lease, :css_snapshot, 9_000, cache)
    {:ok, state, []} = Resources.commit(state, ref, lease, 8_000)
    {{:done, _}, state, _} = Resources.holder_down(state, self())
    before = Resources.bytes(state)
    {:ok, state, []} = Resources.settle(state, ref, cache, :retained)
    assert Resources.bytes(state) == before
    refute Resources.current?(state, ref, lease, cache)
    {{:done, _}, state, _} = Resources.holder_down(state, cache)
    assert_empty(state)
  end

  test "cache-owner DOWN releases charge with run authority already revoked" do
    cache = holder()
    {state, arena, lease} = arena()
    {{:ok, ref}, state, _} = Resources.reserve(state, arena, lease, :css_facts, 3_000, cache)
    {:ok, state, _} = Resources.retire_run(state, :run)
    {{:done, _}, state, _} = Resources.holder_down(state, self())
    {{:done, _}, state, _} = Resources.holder_down(state, cache)
    assert_empty(state)
    assert {{:error, :unknown_grant}, ^state, []} = Resources.release(state, ref, cache)
  end

  test "holder cleanup visits only a bounded number of indexed entries" do
    cache = holder()
    {state, arena, lease} = arena(1_000_000, 2_000_000)

    state =
      Enum.reduce(1..30, state, fn _, state ->
        {{:ok, ref}, state, _} = Resources.reserve(state, arena, lease, :analysis, 1, cache)
        {:ok, state, _} = Resources.adopt(state, ref, cache)
        state
      end)

    {{:done, _}, state, _} = Resources.holder_down(state, self(), 100)
    before = Resources.stats(state).visited
    {{:more, 7}, state, effects} = Resources.holder_down(state, cache, 7)
    assert Resources.stats(state).visited - before == 7
    assert Resources.holder_size(state, cache) == 23
    assert Enum.count(effects, &(&1 == :credit)) == 1
    refute Resources.current?(state, hd(Map.keys(state.receipts)), lease, cache)
    state = drain(state, cache, 7)
    assert_empty(state)
  end

  test "one holder DOWN does not scan many unrelated receipts" do
    cache = holder()
    unrelated = holder()
    {state, arena, lease} = arena(5_000_000, 6_000_000)

    state =
      Enum.reduce(1..200, state, fn _, state ->
        {{:ok, ref}, state, _} = Resources.reserve(state, arena, lease, :source, 1, unrelated)
        {:ok, state, _} = Resources.adopt(state, ref, unrelated)
        state
      end)

    {{:ok, ref}, state, _} = Resources.reserve(state, arena, lease, :snapshot, 5, cache)
    before = Resources.stats(state).visited
    {{:done, 1}, state, _} = Resources.holder_down(state, cache, 1)
    assert Resources.stats(state).visited == before + 1
    assert map_size(state.receipts) == 201
    assert Resources.receipt(state, ref).holders[self()]
    assert Resources.holder_size(state, unrelated) == 200
    assert_accounted(state)
  end

  test "a small unrelated scope fits while a larger envelope is blocked" do
    {state, _arena, _lease} = arena(70_000, 110_000)

    assert {{:blocked, :resource_credit}, ^state, []} =
             Resources.acquire(state, :large, make_ref(), self(), 40_000)

    {{:ok, _}, state, _} = Resources.acquire(state, :small, make_ref(), self(), 5_000)
    assert Resources.bytes(state) <= state.limit
    assert_accounted(state)
  end

  test "external frontier bytes count globally and terminal metadata cannot consume production headroom" do
    state = Resources.new(max_retained_bytes: 100_000)

    assert {:limited, :production_headroom} =
             Resources.admission(state, :run, 20_000, 20_000, external_frontier_bytes: 70_000)

    assert :ok = Resources.admission(state, :run, 5_000, 20_000, external_frontier_bytes: 60_000)

    assert {{:limited, :production_headroom}, ^state, []} =
             Resources.acquire(state, :run, make_ref(), self(), 40_000,
               external_frontier_bytes: 60_000
             )

    assert Resources.capacity(state, :run, external_frontier_bytes: 60_000).global == 40_000
  end

  test "the normalized per-run cap and per-run external bytes apply independently of global capacity" do
    state = Resources.new(max_retained_bytes: 1_000_000)
    lease = make_ref()

    assert {{:limited, :pipeline_envelope}, ^state, []} =
             Resources.acquire(state, :run, lease, self(), 80_000, max_retained_bytes: 50_000)

    {{:ok, _}, state, _} =
      Resources.acquire(state, :run, lease, self(), 30_000, max_retained_bytes: 80_000)

    assert {{:blocked, :resource_credit}, ^state, []} =
             Resources.acquire(state, :run, make_ref(), self(), 50_000,
               max_retained_bytes: 1_000_000
             )

    assert {{:limited, :production_headroom}, ^state, []} =
             Resources.acquire(state, :run, make_ref(), self(), 30_000,
               external_run_bytes: 50_000
             )
  end

  test "retaining shared snapshot backing funds metadata from its arena and retains all holders" do
    cache = holder()
    snapshot = holder()
    {state, arena, lease} = arena()
    {{:ok, ref}, state, _} = Resources.reserve(state, arena, lease, :css_snapshot, 10_000, cache)
    {:ok, state, []} = Resources.commit(state, ref, lease, 8_000)
    {:ok, state, _} = Resources.adopt(state, ref, cache)
    before = Resources.bytes(state)
    {:ok, state, _} = Resources.retain(state, ref, lease, self(), snapshot)
    assert Resources.bytes(state) == before
    {:ok, state, _} = Resources.adopt(state, ref, snapshot)
    {{:done, _}, state, _} = Resources.holder_down(state, self())
    {:ok, state, _} = Resources.release(state, ref, cache)
    assert Resources.bytes(state) > 8_000
    {:ok, state, _} = Resources.release(state, ref, snapshot)
    assert_empty(state)
  end

  test "a new arena can retain cache backing after its creating run and arena end" do
    cache = holder()
    consumer = holder()
    {state, arena, lease} = arena()
    {{:ok, ref}, state, _} = Resources.reserve(state, arena, lease, :source, 10_000, cache)
    {:ok, state, []} = Resources.commit(state, ref, lease, 8_000)
    {:ok, state, _} = Resources.adopt(state, ref, cache)
    {:ok, state, _} = Resources.retire_run(state, :run)
    {{:done, _}, state, _} = Resources.holder_down(state, self())
    next_lease = make_ref()
    {{:ok, next_arena}, state, _} = Resources.acquire(state, :next, next_lease, consumer, 100_000)

    {:ok, state, effects} =
      Resources.retain_from(state, ref, next_arena, next_lease, cache, consumer)

    assert {:put_grant, ref, next_lease, consumer, :next, next_arena} in effects
    assert Resources.current?(state, ref, next_lease, consumer)
    {:ok, state, _} = Resources.adopt(state, ref, consumer)
    {{:done, _}, state, _} = Resources.holder_down(state, cache)
    assert Resources.receipt(state, ref)
    assert_accounted(state)
    {{:done, _}, state, _} = Resources.holder_down(state, consumer)
    assert_empty(state)
  end

  test "same-run arenas keep one original backing charge through every holder" do
    cache = holder()
    consumer = holder()
    recipient = holder()
    {state, arena, lease} = arena(300_000)
    {{:ok, ref}, state, _} = Resources.reserve(state, arena, lease, :response, 200_000, cache)
    {:ok, state, _} = Resources.commit_response(state, ref, lease, 200_000, 512)
    {:ok, state, _} = Resources.adopt(state, ref, cache)
    next_lease = make_ref()
    {{:ok, next}, state, _} = Resources.acquire(state, :run, next_lease, consumer, 30_000)

    {:ok, state, _} =
      Resources.retain_from(state, ref, next, next_lease, cache, consumer, :backing)

    {:ok, state, _} = Resources.adopt(state, ref, consumer)

    {:ok, state, _} =
      Resources.retain_from(state, ref, next, next_lease, consumer, recipient, :backing)

    {:ok, state, _} = Resources.adopt(state, ref, recipient)
    assert state.arenas[next].free > 0
    {:ok, state, _} = Resources.retire_run(state, :run)
    state = state |> drain(self(), 100) |> drain(cache, 100) |> drain(consumer, 100)
    assert Resources.receipt(state, ref).actual == 200_000
    assert Resources.bytes(state) >= 200_000
    assert_accounted(state)
    state = drain(state, recipient, 100)
    assert_empty(state)
  end

  test "unknown grant recovery does not create tombstones or new holder entries" do
    state = Resources.new()
    unknown = make_ref()

    assert {{:error, :unknown_grant}, ^state, []} =
             Resources.settle(state, unknown, self(), :retained)

    assert {{:done, 0}, ^state, []} = Resources.holder_down(state, self(), 1)
    assert_empty(state)
  end

  test "cross-arena cleanup preserves counters for every holder release order" do
    cache = holder()
    consumer = holder()

    orders = [
      [self(), cache, consumer],
      [self(), consumer, cache],
      [cache, self(), consumer],
      [cache, consumer, self()],
      [consumer, self(), cache],
      [consumer, cache, self()]
    ]

    for order <- orders do
      {state, arena, lease} = arena()
      {{:ok, ref}, state, _} = Resources.reserve(state, arena, lease, :source, 9_000, cache)
      {:ok, state, _} = Resources.adopt(state, ref, cache)
      next_lease = make_ref()
      {{:ok, next}, state, _} = Resources.acquire(state, :run, next_lease, consumer, 50_000)
      {:ok, state, _} = Resources.retain_from(state, ref, next, next_lease, cache, consumer)
      {:ok, state, _} = Resources.adopt(state, ref, consumer)

      state =
        Enum.reduce(order, state, fn pid, state ->
          state = drain(state, pid, 1)
          assert_accounted(state)
          state
        end)

      assert_empty(state)
    end
  end

  test "a retained abandonment reply does not restore revoked insertion authority" do
    cache = holder()
    consumer = holder()
    {state, arena, lease} = arena()
    {{:ok, ref}, state, _} = Resources.reserve(state, arena, lease, :source, 9_000, cache)
    {:ok, state, _} = Resources.adopt(state, ref, cache)
    next_lease = make_ref()
    {{:ok, next}, state, _} = Resources.acquire(state, :next, next_lease, consumer, 50_000)
    {:ok, state, _} = Resources.retain_from(state, ref, next, next_lease, cache, consumer)
    assert Resources.current?(state, ref, next_lease, consumer)
    {{:done, _}, state, effects} = Resources.holder_down(state, cache)
    assert {:abandon, consumer, ref, next_lease} in effects
    refute Resources.current?(state, ref, next_lease, consumer)
    {:ok, state, []} = Resources.settle(state, ref, consumer, :retained)
    refute Resources.current?(state, ref, next_lease, consumer)
    assert_accounted(state)
    state = state |> drain(self(), 1) |> drain(consumer, 1)
    assert_empty(state)
  end

  test "metadata, holder indexes and empty pipeline roots are charged" do
    {state, arena, lease} = arena()
    assert Resources.bytes(state) > 100_000
    {{:ok, ref}, state, _} = Resources.reserve(state, arena, lease, :scratch, 0)
    {:ok, state, _} = Resources.close(state, arena)
    assert Resources.bytes(state) > 12_000
    {:ok, state, _} = Resources.release(state, ref, self())
    assert_empty(state)
  end

  defp arena(envelope \\ 100_000, cap \\ 1_000_000) do
    lease = make_ref()

    {{:ok, ref}, state, _} =
      Resources.acquire(Resources.new(max_retained_bytes: cap), :run, lease, self(), envelope)

    {state, ref, lease}
  end

  defp holder do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp drain(state, holder, batch) do
    case Resources.holder_down(state, holder, batch) do
      {{:done, _}, state, _} ->
        state

      {{:more, count}, state, _} ->
        assert count <= batch
        drain(state, holder, batch)
    end
  end

  defp assert_empty(state) do
    assert Resources.bytes(state) == 0
    assert state.runs == %{}
    assert state.arenas == %{}
    assert state.receipts == %{}
    assert state.holders == %{}
  end

  defp assert_accounted(state) do
    roots = Enum.sum(for {_, run} <- state.runs, do: run.root)
    arenas = Enum.sum(for {_, arena} <- state.arenas, do: arena.metadata + arena.free)

    backing =
      Enum.sum(
        for {_, receipt} <- state.receipts,
            do: receipt.metadata + (receipt.actual || receipt.capacity)
      )

    grants =
      Enum.sum(
        for {_, receipt} <- state.receipts, {_, grant} <- receipt.holders, do: grant.metadata
      )

    assert Resources.bytes(state) == roots + arenas + backing + grants
    assert Resources.bytes(state) == Enum.sum(for {_, run} <- state.runs, do: run.used)
    assert Resources.bytes(state) <= state.limit
    assert Enum.all?(state.arenas, fn {_, arena} -> arena.free >= 0 end)
  end
end
