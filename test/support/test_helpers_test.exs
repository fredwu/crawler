defmodule Crawler.TestHelpersTest do
  use ExUnit.Case, async: true

  import Crawler.TestHelpers, only: [wait: 2, start_crawl: 2, await_idle: 1, unique_scope: 1]

  alias Crawler.Store

  test "raw adapter crawls remove their pages and counters on exit" do
    scope = unique_scope("raw-owned-cleanup")
    url = "http://example.test/raw-owned"
    on_exit(fn -> assert_scope_removed(url, scope) end)

    assert {:ok, crawl} = start_crawl(url, raw_options(scope))
    await_idle(crawl)
    assert Store.find_processed({url, scope}).body == "RAW"
    assert Store.ops_count(scope) == 1
    assert Process.alive?(crawl.queue_owner)
  end

  test "raw adapter cleanup drops its scope and leaves an external queue alive" do
    scope = unique_scope("raw-external-cleanup")
    url = "http://example.test/raw-external"
    {queue, processes} = external_queue()

    on_exit(fn ->
      assert_scope_removed(url, scope)
      assert Enum.all?(processes, &Process.alive?/1)
      assert Store.queue_record(queue) == nil
      assert Store.queue_scopes(queue) == []
    end)

    assert {:ok, crawl} = start_crawl(url, Keyword.put(raw_options(scope), :queue, queue))
    await_idle(crawl)
    assert Store.find_processed({url, scope}).body == "RAW"
    assert Store.ops_count(scope) == 1
    assert crawl[:queue_owner] == nil
  end

  test "raw adapter cleanup of a borrowed queue preserves its creator" do
    owner_scope = unique_scope("raw-queue-creator")
    guest_scope = unique_scope("raw-queue-borrower")
    owner_url = "http://example.test/raw-creator"
    guest_url = "http://example.test/raw-borrower"
    on_exit(fn -> assert_scope_removed(owner_url, owner_scope) end)
    assert {:ok, owner} = start_crawl(owner_url, raw_options(owner_scope))
    await_idle(owner)

    on_exit(fn ->
      assert_scope_removed(guest_url, guest_scope)
      assert Process.alive?(owner.queue)
      assert Process.alive?(owner.queue_owner)
      assert Store.find_processed({owner_url, owner_scope}).body == "RAW"
      assert Store.ops_count(owner_scope) == 1
    end)

    assert {:ok, guest} =
             start_crawl(guest_url, Keyword.put(raw_options(guest_scope), :queue, owner.queue))

    await_idle(guest)
    assert Store.find_processed({guest_url, guest_scope}).body == "RAW"
    assert guest[:queue_owner] == nil
  end

  test "wait returns the result after retrying assertion failures" do
    counter = :counters.new(1, [:atomics])

    assert :ready ==
             wait(1_000, fn ->
               :counters.add(counter, 1, 1)
               assert :counters.get(counter, 1) == 3
               :ready
             end)
  end

  test "wait does not retry programming errors" do
    counter = :counters.new(1, [:atomics])

    assert_raise ArgumentError, "invalid fixture", fn ->
      wait(1_000, fn ->
        :counters.add(counter, 1, 1)
        raise ArgumentError, "invalid fixture"
      end)
    end

    assert :counters.get(counter, 1) == 1
  end

  test "a zero timeout makes one attempt and preserves its assertion" do
    counter = :counters.new(1, [:atomics])

    assert_raise ExUnit.AssertionError, ~r/not ready/, fn ->
      wait(0, fn ->
        :counters.add(counter, 1, 1)
        flunk("not ready")
      end)
    end

    assert :counters.get(counter, 1) == 1
  end

  test "time spent in the assertion counts toward the deadline" do
    counter = :counters.new(1, [:atomics])

    assert_raise ExUnit.AssertionError, ~r/expired/, fn ->
      wait(1, fn ->
        :counters.add(counter, 1, 1)

        receive do
        after
          10 -> flunk("expired")
        end
      end)
    end

    assert :counters.get(counter, 1) == 1
  end

  defp assert_scope_removed(url, scope) do
    refute Store.find({url, scope})
    assert Store.ops_count(scope) == 0
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
  end

  defp raw_options(scope) do
    [
      scope: scope,
      workers: 1,
      interval: 0,
      retries: 0,
      store: Store,
      req_options: [
        adapter: fn request -> {request, Req.Response.new(status: 200, body: "RAW")} end
      ]
    ]
  end

  defp external_queue do
    {:links, before} = Process.info(self(), :links)
    {:ok, queue} = OPQ.init(worker: Crawler.Dispatcher.Worker, workers: 1, interval: 0)
    {:links, after_start} = Process.info(self(), :links)
    children = after_start -- before
    on_exit(fn -> Enum.each(children, &stop_external_process/1) end)
    Enum.each(children, &Process.unlink/1)
    {queue, children}
  end

  defp stop_external_process(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
  catch
    :exit, _ -> :ok
  end
end
