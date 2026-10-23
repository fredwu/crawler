defmodule Crawler.Store.PageResourcesTest do
  use ExUnit.Case, async: false

  alias Crawler.Store
  alias Crawler.Store.Execution

  import Crawler.TestHelpers, only: [wait: 1]

  setup do
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)
    %{scope: scope}
  end

  test "explicit and repeated deletion release a managed Page receipt", %{scope: scope} do
    opts = options(scope, "/deleted")
    key = {opts.url, scope}
    assert :ok = Execution.run(opts, &store_page(&1, key, "DELETE"))
    receipt = Store.find(key).opts.page_resource
    assert_retained(scope, receipt, 1)

    assert :ok = Store.delete(key)
    refute Store.find(key)
    assert_released(scope, receipt)
    assert :ok = Store.delete(key)
    assert_released(scope, receipt)
  end

  test "replacing a managed Page removes the old receipt from retention indexes", %{scope: scope} do
    opts = options(scope, "/replaced")
    key = {opts.url, scope}
    assert :ok = Execution.run(opts, &store_page(&1, key, "OLD"))
    old = Store.find(key).opts.page_resource

    assert :ok =
             Execution.run(opts, fn owned ->
               assert :stored = Store.add_page_data(key, "NEW", owned)
               :ok
             end)

    current = Store.find(key)
    assert current.body == "NEW"
    refute current.opts.page_resource == old
    assert_released(scope, old)
    assert_retained(scope, current.opts.page_resource, 1)
    assert :ok = Store.delete(key)
    assert_released(scope, current.opts.page_resource)
  end

  test "queue retirement releases its unprocessed Page and preserves readable Pages", %{
    scope: scope
  } do
    kept_opts = options(scope, "/kept")
    kept_key = {kept_opts.url, scope}

    assert :ok =
             Execution.run(kept_opts, fn owned ->
               store_page(owned, kept_key, "KEEP")
               assert {_, _} = Store.processed(kept_key, owned.generation)
               :ok
             end)

    kept = Store.find_processed(kept_key)
    generation = Store.generation(scope)
    queue = idle_queue()
    assert :ok = Store.note_enqueued(scope, generation, queue)
    opts = options(scope, "/retired") |> Map.merge(%{generation: generation, queue: queue})
    key = {opts.url, scope}
    assert :ok = Execution.run(opts, &store_page(&1, key, "RETIRE"))
    receipt = Store.find(key).opts.page_resource
    assert_retained(scope, receipt, 1)

    assert :ok = Store.release_queue(queue)
    refute Store.find(key)
    assert_released(scope, receipt)
    assert Store.generation(scope) == generation
    assert Store.find_processed(kept_key) == kept
    assert_retained(scope, kept.opts.page_resource, 1)
  end

  test "shared Page ownership ends once while an external holder remains charged", %{scope: scope} do
    %{holder: holder, first: first, second: second, receipt: receipt} = shared_pages(scope)
    assert_retained(scope, receipt, 2)

    wait(fn -> assert map_size(:sys.get_state(Store).resources.receipts[receipt].holders) == 2 end)

    actual = :sys.get_state(Store).resources.receipts[receipt].actual

    assert :ok = Store.delete(first)
    refute Store.find(first)
    assert Store.find(second).body == "SHARED"
    assert_retained(scope, receipt, 1)

    assert :ok = Store.delete(second)
    refute Store.find(second)
    assert_unindexed(scope, receipt)
    state = :sys.get_state(Store)
    record = state.resources.receipts[receipt]
    assert record.actual == actual
    assert Map.keys(record.holders) == [holder]
    assert record.holders[holder].status == :adopted
    assert state.resources.used >= actual
    assert :ok = Store.delete(second)
    assert :sys.get_state(Store).resources.receipts[receipt].actual == actual

    monitor = Process.monitor(holder)
    send(holder, :drop)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}, 2_000
    assert_released(scope, receipt)
  end

  test "public replacement rejects another Page's receipt and releases only removed ownership", %{
    scope: scope
  } do
    first_opts = options(scope, "/public-first")
    second_opts = options(scope, "/public-second")
    first = {first_opts.url, scope}
    second = {second_opts.url, scope}
    assert :ok = Execution.run_job(first_opts, &store_page(&1, first, "FIRST"))
    assert :ok = Execution.run_job(second_opts, &store_page(&1, second, "SECOND"))
    first_page = Store.find(first)
    second_page = Store.find(second)
    assert is_reference(first_page.target_handle)
    assert is_reference(second_page.target_handle)
    first_receipt = first_page.opts.page_resource
    second_receipt = second_page.opts.page_resource

    wait(fn ->
      state = :sys.get_state(Store)
      assert map_size(state.resources.receipts[first_receipt].holders) == 1
      assert map_size(state.resources.receipts[second_receipt].holders) == 1
    end)

    before_first = receipt_accounting(scope, first_receipt)
    before_second = receipt_accounting(scope, second_receipt)
    assert Process.get(:crawler_execution_lease) == nil

    for field <- [:page_resource, :body_resource] do
      foreign = Map.put(first_page.opts, field, second_receipt)
      assert {:error, :stale} = Store.add_page_data(first, "FOREIGN", foreign)
      assert Store.find(first) === first_page
      assert Store.find(second) === second_page
      assert receipt_accounting(scope, first_receipt) === before_first
      assert receipt_accounting(scope, second_receipt) === before_second
    end

    assert :ok = Store.delete(first)
    assert_released(scope, first_receipt)
    assert Store.find(second) === second_page
    assert_retained(scope, second_receipt, 1)
    replacement_opts = %{generation: Store.generation(scope)}
    assert {replacement, ^second_page} = Store.add_page_data(second, "PUBLIC", replacement_opts)
    assert replacement.body == "PUBLIC"
    assert replacement.opts === replacement_opts
    assert is_reference(replacement.storage_revision)
    refute replacement.storage_revision === second_page.storage_revision

    assert Map.drop(replacement, [:body, :opts, :storage_revision]) ===
             Map.drop(second_page, [:body, :opts, :storage_revision])

    assert_released(scope, second_receipt)
    assert :ok = Store.delete(second)
    assert :ok = Store.delete(second)
    assert_released(scope, second_receipt)
  end

  test "public writes retain unchanged shared refs and reject stale generations before replacement",
       %{scope: scope} do
    stale = Store.generation(scope)
    refute Store.drop_scope(scope) === stale
    %{holder: holder, first: first, second: second, receipt: receipt} = shared_pages(scope)

    wait(fn -> assert map_size(:sys.get_state(Store).resources.receipts[receipt].holders) == 2 end)

    assert_retained(scope, receipt, 2)
    first_page = Store.find(first)
    second_page = Store.find(second)
    before = receipt_accounting(scope, receipt)
    assert Process.get(:crawler_execution_lease) == nil

    assert {rewritten, ^first_page} =
             Store.add_page_data(first, first_page.body, first_page.opts)

    assert is_reference(rewritten.storage_revision)
    refute rewritten.storage_revision === first_page.storage_revision
    assert Map.delete(rewritten, :storage_revision) === Map.delete(first_page, :storage_revision)
    first_page = rewritten

    assert receipt_accounting(scope, receipt) === before
    stale_opts = Map.put(first_page.opts, :generation, stale)
    assert {:error, :stale} = Store.add_page_data(first, "STALE", stale_opts)
    assert Store.find(first) === first_page
    assert Store.find(second) === second_page
    assert receipt_accounting(scope, receipt) === before
    replacement_opts = %{generation: Store.generation(scope)}
    assert {replaced_first, ^first_page} = Store.add_page_data(first, "ONE", replacement_opts)
    assert is_reference(replaced_first.storage_revision)
    refute replaced_first.storage_revision === first_page.storage_revision

    assert Map.drop(replaced_first, [:body, :opts, :storage_revision]) ===
             Map.drop(first_page, [:body, :opts, :storage_revision])

    assert Store.find(second) === second_page
    assert_retained(scope, receipt, 1)
    assert :ok = Store.delete(first)
    assert_retained(scope, receipt, 1)
    assert {replaced_second, ^second_page} = Store.add_page_data(second, "TWO", replacement_opts)
    assert is_reference(replaced_second.storage_revision)
    refute replaced_second.storage_revision === second_page.storage_revision

    assert Map.drop(replaced_second, [:body, :opts, :storage_revision]) ===
             Map.drop(second_page, [:body, :opts, :storage_revision])

    assert_unindexed(scope, receipt)
    record = :sys.get_state(Store).resources.receipts[receipt]
    assert record.actual == before.receipt.actual
    assert Map.keys(record.holders) == [holder]
    assert record.holders[holder].status == :adopted
    assert :sys.get_state(Store).resources.used >= record.actual
    assert :ok = Store.delete(second)
    assert :ok = Store.delete(second)
    assert :sys.get_state(Store).resources.receipts[receipt] === record
    monitor = Process.monitor(holder)
    send(holder, :drop)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}, 2_000
    assert_released(scope, receipt)
  end

  defp shared_pages(scope) do
    parent = self()
    holder = spawn(fn -> hold_page(parent) end)
    on_exit(fn -> Process.exit(holder, :kill) end)
    opts = options(scope, "/shared-first")
    first = {opts.url, scope}
    second = {"https://page-resources.test/shared-second", scope}

    assert :ok =
             Execution.run(opts, fn owned ->
               store_page(owned, first, "SHARED")
               page = Store.find(first)
               receipt = page.opts.page_resource
               assert {:ok, _} = Store.add(second, owned.generation)
               assert :stored = Store.add_page_data(second, page.body, page.opts)
               assert :ok = Store.retain_resource(receipt, holder)
               assert {:ok, _} = Store.deliver_resource(receipt, holder, page.body)
               :ok
             end)

    assert_receive {:page_held, ^holder, receipt}, 2_000
    %{holder: holder, first: first, second: second, receipt: receipt}
  end

  defp receipt_accounting(scope, receipt) do
    state = :sys.get_state(Store)
    record = state.resources.receipts[receipt]

    %{
      receipt: record,
      arena: state.resources.arenas[record.arena],
      run: state.resources.runs[record.run],
      count: state.persistent_counts[receipt],
      persistent?: MapSet.member?(state.persistent_resources, receipt),
      retained: state.retained_pages[scope]
    }
  end

  defp options(scope, path) do
    %{
      scope: scope,
      url: "https://page-resources.test" <> path,
      respect_robots: false,
      max_body: 1_024,
      max_analysis_bytes: 2_097_152
    }
  end

  defp store_page(owned, key, body) do
    assert {:ok, _} = Store.add(key, owned.generation, owned[:queue])
    assert :stored = Store.add_page_data(key, body, owned)
    :ok
  end

  defp assert_retained(scope, receipt, count) do
    state = :sys.get_state(Store)
    assert state.persistent_counts[receipt] == {count, 0}
    assert MapSet.member?(state.persistent_resources, receipt)
    assert Map.has_key?(state.retained_pages[scope].members, receipt)
    assert Map.has_key?(state.resources.receipts[receipt].holders, Process.whereis(Store))
    assert state.resources.receipts[receipt].metadata >= 4_096

    assert {:ok, fixed} =
             Crawler.Store.Retained.bytes({{:completed, make_ref()}, {count, 0}}, 4_096)

    assert fixed <= state.resources.receipts[receipt].metadata
  end

  defp assert_unindexed(scope, receipt) do
    state = :sys.get_state(Store)
    refute Map.has_key?(state.persistent_counts, receipt)
    refute MapSet.member?(state.persistent_resources, receipt)
    ring = Map.get(state.retained_pages, scope, Crawler.Frontier.Ring.new())
    refute Map.has_key?(ring.members, receipt)
  end

  defp assert_released(scope, receipt) do
    wait(fn ->
      assert_unindexed(scope, receipt)
      refute :sys.get_state(Store).resources.receipts[receipt]
    end)
  end

  defp idle_queue do
    queue =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(queue, :kill) end)
    queue
  end

  defp hold_page(parent) do
    receive do
      {:crawler_resource_delivery, receipt, _lease, _reply, _ref, body} ->
        send(Store, {:crawler_resource_adopted, receipt, self()})
        _ = :sys.get_state(Store)
        send(parent, {:page_held, self(), receipt})

        receive do
          :drop -> byte_size(body)
        end
    end
  end
end
