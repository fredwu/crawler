defmodule Crawler.CrawlLifecycleTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  defmodule BoomParser do
    @moduledoc false
    @behaviour Crawler.Parser.Spec

    def parse(%{body: body} = page) when is_binary(body) do
      if String.contains?(body, "boom"), do: raise("boom")

      Crawler.Parser.parse(page)
    end

    def parse(other), do: Crawler.Parser.parse(other)
  end

  defmodule Probe do
    @moduledoc false
    @behaviour Crawler.Fetcher.Modifier.Spec

    def headers(opts) do
      if is_pid(opts[:probe]) do
        send(opts[:probe], {:fetch, opts[:url], opts[:alias_url], opts[:headers]})
      end

      []
    end

    def opts(_opts), do: []
  end

  defmodule Watch do
    @moduledoc false
    @behaviour Crawler.Scraper.Spec

    def scrape(%{opts: opts, url: url} = page) do
      if is_pid(opts[:probe]),
        do: send(opts[:probe], {:parsed, url, opts[:alias_url], opts[:headers]})

      {:ok, page}
    end
  end

  test "stopping a crawl shuts down its processes and releases its slots", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    scope = scope("stop")
    page = "#{url}/lifecycle/stop"
    supervisor_before = supervisor_links()
    {:ok, requests} = Agent.start(fn -> 0 end)

    ReqTestSite.stub(site, "GET", "/lifecycle/stop", fn conn ->
      count = Agent.get_and_update(requests, fn count -> {count, count + 1} end)
      send(parent, {:started, self()})

      if count == 0 do
        receive do
          :release -> Plug.Conn.resp(conn, 200, "stopped")
        after
          10_000 -> Plug.Conn.resp(conn, 200, "late")
        end
      else
        Plug.Conn.resp(conn, 200, "stopped")
      end
    end)

    {:ok, opts} =
      Crawler.crawl(page,
        scope: scope,
        workers: 1,
        interval: 50,
        timeout: 10_000,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    assert_receive {:started, handler}, 1_000
    on_exit(fn -> send(handler, :release) end)

    owner = opts[:queue_owner]
    queue = opts[:queue]
    assert is_pid(owner)
    assert Process.alive?(owner)
    assert Process.alive?(queue)
    assert is_pid(Process.whereis(:"opq-#{inspect(queue)}"))
    {:links, owner_links} = Process.info(owner, :links)
    flags = Process.info(self(), :trap_exit)

    assert :ok = Crawler.stop(opts)

    assert Process.info(self(), :trap_exit) == flags
    refute Process.alive?(queue)
    refute Process.alive?(owner)
    refute Process.whereis(:"opq-#{inspect(queue)}")

    supervisor = Process.whereis(Crawler.QueueSupervisor)

    Enum.each(owner_links -- [supervisor], fn pid ->
      refute Process.alive?(pid)
    end)

    supervisor_after = supervisor_links()
    assert Enum.sort(supervisor_before) == Enum.sort(supervisor_after)
    assert Store.inflight_count(scope) == 0
    assert Store.ops_count(scope) == 0
    refute Crawler.running?(opts)
    refute Store.find({page, scope})

    send(handler, :release)

    {:ok, again} =
      Crawler.crawl(page,
        scope: scope,
        workers: 1,
        max_pages: 1,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(again)
      assert %Store.Page{body: "stopped"} = Store.find_processed({page, scope})
      assert Store.ops_count(scope) == 1
      assert Store.inflight_count(scope) == 0
    end)
  end

  test "the queue supervisor shuts the queue down", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = scope("supervisor")
    page = "#{url}/lifecycle/supervisor"
    supervisor_before = supervisor_links()

    ReqTestSite.expect_once(site, "GET", "/lifecycle/supervisor", fn conn ->
      Plug.Conn.resp(conn, 200, "owned")
    end)

    {:ok, opts} =
      Crawler.crawl(page,
        scope: scope,
        workers: 1,
        interval: 50,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({page, scope})
    end)

    owner = opts[:queue_owner]
    queue = opts[:queue]
    {:links, owner_links} = Process.info(owner, :links)
    task = Task.async(fn -> DynamicSupervisor.terminate_child(Crawler.QueueSupervisor, owner) end)

    assert :ok = Task.await(task, 2_000)
    refute Process.alive?(owner)
    refute Process.alive?(queue)
    refute Process.whereis(:"opq-#{inspect(queue)}")

    supervisor = Process.whereis(Crawler.QueueSupervisor)

    Enum.each(owner_links -- [supervisor], fn pid ->
      refute Process.alive?(pid)
    end)

    supervisor_after = supervisor_links()
    assert Enum.sort(supervisor_before) == Enum.sort(supervisor_after)
    assert Store.inflight_count(scope) == 0
    assert Store.find_processed({page, scope})
  end

  test "a crawl that finishes keeps its pages when another scope stops", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    kept_scope = scope("kept")
    stopped_scope = scope("other-stop")
    kept = "#{url}/lifecycle/kept"
    stopped = "#{url}/lifecycle/other-stop"

    ReqTestSite.expect_once(site, "GET", "/lifecycle/kept", fn conn ->
      Plug.Conn.resp(conn, 200, "kept")
    end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/other-stop", fn conn ->
      Plug.Conn.resp(conn, 200, "gone")
    end)

    {:ok, kept_opts} =
      Crawler.crawl(kept,
        scope: kept_scope,
        workers: 1,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    {:ok, stopped_opts} =
      Crawler.crawl(stopped,
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
    scope_a = scope("queue-a")
    scope_b = scope("queue-b")
    page_a = "#{url}/lifecycle/owned-a"
    page_b = "#{url}/lifecycle/owned-b"

    ReqTestSite.stub(site, "GET", "/lifecycle/owned-a", fn conn ->
      send(parent, {:started, :a, self()})

      receive do
        :release -> Plug.Conn.resp(conn, 200, "A")
      after
        10_000 -> Plug.Conn.resp(conn, 200, "late")
      end
    end)

    ReqTestSite.stub(site, "GET", "/lifecycle/owned-b", fn conn ->
      send(parent, {:started, :b, self()})

      receive do
        :release -> Plug.Conn.resp(conn, 200, "B")
      after
        10_000 -> Plug.Conn.resp(conn, 200, "late")
      end
    end)

    {:ok, first} =
      Crawler.crawl(page_a,
        scope: scope_a,
        workers: 1,
        timeout: 10_000,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    {:ok, second} =
      Crawler.crawl(page_b,
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
    scope_a = scope("shared-owner")
    scope_b = scope("shared-guest")
    page_a = "#{url}/lifecycle/shared-a"
    page_b = "#{url}/lifecycle/shared-b"

    ReqTestSite.expect_once(site, "GET", "/lifecycle/shared-a", fn conn ->
      Plug.Conn.resp(conn, 200, "owner")
    end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/shared-b", fn conn ->
      Plug.Conn.resp(conn, 200, "guest")
    end)

    {:ok, owner} =
      Crawler.crawl(page_a,
        scope: scope_a,
        workers: 2,
        interval: 20,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    {:ok, guest} =
      Crawler.crawl(page_b,
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
    scope_a = scope("guest-owner")
    scope_b = scope("guest-stop")
    page_a = "#{url}/lifecycle/guest-a"
    page_b = "#{url}/lifecycle/guest-b"
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    ReqTestSite.stub(site, "GET", "/lifecycle/guest-a", fn conn ->
      send(parent, {:started, self()})

      receive do
        :release -> Plug.Conn.resp(conn, 200, "owner")
      after
        10_000 -> Plug.Conn.resp(conn, 200, "late")
      end
    end)

    ReqTestSite.stub(site, "GET", "/lifecycle/guest-b", fn conn ->
      Agent.update(hits, &(&1 + 1))
      Plug.Conn.resp(conn, 200, "guest")
    end)

    {:ok, owner} =
      Crawler.crawl(page_a,
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
      Crawler.crawl(page_b,
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
      Crawler.crawl(page_b,
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
    scope_a = scope("abandon-owner")
    scope_b = scope("abandon-guest")
    page_a = "#{url}/lifecycle/abandon-a"
    page_b = "#{url}/lifecycle/abandon-b"
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    for path <- ["/lifecycle/abandon-a", "/lifecycle/abandon-b"] do
      ReqTestSite.stub(site, "GET", path, fn conn ->
        count = Agent.get_and_update(hits, fn count -> {count + 1, count + 1} end)
        send(parent, {:started, path, self()})

        if count <= 2 do
          receive do
            :release -> Plug.Conn.resp(conn, 200, path)
          after
            10_000 -> Plug.Conn.resp(conn, 200, "late")
          end
        else
          Plug.Conn.resp(conn, 200, path)
        end
      end)
    end

    {:ok, owner} =
      Crawler.crawl(page_a,
        scope: scope_a,
        workers: 2,
        timeout: 10_000,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    {:ok, guest} =
      Crawler.crawl(page_b,
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
      Crawler.crawl(page_b,
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

  test "stopping a caller-owned queue does not stop that queue", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = scope("external")
    kept_scope = scope("external-kept")
    page = "#{url}/lifecycle/external"
    kept = "#{url}/lifecycle/external-kept"
    {:links, links_before} = Process.info(self(), :links)
    {:ok, queue} = OPQ.init(worker: Crawler.Dispatcher.Worker, workers: 1, timeout: 5_000)
    {:links, links_after} = Process.info(self(), :links)
    spawned = links_after -- links_before
    Enum.each(spawned, &Process.unlink/1)
    on_exit(fn -> stop_processes(spawned) end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/external-kept", fn conn ->
      Plug.Conn.resp(conn, 200, "kept")
    end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/external", fn conn ->
      Plug.Conn.resp(conn, 200, "external")
    end)

    {:ok, kept_opts} =
      Crawler.crawl(kept,
        scope: kept_scope,
        workers: 1,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    {:ok, opts} =
      Crawler.crawl(page,
        scope: scope,
        queue: queue,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    assert opts[:queue] == queue
    assert opts[:queue_owner] == nil

    wait(fn ->
      refute Crawler.running?(kept_opts)
      refute Crawler.running?(opts)
      assert Store.find_processed({page, scope})
      assert Store.find_processed({kept, kept_scope})
    end)

    flags = Process.info(self(), :trap_exit)
    assert :ok = Crawler.stop(opts)
    assert Process.info(self(), :trap_exit) == flags
    assert Process.alive?(queue)
    assert {:normal, %{data: {[], []}}, 1} = OPQ.info(queue)
    refute Store.find({page, scope})
    assert Store.ops_count(scope) == 0
    assert Store.inflight_count(scope) == 0
    assert %Store.Page{body: "kept"} = Store.find_processed({kept, kept_scope})
    refute Crawler.running?(opts)
  end

  test "linked pages fetch a missing url once and a later crawl can retry it", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = scope("missing")
    entry = "#{url}/lifecycle/missing"
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/missing", fn conn ->
      Plug.Conn.resp(conn, 200, """
      <a href="#{entry}/a">a</a>
      <a href="#{entry}/b">b</a>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/missing/a", fn conn ->
      Plug.Conn.resp(conn, 200, ~s(<a href="#{entry}/gone">gone</a>))
    end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/missing/b", fn conn ->
      Plug.Conn.resp(conn, 200, ~s(<a href="#{entry}/gone">gone</a>))
    end)

    ReqTestSite.stub(site, "GET", "/lifecycle/missing/gone", fn conn ->
      Agent.update(hits, &(&1 + 1))
      Plug.Conn.resp(conn, 404, "missing")
    end)

    {:ok, opts} =
      Crawler.crawl(entry,
        scope: scope,
        workers: 2,
        max_depths: 3,
        retries: 2,
        req_options: req_options
      )

    wait(2_000, fn ->
      refute Crawler.running?(opts)
      assert Agent.get(hits, & &1) == 1
      refute Store.find({"#{entry}/gone", scope})
      assert Store.find_processed({entry, scope})
    end)

    {:ok, again} =
      Crawler.crawl("#{entry}/gone",
        scope: scope,
        workers: 1,
        retries: 0,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(again)
      assert Agent.get(hits, & &1) == 2
    end)
  end

  test "linked pages retry a failing url once per crawl", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = scope("retry-once")
    entry = "#{url}/lifecycle/retry-once"
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/retry-once", fn conn ->
      Plug.Conn.resp(conn, 200, """
      <a href="#{entry}/a">a</a>
      <a href="#{entry}/b">b</a>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/retry-once/a", fn conn ->
      Plug.Conn.resp(conn, 200, ~s(<a href="#{entry}/down">down</a>))
    end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/retry-once/b", fn conn ->
      Plug.Conn.resp(conn, 200, ~s(<a href="#{entry}/down">down</a>))
    end)

    ReqTestSite.stub(site, "GET", "/lifecycle/retry-once/down", fn conn ->
      Agent.update(hits, &(&1 + 1))
      Plug.Conn.resp(conn, 500, "down")
    end)

    {:ok, opts} =
      Crawler.crawl(entry,
        scope: scope,
        workers: 2,
        max_depths: 3,
        retries: 2,
        req_options: req_options
      )

    wait(2_000, fn ->
      refute Crawler.running?(opts)
      assert Agent.get(hits, & &1) == 3
      refute Store.find({"#{entry}/down", scope})
    end)

    {:ok, again} =
      Crawler.crawl("#{entry}/down",
        scope: scope,
        workers: 1,
        retries: 2,
        req_options: req_options
      )

    wait(2_000, fn ->
      refute Crawler.running?(again)
      assert Agent.get(hits, & &1) == 6
    end)
  end

  test "a crashed page can be fetched again without force", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = scope("crash")
    page = "#{url}/lifecycle/crash"
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    ReqTestSite.stub(site, "GET", "/lifecycle/crash", fn conn ->
      Agent.update(hits, &(&1 + 1))
      Plug.Conn.resp(conn, 200, "boom")
    end)

    ExUnit.CaptureLog.capture_log(fn ->
      {:ok, failed} =
        Crawler.crawl(page,
          scope: scope,
          workers: 1,
          retries: 0,
          parser: __MODULE__.BoomParser,
          store: Store,
          req_options: req_options
        )

      wait(fn ->
        refute Crawler.running?(failed)
        refute Store.find({page, scope})
        assert Agent.get(hits, & &1) == 1
      end)
    end)

    {:ok, again} =
      Crawler.crawl(page,
        scope: scope,
        workers: 1,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(again)
      assert Agent.get(hits, & &1) == 2
      assert %Store.Page{body: "boom"} = Store.find_processed({page, scope})
    end)
  end

  test "a linked page does not inherit the parent's redirect or headers", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    from = "#{url}/lifecycle/inherit/from"
    landing = "#{url}/lifecycle/inherit/landing"
    child = "#{url}/lifecycle/inherit/child"

    ReqTestSite.expect(site, "GET", "/lifecycle/inherit/from", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", landing)
      |> Plug.Conn.resp(302, "")
    end)

    ReqTestSite.expect(site, "GET", "/lifecycle/inherit/landing", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, ~s(<a href="#{child}">child</a>))
    end)

    ReqTestSite.expect(site, "GET", "/lifecycle/inherit/child", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "child")
    end)

    {:ok, opts} =
      Crawler.crawl(from,
        scope: scope("inherit"),
        workers: 2,
        retries: 0,
        modifier: __MODULE__.Probe,
        scraper: __MODULE__.Watch,
        probe: parent,
        store: Store,
        req_options: req_options
      )

    assert_receive {:parsed, ^from, ^landing, headers}, 2_000
    assert is_list(headers)
    assert_receive {:fetch, ^child, nil, nil}, 2_000

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({child, opts[:scope]})
    end)
  end

  test "a slower save loses when a newer fetch of the same page finishes first", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    scope = scope("slow-save")
    page = "#{url}/lifecycle/slow-save"
    directory = "lifecycle-slow-save-#{System.unique_integer([:positive])}"
    file = offline(directory, site, "/lifecycle/slow-save")
    {:ok, hits} = Agent.start_link(fn -> 0 end)
    {:ok, holders} = Agent.start(fn -> [] end)
    release_holders_on_exit(holders)

    ReqTestSite.stub(site, "GET", "/lifecycle/slow-save", fn conn ->
      count = Agent.get_and_update(hits, fn count -> {count, count + 1} end)
      body = if count == 0, do: "OLD", else: "NEW"

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, body)
    end)

    hook = fn ->
      holder = self()
      Agent.update(holders, &[holder | &1])
      send(parent, {:staged, holder})

      receive do
        :release_save -> :ok
      after
        5_000 -> :ok
      end
    end

    {:ok, _first} =
      Crawler.crawl(page,
        scope: scope,
        workers: 1,
        retries: 0,
        store: Store,
        save_to: tmp(directory),
        before_publish: hook,
        req_options: req_options
      )

    assert_receive {:staged, holder}, 2_000

    {:ok, second} =
      Crawler.crawl(page,
        scope: scope,
        force: true,
        workers: 1,
        retries: 0,
        store: Store,
        save_to: tmp(directory),
        req_options: req_options
      )

    wait(2_000, fn ->
      refute Crawler.running?(second)
      assert File.read!(file) == "NEW"
      assert %Store.Page{body: "NEW"} = Store.find_processed({page, scope})
    end)

    assert Process.alive?(holder)
    send(holder, :release_save)

    wait(fn ->
      refute Process.alive?(holder)
      assert File.read!(file) == "NEW"
      assert %Store.Page{body: "NEW"} = Store.find_processed({page, scope})
    end)
  end

  test "concurrent saves of one path keep one complete body", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    page = "#{url}/lifecycle/bodies"
    scope_a = scope("body-a")
    scope_b = scope("body-b")
    directory = "lifecycle-bodies-#{System.unique_integer([:positive])}"
    file = offline(directory, site, "/lifecycle/bodies")
    {:ok, hits} = Agent.start_link(fn -> 0 end)
    {:ok, holders} = Agent.start(fn -> [] end)
    release_holders_on_exit(holders)

    ReqTestSite.stub(site, "GET", "/lifecycle/bodies", fn conn ->
      count = Agent.get_and_update(hits, fn count -> {count, count + 1} end)

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "BODY-#{count}")
    end)

    hook = fn ->
      holder = self()
      Agent.update(holders, &[holder | &1])
      send(parent, {:staged, holder})

      receive do
        :release_save -> :ok
      after
        5_000 -> :ok
      end
    end

    crawl = fn scope ->
      Crawler.crawl(page,
        scope: scope,
        workers: 1,
        retries: 0,
        store: Store,
        save_to: tmp(directory),
        before_publish: hook,
        req_options: req_options
      )
    end

    {:ok, first} = crawl.(scope_a)
    {:ok, second} = crawl.(scope_b)
    assert first[:queue] != second[:queue]

    assert_receive {:staged, holder_a}, 2_000
    assert_receive {:staged, holder_b}, 2_000
    refute File.exists?(file)

    send(holder_a, :release_save)
    send(holder_b, :release_save)

    wait(2_000, fn ->
      refute Crawler.running?(first)
      refute Crawler.running?(second)
      refute Process.alive?(holder_a)
      refute Process.alive?(holder_b)

      assert %Store.Page{body: body_a} = Store.find_processed({page, scope_a})
      assert %Store.Page{body: body_b} = Store.find_processed({page, scope_b})
      assert body_a != body_b
      assert body_a in ["BODY-0", "BODY-1"]
      assert body_b in ["BODY-0", "BODY-1"]
      assert File.read!(file) in [body_a, body_b]
    end)
  end

  test "stopping the scope that started a queue stops it", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = scope("same-scope-queue")
    first_page = "#{url}/lifecycle/same-scope-a"
    second_page = "#{url}/lifecycle/same-scope-b"

    ReqTestSite.expect_once(site, "GET", "/lifecycle/same-scope-a", fn conn ->
      Plug.Conn.resp(conn, 200, "a")
    end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/same-scope-b", fn conn ->
      Plug.Conn.resp(conn, 200, "b")
    end)

    {:ok, creator} =
      Crawler.crawl(first_page,
        scope: scope,
        workers: 1,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(creator)
      assert Store.find_processed({first_page, scope})
    end)

    {:ok, again} =
      Crawler.crawl(second_page,
        scope: scope,
        queue: creator[:queue],
        retries: 0,
        store: Store,
        req_options: req_options
      )

    assert again[:queue] == creator[:queue]
    assert again[:queue_owner] == nil

    wait(fn ->
      refute Crawler.running?(again)
      assert Store.find_processed({second_page, scope})
    end)

    assert :ok = Crawler.stop(again)
    refute Process.alive?(creator[:queue])
    refute Process.alive?(creator[:queue_owner])
    refute Store.find({first_page, scope})
    refute Store.find({second_page, scope})
  end

  test "a dead queue does not pin the scope", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = scope("dead-queue")
    page = "#{url}/lifecycle/dead-queue"
    {:ok, hits} = Agent.start(fn -> 0 end)
    on_exit(fn -> if Process.alive?(hits), do: Agent.stop(hits) end)
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, _, _, _}

    ReqTestSite.stub(site, "GET", "/lifecycle/dead-queue", fn conn ->
      Agent.update(hits, &(&1 + 1))
      Plug.Conn.resp(conn, 404, "missing")
    end)

    assert {:ok, _} =
             Crawler.crawl(page,
               scope: scope,
               queue: dead,
               retries: 0,
               req_options: req_options
             )

    Process.sleep(50)
    assert Agent.get(hits, & &1) == 0

    {:ok, opts} =
      Crawler.crawl(page,
        scope: scope,
        workers: 1,
        retries: 0,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)
      assert Agent.get(hits, & &1) == 1
      refute Store.find({page, scope})
    end)

    {:ok, again} =
      Crawler.crawl(page,
        scope: scope,
        queue: opts[:queue],
        retries: 0,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(again)
      assert Agent.get(hits, & &1) == 2
      refute Store.find({page, scope})
    end)
  end

  test "stopping a crawl during a save removes its temp file", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    scope = scope("stop-save")
    page = "#{url}/lifecycle/stop-save"
    directory = "lifecycle-stop-save-#{System.unique_integer([:positive])}"
    file = offline(directory, site, "/lifecycle/stop-save")
    dir = Path.dirname(file)
    {:ok, holders} = Agent.start(fn -> [] end)
    release_holders_on_exit(holders)

    ReqTestSite.stub(site, "GET", "/lifecycle/stop-save", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "PARTIAL")
    end)

    hook = fn ->
      holder = self()
      Agent.update(holders, &[holder | &1])
      send(parent, :staged)

      receive do
        :release_save -> :ok
      after
        5_000 -> :ok
      end
    end

    {:ok, opts} =
      Crawler.crawl(page,
        scope: scope,
        workers: 1,
        retries: 0,
        store: Store,
        save_to: tmp(directory),
        before_publish: hook,
        req_options: req_options
      )

    assert_receive :staged, 2_000
    assert File.dir?(dir)
    assert Enum.any?(File.ls!(dir), &String.ends_with?(&1, ".tmp"))

    assert :ok = Crawler.stop(opts)

    wait(2_000, fn ->
      refute Process.alive?(opts[:queue])
      assert File.ls!(dir) |> Enum.filter(&String.ends_with?(&1, ".tmp")) == []
    end)

    refute File.exists?(file)
    refute Store.find({page, scope})
  end

  defp scope(name), do: "lifecycle-#{name}-#{System.unique_integer([:positive])}"

  defp offline(directory, site, path) do
    tmp("#{directory}/#{site.path}#{path}", "__index.html")
  end

  defp supervisor_links do
    {:links, links} = Process.info(Process.whereis(Crawler.QueueSupervisor), :links)
    links
  end

  defp release_holders_on_exit(holders) do
    on_exit(fn ->
      if Process.alive?(holders) do
        holders |> Agent.get(& &1) |> Enum.each(&send(&1, :release_save))
        Agent.stop(holders)
      end
    end)
  end

  defp stop_processes(pids) do
    {supervisors, others} = Enum.split_with(pids, &supervisor_process?/1)

    task =
      Task.async(fn ->
        Enum.each(supervisors ++ others, &stop_process/1)
      end)

    Task.await(task, 5_000)
  end

  defp stop_process(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :shutdown, 2_000)
      catch
        :exit, _ ->
          if Process.alive?(pid), do: Process.exit(pid, :kill)
      end
    end
  end

  defp supervisor_process?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> match?({:supervisor, _, _}, dictionary[:"$initial_call"])
      _ -> false
    end
  end
end
