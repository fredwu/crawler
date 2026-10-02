defmodule Crawler.CrawlPageBudgetTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  for status <- [404, 500] do
    test "a blocked #{status} child releases its page slot for a successful sibling", context do
      exercise_failed_child(unquote(status), context)
    end
  end

  test "parked work honors its own limit and frees worker capacity", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    scope = unique_scope("different-page-budgets")
    blocked_route(site, "/budget/root", parent, 200)

    ReqTestSite.stub(site, "GET", "/budget/small", fn conn ->
      send(parent, :small_fetched)
      Plug.Conn.resp(conn, 200, "small")
    end)

    ReqTestSite.expect_once(site, "GET", "/budget/large", fn conn ->
      send(parent, :large_fetched)
      Plug.Conn.resp(conn, 200, "large")
    end)

    owner = crawl(url <> "/budget/root", scope, req_options, workers: 2, max_pages: 3)
    on_exit(fn -> Crawler.stop(owner) end)
    assert_receive {:blocked, handler}, 2_000
    on_exit(fn -> send(handler, :release) end)

    crawl(url <> "/budget/small", scope, req_options, queue: owner[:queue], max_pages: 1)
    await_parked(owner, 2, 1)

    crawl(url <> "/budget/large", scope, req_options, queue: owner[:queue], max_pages: 2)
    assert_receive :large_fetched, 2_000

    wait(fn ->
      assert Store.ops_count(scope) == 1
      assert Store.pending_count(scope) == 1
      assert Store.inflight_count(scope) == 1
    end)

    refute_receive :small_fetched
    send(handler, :release)
    await_idle(owner)
    assert Store.ops_count(scope) == 2
    refute Store.find({url <> "/budget/small", scope})
    assert Store.find_processed({url <> "/budget/large", scope})
    assert_idle_counts(scope)
  end

  test "retiring a claimed queue wakes parked work on another queue", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    scope = unique_scope("retired-page-reservation")
    blocked_route(site, "/budget/lost", parent, 404)

    ReqTestSite.expect_once(site, "GET", "/budget/live", fn conn ->
      Plug.Conn.resp(conn, 200, "live")
    end)

    lost = crawl(url <> "/budget/lost", scope, req_options, max_pages: 1)
    on_exit(fn -> Crawler.stop(lost) end)
    assert_receive {:blocked, handler}, 2_000
    on_exit(fn -> send(handler, :release) end)

    live = crawl(url <> "/budget/live", scope, req_options, max_pages: 1)
    on_exit(fn -> Crawler.stop(live) end)
    await_parked(live, 2, 1)
    ref = Process.monitor(lost[:queue_owner])
    Process.exit(lost[:queue], :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000

    await_idle(live)
    assert Store.generation(scope) == live[:generation]
    assert Store.ops_count(scope) == 1
    assert Store.find_processed({url <> "/budget/live", scope})
    refute Store.find({url <> "/budget/lost", scope})
    refute Crawler.running?(lost)
    assert_idle_counts(scope)
  end

  test "resetting page counts wakes parked work while another reservation stays active", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    scope = unique_scope("reset-page-budget")
    blocked_route(site, "/budget/blocked-reset", parent, 404)

    ReqTestSite.expect_once(site, "GET", "/budget/kept-reset", fn conn ->
      Plug.Conn.resp(conn, 200, "kept")
    end)

    ReqTestSite.expect_once(site, "GET", "/budget/resumed-reset", fn conn ->
      send(parent, :resumed_after_reset)
      Plug.Conn.resp(conn, 200, "resumed")
    end)

    owner = crawl(url <> "/budget/kept-reset", scope, req_options, workers: 2, max_pages: 3)
    on_exit(fn -> Crawler.stop(owner) end)
    await_idle(owner)
    assert Store.ops_count(scope) == 1
    kept = Store.find_processed({url <> "/budget/kept-reset", scope})

    crawl(url <> "/budget/blocked-reset", scope, req_options,
      queue: owner[:queue],
      max_pages: 3
    )

    assert_receive {:blocked, handler}, 2_000
    on_exit(fn -> send(handler, :release) end)

    crawl(url <> "/budget/resumed-reset", scope, req_options,
      queue: owner[:queue],
      max_pages: 2
    )

    await_parked(owner, 2, 1)
    refute_receive :resumed_after_reset
    assert :ok = Store.ops_reset()
    assert_receive :resumed_after_reset, 2_000

    wait(fn ->
      assert Store.ops_count(scope) == 1
      assert Store.pending_count(scope) == 1
      assert Store.inflight_count(scope) == 1
      assert Store.find_processed({url <> "/budget/resumed-reset", scope})
    end)

    assert Store.find_processed({url <> "/budget/kept-reset", scope}) == kept
    send(handler, :release)
    await_idle(owner)
    assert Store.ops_count(scope) == 1
    assert_idle_counts(scope)
  end

  test "exhausting another queue's parked work clears its failed URL before the first retry", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    scope = unique_scope("exhausted-queue-cleanup")
    blocked_route(site, "/budget/completed-other", parent, 200)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    failed_then_successful_route(site, parent, attempts)

    ReqTestSite.stub(site, "GET", "/budget/exhausted-parked", fn conn ->
      send(parent, :exhausted_fetched)
      Plug.Conn.resp(conn, 200, "parked")
    end)

    other = crawl(url <> "/budget/completed-other", scope, req_options, max_pages: 1)
    on_exit(fn -> Crawler.stop(other) end)
    assert_receive {:blocked, handler}, 2_000
    on_exit(fn -> send(handler, :release) end)

    direct_key = {url <> "/budget/direct", scope}
    assert {:ok, _} = Store.add(direct_key, other[:generation])

    assert {_, _} =
             Store.add_page_data(direct_key, "DIRECT", %{generation: other[:generation]})

    direct = Store.find(direct_key)
    failed_key = {url <> "/budget/exhausted-failure", scope}
    owner = crawl(elem(failed_key, 0), scope, req_options, max_pages: 2, workers: 2)
    on_exit(fn -> Crawler.stop(owner) end)
    assert_receive {:failed_fetch, failure_handler}, 2_000
    on_exit(fn -> send(failure_handler, :release) end)

    crawl(url <> "/budget/exhausted-parked", scope, req_options,
      queue: owner[:queue],
      max_pages: 1
    )

    await_parked(owner, 3, 2)
    send(failure_handler, :release)

    wait(fn ->
      assert Store.pending_count(scope) == 2
      assert Store.inflight_count(scope) == 1
      assert Store.find(failed_key)
    end)

    send(handler, :release)
    await_idle(other)
    assert Store.ops_count(scope) == 1
    assert Store.find_processed({url <> "/budget/completed-other", scope})
    refute Store.find(failed_key)
    assert Store.find(direct_key) == direct
    refute_receive :exhausted_fetched

    assert {:ok, retry} = start_crawl(elem(failed_key, 0), owner)
    assert_receive :retried_fetch, 2_000
    await_idle(retry)
    assert Agent.get(attempts, & &1) == 2
    assert Store.find_processed(failed_key)
    assert Store.find_processed({url <> "/budget/completed-other", scope})
    assert Store.find(direct_key) == direct
    assert Store.ops_count(scope) == 2
    assert_idle_counts(scope)
  end

  defp exercise_failed_child(status, %{site: site, url: url, req_options: req_options}) do
    parent = self()
    scope = unique_scope("failed-page-slot")
    blocked_route(site, "/budget/failure", parent, status)

    ReqTestSite.expect_once(site, "GET", "/budget/root", fn conn ->
      Plug.Conn.resp(conn, 200, """
      <a href="#{url}/budget/failure">failed child</a>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/budget/success", fn conn ->
      send(parent, :success_fetched)
      Plug.Conn.resp(conn, 200, "success")
    end)

    owner = crawl(url <> "/budget/root", scope, req_options, workers: 2, max_pages: 2)
    on_exit(fn -> Crawler.stop(owner) end)
    assert_receive {:blocked, handler}, 2_000
    on_exit(fn -> send(handler, :release) end)

    wait(fn -> assert Store.ops_count(scope) == 1 end)
    assert {:ok, _} = start_crawl(url <> "/budget/success", Map.put(owner, :depth, 1))
    await_parked(owner, 2, 1)
    refute_receive :success_fetched
    send(handler, :release)
    assert_receive :success_fetched, 2_000
    await_idle(owner)

    assert Store.ops_count(scope) == 2
    assert Store.find_processed({url <> "/budget/root", scope})
    assert Store.find_processed({url <> "/budget/success", scope})
    refute Store.find({url <> "/budget/failure", scope})
    assert_idle_counts(scope)
  end

  defp failed_then_successful_route(site, parent, attempts) do
    ReqTestSite.expect(site, "GET", "/budget/exhausted-failure", fn conn ->
      attempt = Agent.get_and_update(attempts, &{&1, &1 + 1})
      failure_response(conn, parent, attempt)
    end)
  end

  defp failure_response(conn, parent, 0) do
    send(parent, {:failed_fetch, self()})

    receive do
      :release -> Plug.Conn.resp(conn, 404, "failed")
    end
  end

  defp failure_response(conn, parent, _attempt) do
    send(parent, :retried_fetch)
    Plug.Conn.resp(conn, 200, "retried")
  end

  defp blocked_route(site, path, parent, status) do
    ReqTestSite.expect_once(site, "GET", path, fn conn ->
      send(parent, {:blocked, self()})

      receive do
        :release -> Plug.Conn.resp(conn, status, "released")
      end
    end)
  end

  defp await_parked(opts, pending, inflight) do
    wait(fn ->
      assert Store.pending_count(opts[:scope]) == pending
      assert Store.inflight_count(opts[:scope]) == inflight
      assert {:normal, %OPQ.Queue{data: data}, _} = OPQ.info(opts[:queue])
      assert :queue.is_empty(data)
    end)
  end

  defp assert_idle_counts(scope) do
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
  end

  defp crawl(page, scope, req_options, extra) do
    opts = [
      scope: scope,
      workers: 1,
      max_depths: 3,
      retries: 0,
      store: Store,
      req_options: req_options
    ]

    {:ok, opts} = start_crawl(page, Keyword.merge(opts, extra))
    opts
  end
end
