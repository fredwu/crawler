defmodule Crawler.ReqTestSiteTest do
  use ExUnit.Case, async: true

  alias Crawler.ReqTestSite

  import Crawler.TestHelpers, only: [start_crawl: 2, await_idle: 1, unique_scope: 1]

  defmodule GatedRetrier do
    @behaviour Crawler.Fetcher.Retrier.Spec

    def perform(fetch_url, opts) do
      Crawler.Fetcher.Retrier.perform(
        fn ->
          result = fetch_url.()
          send(opts[:test_pid], {:attempt_finished, self()})

          receive do
            :continue_retry -> result
          after
            2_000 -> raise "Retry was not released"
          end
        end,
        opts
      )
    end
  end

  defmodule GatedParser do
    @behaviour Crawler.Parser.Spec

    def parse(%Crawler.Store.Page{opts: opts} = page) do
      send(opts[:test_pid], {:parser_waiting, self()})

      receive do
        :continue_parse -> Crawler.Parser.parse(page)
      after
        2_000 -> raise "Parser was not released"
      end
    end

    def parse(other), do: Crawler.Parser.parse(other)
  end

  test "start_crawl preserves rejected and budget-denied results without tracking work" do
    site = ReqTestSite.open(verify_on_exit: false)
    on_exit(fn -> ReqTestSite.close(site) end)
    scope = unique_scope("fixture-not-started")
    opts = [scope: scope, req_options: ReqTestSite.req_options(site)]
    missing = Keyword.put(opts, :queue, :crawler_fixture_unavailable_queue)

    try do
      expected = Crawler.crawl(site.url, missing)
      assert {:error, {:queue_unavailable, :crawler_fixture_unavailable_queue}} = expected
      assert start_crawl(site.url, missing) == expected

      denied = Keyword.put(opts, :max_pages, 0)
      assert {:ok, expected} = Crawler.crawl(site.url, denied)
      assert expected[:queue] == nil
      assert start_crawl(site.url, denied) == {:ok, expected}
      assert Agent.get(site.site.agent, & &1.crawls) == MapSet.new()
      assert :ok = ReqTestSite.track_crawl(nil)
      assert :ok = ReqTestSite.verify!(site)
    after
      Crawler.Store.drop_scope(scope)
    end
  end

  test "verify! waits across a real crawl retry after its handler returns" do
    site = ReqTestSite.open(verify_on_exit: false)
    on_exit(fn -> ReqTestSite.close(site) end)

    ReqTestSite.expect_once(site.site, "GET", "/retry", fn conn ->
      Plug.Conn.send_resp(conn, 500, "retry")
    end)

    {:ok, crawl} =
      start_crawl(site.url <> "/retry",
        scope: unique_scope("fixture-retry"),
        workers: 1,
        retries: 1,
        retrier: GatedRetrier,
        test_pid: self(),
        req_options: ReqTestSite.req_options(site)
      )

    assert_receive {:attempt_finished, worker}, 2_000

    try do
      verifier = Task.async(fn -> verify_result(site) end)
      assert is_nil(Task.yield(verifier, 50))
      send(worker, :continue_retry)
      assert_receive {:attempt_finished, ^worker}, 2_000
      send(worker, :continue_retry)

      assert %ExUnit.AssertionError{message: message} = Task.await(verifier)
      assert message =~ "extra request"
    after
      send(worker, :continue_retry)
      Crawler.stop(crawl)
    end
  end

  test "verify! reports a linked unexpected request after its parent handler returns" do
    site = ReqTestSite.open(verify_on_exit: false)
    on_exit(fn -> ReqTestSite.close(site) end)

    ReqTestSite.expect_once(site.site, "GET", "/parent", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, ~s(<a href="/late">late</a>))
    end)

    {:ok, crawl} =
      start_crawl(site.url <> "/parent",
        scope: unique_scope("fixture-parser"),
        workers: 1,
        retries: 0,
        parser: GatedParser,
        test_pid: self(),
        req_options: ReqTestSite.req_options(site)
      )

    assert_receive {:parser_waiting, worker}, 2_000

    try do
      verifier = Task.async(fn -> verify_result(site) end)
      assert is_nil(Task.yield(verifier, 50))
      send(worker, :continue_parse)

      assert %ExUnit.AssertionError{message: message} = Task.await(verifier)
      assert message =~ "Unexpected request"
      assert message =~ "/late"
    after
      send(worker, :continue_parse)
      Crawler.stop(crawl)
    end
  end

  test "verify! waits for tracked work before its first HTTP request" do
    site = ReqTestSite.open(verify_on_exit: false)
    on_exit(fn -> ReqTestSite.close(site) end)
    scope = unique_scope("fixture-queued")
    queue = paused_queue(scope)

    ReqTestSite.expect_once(site.site, "GET", "/queued", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    {:ok, crawl} =
      start_crawl(site.url <> "/queued",
        scope: scope,
        queue: queue,
        req_options: ReqTestSite.req_options(site)
      )

    try do
      verifier = Task.async(fn -> ReqTestSite.verify!(site) end)
      assert is_nil(Task.yield(verifier, 50))
      Crawler.resume(crawl)
      assert :ok = Task.await(verifier)
    after
      Crawler.stop(crawl)
    end
  end

  test "verify! ignores another fixture's paused queue in the same scope" do
    site = ReqTestSite.open(verify_on_exit: false)
    on_exit(fn -> ReqTestSite.close(site) end)
    other = ReqTestSite.open(verify_on_exit: false)
    on_exit(fn -> ReqTestSite.close(other) end)
    scope = unique_scope("fixture-isolated")

    ReqTestSite.expect_once(site.site, "GET", "/done", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    {:ok, completed} =
      start_crawl(site.url <> "/done", scope: scope, req_options: ReqTestSite.req_options(site))

    await_idle(completed)
    queue = paused_queue(scope)

    {:ok, paused} =
      start_crawl(other.url <> "/paused",
        scope: scope,
        queue: queue,
        req_options: ReqTestSite.req_options(other)
      )

    try do
      assert Crawler.Store.pending_count(scope) == 1
      verifier = Task.async(fn -> ReqTestSite.verify!(site) end)
      assert :ok = Task.await(verifier, 500)
      assert Crawler.Store.pending_count(scope) == 1
    after
      Crawler.stop(paused)
      Crawler.stop(completed)
    end
  end

  test "verify! treats a tracked crawl's stopped generation as settled" do
    site = ReqTestSite.open(verify_on_exit: false)
    on_exit(fn -> ReqTestSite.close(site) end)
    scope = unique_scope("fixture-stopped")
    queue = paused_queue(scope)

    {:ok, crawl} =
      start_crawl(site.url <> "/cancelled",
        scope: scope,
        queue: queue,
        req_options: ReqTestSite.req_options(site)
      )

    try do
      verifier = Task.async(fn -> ReqTestSite.verify!(site) end)
      assert is_nil(Task.yield(verifier, 50))
      Crawler.stop(crawl)
      assert :ok = Task.await(verifier)
    after
      Crawler.stop(crawl)
    end
  end

  test "verify! reports missing expected calls" do
    site = ReqTestSite.open(hosts: 1, verify_on_exit: false)
    on_exit(fn -> ReqTestSite.close(site) end)

    ReqTestSite.expect_once(site.site, "GET", "/missing", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert_raise ExUnit.AssertionError, ~r/exactly once, got 0 calls/, fn ->
      ReqTestSite.verify!(site)
    end
  end

  test "verify! reports unexpected requests" do
    site = ReqTestSite.open(hosts: 1, verify_on_exit: false)
    on_exit(fn -> ReqTestSite.close(site) end)

    assert {:ok, %Req.Response{status: 500}} =
             Req.get(site.url <> "/unexpected", ReqTestSite.req_options(site))

    assert_raise ExUnit.AssertionError, ~r/Unexpected request/, fn ->
      ReqTestSite.verify!(site)
    end
  end

  test "verify! reports an unexpected request that arrives while another is in flight" do
    site = ReqTestSite.open(hosts: 1, verify_on_exit: false)
    on_exit(fn -> ReqTestSite.close(site) end)
    test_pid = self()

    ReqTestSite.expect_once(site.site, "GET", "/hold", fn conn ->
      send(test_pid, {:holding, self()})

      receive do
        :release -> Plug.Conn.send_resp(conn, 200, "ok")
      end
    end)

    hold =
      Task.async(fn ->
        Req.get(site.url <> "/hold", ReqTestSite.req_options(site))
      end)

    assert_receive {:holding, holder}, 2_000

    late =
      Task.async(fn ->
        receive do
          :go -> Req.get(site.url <> "/late", ReqTestSite.req_options(site))
        end
      end)

    verifier =
      Task.async(fn ->
        try do
          ReqTestSite.verify!(site)
          :no_error
        rescue
          error in ExUnit.AssertionError -> error
        end
      end)

    assert is_nil(Task.yield(verifier, 50))

    send(late.pid, :go)
    assert {:ok, %Req.Response{status: 500}} = Task.await(late)
    send(holder, :release)

    assert %ExUnit.AssertionError{message: message} = Task.await(verifier)
    assert message =~ "Unexpected request"
    assert {:ok, %Req.Response{status: 200}} = Task.await(hold)
  end

  test "expect_once rejects extra calls without running the route handler again" do
    site = ReqTestSite.open(hosts: 1, verify_on_exit: false)
    on_exit(fn -> ReqTestSite.close(site) end)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    ReqTestSite.expect_once(site.site, "GET", "/once", fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert {:ok, %Req.Response{status: 200}} =
             Req.get(site.url <> "/once", ReqTestSite.req_options(site))

    assert {:ok, %Req.Response{status: 500}} =
             Req.get(site.url <> "/once", ReqTestSite.req_options(site))

    assert Agent.get(counter, & &1) == 1

    assert_raise ExUnit.AssertionError, ~r/extra request/, fn ->
      ReqTestSite.verify!(site)
    end
  end

  test "verify! reports route handler failures" do
    site = ReqTestSite.open(hosts: 1, verify_on_exit: false)
    on_exit(fn -> ReqTestSite.close(site) end)

    ReqTestSite.expect_once(site.site, "GET", "/boom", fn _conn ->
      raise "boom"
    end)

    assert {:ok, %Req.Response{status: 500}} =
             Req.get(site.url <> "/boom", ReqTestSite.req_options(site))

    assert_raise ExUnit.AssertionError, ~r/boom/, fn ->
      ReqTestSite.verify!(site)
    end
  end

  test "verify! waits for in-flight route handlers" do
    site = ReqTestSite.open(hosts: 1, verify_on_exit: false)
    on_exit(fn -> ReqTestSite.close(site) end)
    test_pid = self()

    ReqTestSite.expect_once(site.site, "GET", "/slow", fn conn ->
      send(test_pid, {:handler_started, self()})

      receive do
        :release -> Plug.Conn.send_resp(conn, 200, "ok")
      end
    end)

    request =
      Task.async(fn ->
        Req.get(site.url <> "/slow", ReqTestSite.req_options(site))
      end)

    assert_receive {:handler_started, handler_pid}, 2_000

    verifier =
      Task.async(fn ->
        ReqTestSite.verify!(site)
        send(test_pid, :verified)
        :ok
      end)

    refute_receive :verified, 20

    send(handler_pid, :release)

    assert :ok = Task.await(verifier)
    assert {:ok, %Req.Response{status: 200}} = Task.await(request)
  end

  defp verify_result(site) do
    ReqTestSite.verify!(site)
  rescue
    error in ExUnit.AssertionError -> error
  end

  defp paused_queue(scope) do
    opts = %{scope: scope, workers: 1, interval: 0, timeout: 5_000}
    spec = Supervisor.child_spec({Crawler.Queue, opts}, restart: :temporary)
    {:ok, owner} = DynamicSupervisor.start_child(Crawler.QueueSupervisor, spec)
    on_exit(fn -> Crawler.Queue.stop(owner) end)
    queue = Crawler.Queue.feeder(owner)
    OPQ.pause(queue)
    assert {:paused, _, _} = OPQ.info(queue)
    queue
  end
end
