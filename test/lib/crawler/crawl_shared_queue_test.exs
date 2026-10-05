defmodule Crawler.CrawlSharedQueueTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  test "a crawl that finishes keeps its pages when another scope stops", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    kept_scope = unique_scope("lifecycle-kept")
    stopped_scope = unique_scope("lifecycle-other-stop")
    kept = "#{url}/lifecycle/kept"
    stopped = "#{url}/lifecycle/other-stop"

    ReqTestSite.expect_once(site, "GET", "/lifecycle/kept", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "kept")
    end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/other-stop", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "gone")
    end)

    {:ok, kept_opts} =
      start_crawl(kept,
        scope: kept_scope,
        workers: 1,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    {:ok, stopped_opts} =
      start_crawl(stopped,
        scope: stopped_scope,
        workers: 1,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(kept_opts)
      refute Crawler.running?(stopped_opts)
      assert %Store.Page{body: "kept"} = Store.find_processed({kept, kept_scope})
      assert Store.find_processed({stopped, stopped_scope})
    end)

    assert :ok = Crawler.stop(stopped_opts)

    refute Process.alive?(stopped_opts[:queue])
    assert Process.alive?(kept_opts[:queue])
    assert Process.alive?(kept_opts[:queue_owner])
    refute Store.find({stopped, stopped_scope})
    assert %Store.Page{body: "kept"} = Store.find_processed({kept, kept_scope})
    refute Crawler.running?(stopped_opts)
    refute Crawler.running?(kept_opts)
  end

  test "stopping one owned queue leaves the other crawl running", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    scope_a = unique_scope("lifecycle-queue-a")
    scope_b = unique_scope("lifecycle-queue-b")
    page_a = "#{url}/lifecycle/owned-a"
    page_b = "#{url}/lifecycle/owned-b"

    ReqTestSite.stub(site, "GET", "/lifecycle/owned-a", fn conn ->
      send(parent, {:started, :a, self()})

      receive do
        :release ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.resp(200, "A")
      after
        10_000 ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.resp(200, "late")
      end
    end)

    ReqTestSite.stub(site, "GET", "/lifecycle/owned-b", fn conn ->
      send(parent, {:started, :b, self()})

      receive do
        :release ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.resp(200, "B")
      after
        10_000 ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.resp(200, "late")
      end
    end)

    {:ok, first} =
      start_crawl(page_a,
        scope: scope_a,
        workers: 1,
        timeout: 10_000,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    {:ok, second} =
      start_crawl(page_b,
        scope: scope_b,
        workers: 1,
        timeout: 10_000,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    assert_receive {:started, :a, handler_a}, 1_000
    assert_receive {:started, :b, handler_b}, 1_000
    on_exit(fn -> send(handler_a, :release) end)
    on_exit(fn -> send(handler_b, :release) end)
    assert first[:queue] != second[:queue]

    assert :ok = Crawler.stop(first)
    refute Process.alive?(first[:queue])
    refute Process.alive?(first[:queue_owner])
    assert Process.alive?(second[:queue])
    assert Process.alive?(second[:queue_owner])
    refute Crawler.running?(first)
    assert Crawler.running?(second)

    send(handler_a, :release)
    send(handler_b, :release)

    wait(fn ->
      refute Crawler.running?(second)
      refute Store.find({page_a, scope_a})
      assert %Store.Page{body: "B"} = Store.find_processed({page_b, scope_b})
    end)
  end

  test "stopping a shared queue keeps the other scope's stored pages", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope_a = unique_scope("lifecycle-shared-owner")
    scope_b = unique_scope("lifecycle-shared-guest")
    page_a = "#{url}/lifecycle/shared-a"
    page_b = "#{url}/lifecycle/shared-b"

    ReqTestSite.expect_once(site, "GET", "/lifecycle/shared-a", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "owner")
    end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/shared-b", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "guest")
    end)

    {:ok, owner} =
      start_crawl(page_a,
        scope: scope_a,
        workers: 2,
        interval: 20,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    {:ok, guest} =
      start_crawl(page_b,
        scope: scope_b,
        queue: owner[:queue],
        retries: 0,
        store: Store,
        req_options: req_options
      )

    assert guest[:queue_owner] == nil
    assert guest[:queue] == owner[:queue]

    wait(2_000, fn ->
      refute Crawler.running?(owner)
      refute Crawler.running?(guest)
      assert Store.find_processed({page_a, scope_a})
      assert %Store.Page{body: "guest"} = Store.find_processed({page_b, scope_b})
    end)

    flags = Process.info(self(), :trap_exit)
    assert :ok = Crawler.stop(owner)
    assert Process.info(self(), :trap_exit) == flags
    refute Process.alive?(owner[:queue])
    refute Process.alive?(owner[:queue_owner])
    refute Process.whereis(:"opq-#{inspect(owner[:queue])}")
    refute Store.find({page_a, scope_a})
    assert Store.ops_count(scope_a) == 0
    assert Store.inflight_count(scope_a) == 0
    assert Store.inflight_count(scope_b) == 0
    assert %Store.Page{body: "guest"} = Store.find_processed({page_b, scope_b})
    assert Store.ops_count(scope_b) == 1
    refute Crawler.running?(owner)
    refute Crawler.running?(guest)
  end

  test "stopping a guest crawl leaves the shared queue at work", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    scope_a = unique_scope("lifecycle-guest-owner")
    scope_b = unique_scope("lifecycle-guest-stop")
    page_a = "#{url}/lifecycle/guest-a"
    page_b = "#{url}/lifecycle/guest-b"
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    ReqTestSite.stub(site, "GET", "/lifecycle/guest-a", fn conn ->
      send(parent, {:started, self()})

      receive do
        :release ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.resp(200, "owner")
      after
        10_000 ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.resp(200, "late")
      end
    end)

    ReqTestSite.stub(site, "GET", "/lifecycle/guest-b", fn conn ->
      Agent.update(hits, &(&1 + 1))

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "guest")
    end)

    {:ok, owner} =
      start_crawl(page_a,
        scope: scope_a,
        workers: 1,
        timeout: 10_000,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    assert_receive {:started, handler}, 1_000
    on_exit(fn -> send(handler, :release) end)

    {:ok, guest} =
      start_crawl(page_b,
        scope: scope_b,
        queue: owner[:queue],
        retries: 0,
        store: Store,
        req_options: req_options
      )

    assert guest[:queue_owner] == nil

    assert {:normal, %{data: data}, _demand} = OPQ.info(owner[:queue])
    refute :queue.is_empty(data)
    assert :ok = Crawler.stop(guest)
    refute Crawler.running?(guest)
    assert Crawler.running?(owner)
    assert Process.alive?(owner[:queue])
    assert Process.alive?(owner[:queue_owner])

    send(handler, :release)

    wait(fn ->
      refute Crawler.running?(owner)
      assert Agent.get(hits, & &1) == 0
      assert %Store.Page{body: "owner"} = Store.find_processed({page_a, scope_a})
      refute Store.find({page_b, scope_b})
    end)

    {:ok, again} =
      start_crawl(page_b,
        scope: scope_b,
        queue: owner[:queue],
        max_pages: 1,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(again)
      assert Agent.get(hits, & &1) == 1
      assert %Store.Page{body: "guest"} = Store.find_processed({page_b, scope_b})
      assert Store.find_processed({page_a, scope_a})
    end)
  end

  test "stopping the queue owner releases a sibling's in-flight url", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    scope_a = unique_scope("lifecycle-abandon-owner")
    scope_b = unique_scope("lifecycle-abandon-guest")
    page_a = "#{url}/lifecycle/abandon-a"
    page_b = "#{url}/lifecycle/abandon-b"
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    for path <- ["/lifecycle/abandon-a", "/lifecycle/abandon-b"] do
      ReqTestSite.stub(site, "GET", path, fn conn ->
        count = Agent.get_and_update(hits, fn count -> {count + 1, count + 1} end)
        send(parent, {:started, path, self()})

        if count <= 2 do
          receive do
            :release ->
              conn
              |> Plug.Conn.put_resp_header("content-type", "text/html")
              |> Plug.Conn.resp(200, path)
          after
            10_000 ->
              conn
              |> Plug.Conn.put_resp_header("content-type", "text/html")
              |> Plug.Conn.resp(200, "late")
          end
        else
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.resp(200, path)
        end
      end)
    end

    {:ok, owner} =
      start_crawl(page_a,
        scope: scope_a,
        workers: 2,
        timeout: 10_000,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    {:ok, guest} =
      start_crawl(page_b,
        scope: scope_b,
        queue: owner[:queue],
        timeout: 10_000,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    assert_receive {:started, "/lifecycle/abandon-a", handler_a}, 1_000
    assert_receive {:started, "/lifecycle/abandon-b", handler_b}, 1_000
    on_exit(fn -> send(handler_a, :release) end)
    on_exit(fn -> send(handler_b, :release) end)

    assert :ok = Crawler.stop(owner)
    refute Process.alive?(owner[:queue])
    refute Crawler.running?(owner)
    refute Crawler.running?(guest)
    assert Store.inflight_count(scope_a) == 0
    assert Store.inflight_count(scope_b) == 0
    refute Store.find({page_a, scope_a})
    refute Store.find({page_b, scope_b})

    send(handler_a, :release)
    send(handler_b, :release)

    {:ok, again} =
      start_crawl(page_b,
        scope: scope_b,
        workers: 1,
        max_pages: 1,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(again)
      assert %Store.Page{body: "/lifecycle/abandon-b"} = Store.find_processed({page_b, scope_b})
    end)

    assert Agent.get(hits, & &1) == 3
  end
end
