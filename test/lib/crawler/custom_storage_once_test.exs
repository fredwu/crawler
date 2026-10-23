defmodule Crawler.CustomStorageOnceTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store
  alias Crawler.Store.CustomStorage

  defmodule HeldStore do
    def add_page_data(key, body, opts) do
      send(opts.storage_owner, {:storage_held, self(), key, body})

      receive do
        :release_storage ->
          :ok
      end
    end
  end

  defmodule CompletedStore do
    def add_page_data(_key, _body, _opts), do: :ok
  end

  test "concurrent interpretations await one physical source storage callback", context do
    scope = unique_scope("custom-storage-once")
    url = context.url <> "/storage-once.bin"

    ReqTestSite.expect_once(context.site, "GET", "/storage-once.bin", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.resp(200, "SOURCE")
    end)

    assert {:ok, opts} =
             start_crawl(url,
               scope: scope,
               workers: 2,
               html_tag: "img",
               javascript_goal: :script,
               max_body: 1_048_576,
               max_analysis_bytes: 16_000_000,
               store: HeldStore,
               storage_owner: self(),
               respect_robots: false,
               req_options: context.req_options
             )

    assert_receive {:storage_held, owner, {^url, ^scope}, "SOURCE"}, 2_000
    on_exit(fn -> send(owner, :release_storage) end)
    assert {:ok, _} = start_crawl(url, Map.put(opts, :javascript_goal, :module))

    wait(fn ->
      state = :sys.get_state(Store)
      run = state.execution_runs[{scope, opts.generation}]
      assert run

      assert Enum.any?(run.members, fn {lease, _} ->
               match?(%{custom_storage: %{role: {:waiter, _}}}, state.executions[lease])
             end)
    end)

    refute_receive {:storage_held, _, _, _}
    send(owner, :release_storage)
    await_idle(opts)
    refute_receive {:storage_held, _, _, _}
    assert Store.find_processed({url, scope})
  end

  for retirement <- [:deadline, :last_queue] do
    test "#{retirement} reclaims completed custom storage markers before scope disposal",
         context do
      opts =
        start_storage(context, "/marker-1", CompletedStore,
          run_timeout: if(unquote(retirement) == :deadline, do: 2_000, else: 30_000)
        )

      for index <- 2..3 do
        path = "/marker-#{index}"
        expect_source(context, path)
        assert {:ok, _} = Crawler.crawl_reference(context.url <> path, opts)
      end

      await_idle(opts)
      state = :sys.get_state(Store)
      markers = markers(state, opts)
      assert length(markers) == 3
      assert Enum.all?(markers, &is_nil(&1.owner))
      receipts = Enum.map(markers, & &1.receipt)
      Enum.each(receipts, &assert_marker_retained(state, opts, &1))

      if unquote(retirement) == :last_queue do
        assert :ok = Crawler.Queue.stop(opts.queue_owner)
      end

      wait(fn ->
        state = :sys.get_state(Store)
        assert markers(state, opts) == []
        assert Map.has_key?(state.scopes, opts.scope)
        Enum.each(receipts, &assert_marker_released(state, opts, &1))
      end)

      if unquote(retirement) == :deadline do
        assert :sys.get_state(Store).scopes[opts.scope].outcome == {:limited, {:deadline, :run}}
      else
        assert :ok = Store.release_queue(opts.queue)
        state = :sys.get_state(Store)
        Enum.each(receipts, &assert_marker_released(state, opts, &1))
      end
    end
  end

  for retirement <- [:last_queue, :reset, :dispose] do
    test "#{retirement} marker drain preserves active owner and waiter receipts until execution cleanup",
         context do
      exercise_active_retirement(context, unquote(retirement))
    end
  end

  defp exercise_active_retirement(context, retirement) do
    opts = start_storage(context, "/active-marker", HeldStore)
    assert_receive {:storage_held, owner, _, "SOURCE"}, 2_000
    on_exit(fn -> send(owner, :release_storage) end)
    assert {:ok, _} = start_crawl(opts.url, Map.put(opts, :javascript_goal, :module))

    wait(fn ->
      executions = :sys.get_state(Store).executions

      assert Enum.any?(executions, fn {_, execution} ->
               match?(%{custom_storage: %{role: {:waiter, _}}}, execution)
             end)
    end)

    state = :sys.get_state(Store)
    [marker] = markers(state, opts)
    owner_lease = marker.owner
    [waiter_lease] = Map.keys(marker.waiters.members)
    waiter = state.executions[waiter_lease].worker
    waiter_receipt = state.executions[waiter_lease].custom_storage.receipt
    owner_monitor = Process.monitor(owner)
    waiter_monitor = Process.monitor(waiter)
    store = Process.whereis(Store)
    receipt = marker.receipt

    :erlang.trace_pattern(
      {CustomStorage, :retire_marker, 2},
      [{[:_, %{receipt: receipt}], [], [{:return_trace}]}],
      [:local]
    )

    :erlang.trace(store, true, [:call])

    on_exit(fn ->
      :erlang.trace(store, false, [:call])
      :erlang.trace_pattern({CustomStorage, :retire_marker, 2}, false, [:local])
    end)

    retire_active(context, opts, retirement)

    assert_receive {:trace, ^store, :return_from, {CustomStorage, :retire_marker, 2}, drained},
                   2_000

    assert drained.executions[owner_lease].custom_storage.receipt === marker.receipt
    assert drained.executions[waiter_lease].custom_storage.receipt === waiter_receipt
    assert_marker_retained(drained, opts, marker.receipt)
    assert_marker_retained(drained, opts, waiter_receipt)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _}, 2_000
    assert_receive {:DOWN, ^waiter_monitor, :process, ^waiter, _}, 2_000

    wait(fn ->
      state = :sys.get_state(Store)

      if retirement != :last_queue do
        assert Map.has_key?(state.scopes, opts.scope) == (retirement == :reset)
      end

      refute Map.has_key?(state.execution_runs, {opts.scope, opts.generation})
      assert markers(state, opts) == []
      refute Map.has_key?(state.executions, owner_lease)
      refute Map.has_key?(state.executions, waiter_lease)
      assert_marker_released(state, opts, marker.receipt)
      assert_marker_released(state, opts, waiter_receipt)
    end)
  end

  defp retire_active(_context, opts, :last_queue),
    do: assert(:ok = Crawler.Queue.stop(opts.queue_owner))

  defp retire_active(_context, opts, :dispose),
    do: assert(:ok = Store.dispose_scope(opts.scope, opts.generation))

  defp retire_active(context, opts, :reset) do
    expect_source(context, "/replacement-marker")

    assert {:ok, fresh} =
             start_crawl(
               context.url <> "/replacement-marker",
               Map.merge(opts, %{force: true, store: CompletedStore})
             )

    refute fresh.generation === opts.generation
  end

  defp start_storage(context, path, storage, extra \\ []) do
    expect_source(context, path)

    assert {:ok, opts} =
             start_crawl(
               context.url <> path,
               Keyword.merge(
                 [
                   scope: unique_scope("custom-storage-retirement"),
                   workers: 2,
                   html_tag: "img",
                   javascript_goal: :script,
                   max_body: 1_024,
                   max_analysis_bytes: 2_097_152,
                   store: storage,
                   storage_owner: self(),
                   respect_robots: false,
                   req_options: context.req_options
                 ],
                 extra
               )
             )

    opts
  end

  defp expect_source(context, path) do
    ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.resp(200, "SOURCE")
    end)
  end

  defp markers(state, opts) do
    ring =
      Map.get(
        state.scheduler.run_representations,
        {opts.scope, opts.generation},
        Crawler.Frontier.Ring.new()
      )

    Enum.flat_map(ring.members, fn {id, _} ->
      record = state.scheduler.representations[id]
      if record, do: Map.values(Map.get(record, :custom_storage, %{})), else: []
    end)
  end

  defp assert_marker_retained(state, opts, receipt) do
    {ordinary, issued} = state.persistent_counts[receipt]
    assert ordinary + issued > 0
    assert MapSet.member?(state.persistent_resources, receipt)
    assert Map.has_key?(state.resources.receipts[receipt].holders, Process.whereis(Store))
    assert state.resources.receipts[receipt].run === {opts.scope, opts.generation}
  end

  defp assert_marker_unindexed(state, opts, receipt) do
    refute Map.has_key?(state.persistent_counts, receipt)
    refute MapSet.member?(state.persistent_resources, receipt)
    ring = Map.get(state.retained_pages, opts.scope, Crawler.Frontier.Ring.new())
    refute Map.has_key?(ring.members, receipt)
  end

  defp assert_marker_released(state, opts, receipt) do
    assert_marker_unindexed(state, opts, receipt)
    refute Map.has_key?(state.resources.receipts, receipt)
    assert :ets.lookup(Crawler.Store.Resources, {:grant, receipt, Process.whereis(Store)}) == []
  end
end
