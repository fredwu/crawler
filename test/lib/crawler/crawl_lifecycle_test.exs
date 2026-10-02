defmodule Crawler.CrawlLifecycleTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  test "stopping a crawl shuts down its processes and releases its slots", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    scope = unique_scope("lifecycle-stop")
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
      start_crawl(page,
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
      start_crawl(page,
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
    scope = unique_scope("lifecycle-supervisor")
    page = "#{url}/lifecycle/supervisor"
    supervisor_before = supervisor_links()

    ReqTestSite.expect_once(site, "GET", "/lifecycle/supervisor", fn conn ->
      Plug.Conn.resp(conn, 200, "owned")
    end)

    {:ok, opts} =
      start_crawl(page,
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

  test "stopping a caller-owned queue does not stop that queue", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("lifecycle-external")
    kept_scope = unique_scope("lifecycle-external-kept")
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
      start_crawl(kept,
        scope: kept_scope,
        workers: 1,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    {:ok, opts} =
      start_crawl(page,
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

  test "stopping the scope that started a queue stops it", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("lifecycle-same-scope-queue")
    first_page = "#{url}/lifecycle/same-scope-a"
    second_page = "#{url}/lifecycle/same-scope-b"

    ReqTestSite.expect_once(site, "GET", "/lifecycle/same-scope-a", fn conn ->
      Plug.Conn.resp(conn, 200, "a")
    end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/same-scope-b", fn conn ->
      Plug.Conn.resp(conn, 200, "b")
    end)

    {:ok, creator} =
      start_crawl(first_page,
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
      start_crawl(second_page,
        scope: scope,
        queue: creator[:queue],
        retries: 0,
        store: Store,
        req_options: req_options
      )

    assert again[:queue] == creator[:queue]
    assert again[:queue_owner] == creator[:queue_owner]

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
    scope = unique_scope("lifecycle-dead-queue")
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
             start_crawl(page,
               scope: scope,
               queue: dead,
               retries: 0,
               req_options: req_options
             )

    Process.sleep(50)
    assert Agent.get(hits, & &1) == 0

    {:ok, opts} =
      start_crawl(page,
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
      start_crawl(page,
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

  defp supervisor_links do
    {:links, links} = Process.info(Process.whereis(Crawler.QueueSupervisor), :links)
    links
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
