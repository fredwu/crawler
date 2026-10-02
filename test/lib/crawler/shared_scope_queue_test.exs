defmodule Crawler.SharedScopeQueueTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  for event <- [:stop, :feeder_failure] do
    test "#{event} retires only one queue's work in a shared scope", context do
      exercise_retirement(unquote(event), context)
    end
  end

  test "an unavailable named queue fails initial enqueue and retry without creating a queue", %{
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("unavailable-named-queue")
    name = :crawler_test_unavailable_queue
    page = url <> "/unavailable-queue"
    generation = Store.generation(scope)
    children = DynamicSupervisor.which_children(Crawler.QueueSupervisor)
    opts = [scope: scope, queue: name, req_options: req_options]
    on_exit(fn -> Store.drop_scope(scope) end)
    assert Process.whereis(name) == nil

    assert {:error, {:queue_unavailable, ^name}} = Crawler.crawl(page, opts)
    assert DynamicSupervisor.which_children(Crawler.QueueSupervisor) == children
    assert {:error, {:queue_unavailable, ^name}} = Crawler.crawl(page, opts)
    assert DynamicSupervisor.which_children(Crawler.QueueSupervisor) == children

    assert {:error, {:queue_unavailable, ^name}} =
             Crawler.QueueHandler.enqueue(%{
               url: page,
               scope: scope,
               generation: generation,
               queue: name
             })

    assert DynamicSupervisor.which_children(Crawler.QueueSupervisor) == children
    assert Process.whereis(name) == nil
    refute Store.find({page, scope})
    assert Store.queue_scopes(name) == []
    assert Store.generation(scope) == generation
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
    assert Store.ops_count(scope) == 0
  end

  test "a registered external queue uses one PID ownership identity", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    scope = unique_scope("named-queue")
    name = :crawler_test_external_queue
    queue = external_queue(name)
    on_exit(fn -> Store.drop_scope(scope) end)

    ReqTestSite.expect_once(site, "GET", "/named-queue", fn conn ->
      Plug.Conn.resp(conn, 200, "named")
    end)

    ReqTestSite.expect_once(site, "GET", "/named-queue/resumed", fn conn ->
      send(parent, :resumed_fetch)
      Plug.Conn.resp(conn, 200, "resumed")
    end)

    opts = start_crawl(url <> "/named-queue", scope, req_options, queue: name)
    assert opts[:queue] == queue
    assert opts[:queue_name] == name
    assert opts[:queue_owner] == nil
    assert Store.queue_record(queue) == nil

    await_idle(opts)
    assert Store.find_processed({url <> "/named-queue", scope})
    assert Store.ops_count(scope) == 1
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
    assert Store.queue_scopes(queue) == [scope]

    Crawler.pause(opts)
    assert {:paused, _, _} = OPQ.info(name)
    assert {:ok, paused} = start_crawl(url <> "/named-queue/resumed", opts)
    assert paused[:queue] == queue
    assert paused[:queue_name] == name
    assert paused[:queue_owner] == nil
    assert Store.pending_count(scope) == 1
    assert Store.inflight_count(scope) == 0
    assert {:paused, %OPQ.Queue{data: data}, _} = OPQ.info(name)
    assert :queue.len(data) == 1
    refute Crawler.running?(paused)
    refute_receive :resumed_fetch

    Crawler.resume(paused)
    assert_receive :resumed_fetch, 2_000
    await_idle(paused)
    assert Store.find_processed({url <> "/named-queue/resumed", scope})
    assert Store.ops_count(scope) == 2
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
    assert Store.queue_scopes(queue) == [scope]
    assert Store.queue_record(queue) == nil

    assert :ok = Crawler.stop(paused)
    assert Process.alive?(queue)
    refute Store.find({url <> "/named-queue", scope})
    refute Store.find({url <> "/named-queue/resumed", scope})
    assert Process.whereis(name) == queue
    assert Store.queue_scopes(queue) == []
  end

  test "a rebound queue name cannot redirect controls or status for old crawl options", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    scope = unique_scope("rebound-old-queue")
    replacement_scope = unique_scope("rebound-new-queue")
    name = :crawler_test_rebound_queue
    old_queue = external_queue(name)
    on_exit(fn -> Store.drop_scope(scope) end)
    on_exit(fn -> Store.drop_scope(replacement_scope) end)

    ReqTestSite.expect_once(site, "GET", "/rebound/initial", fn conn ->
      Plug.Conn.resp(conn, 200, "initial")
    end)

    ReqTestSite.expect_once(site, "GET", "/rebound/old", fn conn ->
      send(parent, {:old_queue_fetch, self()})

      receive do
        :release -> Plug.Conn.resp(conn, 200, "old")
      end
    end)

    ReqTestSite.expect_once(site, "GET", "/rebound/new", fn conn ->
      send(parent, :new_queue_fetch)
      Plug.Conn.resp(conn, 200, "new")
    end)

    old = start_crawl(url <> "/rebound/initial", scope, req_options, queue: name)
    await_idle(old)
    assert old[:queue] == old_queue
    assert old[:queue_name] == name
    assert Process.unregister(name)
    replacement_queue = external_queue(name)
    assert Process.whereis(name) == replacement_queue

    Crawler.pause(old)
    assert {:paused, _, _} = GenStage.call(old_queue, :info)
    assert {:normal, _, _} = OPQ.info(name)
    assert {:ok, pending_old} = start_crawl(url <> "/rebound/old", old)
    assert pending_old[:queue] == old_queue
    refute pending_old[:queue_name]
    assert Store.pending_count(scope) == 1
    refute Crawler.running?(old)
    refute Crawler.running?(pending_old)
    assert {:normal, _, _} = OPQ.info(name)

    OPQ.pause(replacement_queue)
    assert {:paused, _, _} = OPQ.info(name)
    replacement = start_crawl(url <> "/rebound/new", replacement_scope, req_options, queue: name)
    assert replacement[:queue] == replacement_queue
    assert Store.pending_count(replacement_scope) == 1

    Crawler.resume(old)
    assert_receive {:old_queue_fetch, handler}, 2_000
    on_exit(fn -> send(handler, :release) end)
    assert Crawler.running?(old)
    assert {:paused, _, _} = OPQ.info(name)
    refute_receive :new_queue_fetch

    send(handler, :release)
    await_idle(pending_old)
    assert Store.find_processed({url <> "/rebound/old", scope})
    assert :ok = Crawler.stop(old)
    assert Process.alive?(old_queue)
    assert Process.alive?(replacement_queue)
    assert Store.queue_record(old_queue) == nil
    assert Store.queue_record(replacement_queue) == nil
    assert Store.queue_scopes(old_queue) == []
    assert Store.queue_scopes(replacement_queue) == [replacement_scope]
    assert Store.pending_count(replacement_scope) == 1

    Crawler.resume(replacement)
    assert_receive :new_queue_fetch, 2_000
    await_idle(replacement)
    assert Store.find_processed({url <> "/rebound/new", replacement_scope})
    assert :ok = Crawler.stop(replacement)
    assert Process.alive?(old_queue)
    assert Process.alive?(replacement_queue)
    assert Process.whereis(name) == replacement_queue
    assert Store.queue_scopes(replacement_queue) == []
  end

  defp external_queue(name) do
    {:links, before} = Process.info(self(), :links)
    {:ok, queue} = OPQ.init(name: name, worker: Crawler.Dispatcher.Worker, workers: 1)
    {:links, after_start} = Process.info(self(), :links)
    children = after_start -- before
    Enum.each(children, &Process.unlink/1)
    on_exit(fn -> Enum.each(children, &stop_external_process/1) end)
    queue
  end

  defp stop_external_process(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
  catch
    :exit, _ -> :ok
  end

  defp exercise_retirement(event, %{site: site, url: url, req_options: req_options}) do
    parent = self()
    owner_scope = unique_scope("retire-owner")
    shared_scope = unique_scope("retire-shared")
    {:ok, requests} = Agent.start_link(fn -> %{} end)

    install_routes(site, parent, requests)

    owner = start_crawl(url <> "/retire/owner", owner_scope, req_options, workers: 2)
    on_exit(fn -> Crawler.stop(owner) end)
    assert_receive {:blocked, :owner, owner_handler}, 2_000
    on_exit(fn -> send(owner_handler, :release) end)

    lost = start_crawl(url <> "/retire/lost", shared_scope, req_options, queue: owner[:queue])
    assert_receive {:blocked, :lost, lost_handler}, 2_000
    on_exit(fn -> send(lost_handler, :release) end)

    start_crawl(url <> "/retire/lost-queued", shared_scope, req_options, queue: owner[:queue])

    survivor = start_crawl(url <> "/retire/kept", shared_scope, req_options)
    on_exit(fn -> Crawler.stop(survivor) end)

    wait(fn ->
      assert Store.find_processed({url <> "/retire/kept", shared_scope})
      assert Store.pending_count(shared_scope) == 2
      assert Store.inflight_count(shared_scope) == 1
    end)

    start_crawl(url <> "/retire/live", shared_scope, req_options, queue: survivor[:queue])
    assert_receive {:blocked, :live, live_handler}, 2_000
    on_exit(fn -> send(live_handler, :release) end)

    start_crawl(url <> "/retire/live-queued", shared_scope, req_options, queue: survivor[:queue])

    assert Store.pending_count(shared_scope) == 4
    assert Store.inflight_count(shared_scope) == 2
    assert Store.ops_count(shared_scope) == 1

    monitors = monitor_owned_processes(owner, [owner_handler, lost_handler])
    retire(owner, event)
    await_down(monitors)

    assert Process.alive?(survivor[:queue_owner])
    assert Process.alive?(survivor[:queue])
    assert Process.alive?(live_handler)
    assert Store.generation(shared_scope) == survivor[:generation]
    assert Store.pending_count(shared_scope) == 2
    assert Store.inflight_count(shared_scope) == 1
    assert Store.ops_count(shared_scope) == 1
    assert Store.find_processed({url <> "/retire/kept", shared_scope})
    assert Store.find({url <> "/retire/live", shared_scope})
    refute Store.find({url <> "/retire/lost", shared_scope})
    refute Crawler.running?(owner)
    refute Crawler.running?(lost)
    assert Crawler.running?(survivor)
    assert Map.get(Agent.get(requests, & &1), "/retire/lost-queued", 0) == 0

    assert :stale = Store.finish_work(shared_scope, lost[:generation], true, owner[:queue])
    assert Store.pending_count(shared_scope) == 2
    assert Store.inflight_count(shared_scope) == 1

    retry_abandoned_work(survivor, shared_scope, url, req_options, requests, live_handler)
  end

  defp install_routes(site, parent, requests) do
    routes = [
      {"/retire/owner", :owner},
      {"/retire/lost", :lost},
      {"/retire/live", :live},
      {"/retire/kept", nil},
      {"/retire/live-queued", nil},
      {"/retire/lost-queued", nil}
    ]

    Enum.each(routes, fn {path, blocked} ->
      ReqTestSite.expect(site, "GET", path, &route_response(&1, parent, requests, path, blocked))
    end)
  end

  defp route_response(conn, parent, requests, path, blocked) do
    count =
      Agent.get_and_update(requests, fn counts ->
        count = Map.get(counts, path, 0)
        {count, Map.put(counts, path, count + 1)}
      end)

    if blocked && count == 0 do
      send(parent, {:blocked, blocked, self()})

      receive do
        :release -> Plug.Conn.resp(conn, 200, path)
      end
    else
      Plug.Conn.resp(conn, 200, path)
    end
  end

  defp retry_abandoned_work(survivor, shared_scope, url, req_options, requests, live_handler) do
    retry =
      start_crawl(url <> "/retire/lost", shared_scope, req_options,
        queue: survivor[:queue],
        max_pages: 4
      )

    send(live_handler, :release)
    await_idle(retry)

    for path <- ["kept", "live", "live-queued", "lost"] do
      assert Store.find_processed({url <> "/retire/" <> path, shared_scope})
    end

    assert Store.ops_count(shared_scope) == 4
    assert Store.pending_count(shared_scope) == 0
    assert Store.inflight_count(shared_scope) == 0

    queued_retry =
      start_crawl(url <> "/retire/lost-queued", shared_scope, req_options,
        queue: survivor[:queue],
        max_pages: 5
      )

    await_idle(queued_retry)
    assert Store.find_processed({url <> "/retire/lost-queued", shared_scope})
    assert Store.ops_count(shared_scope) == 5
    assert Store.pending_count(shared_scope) == 0
    assert Store.inflight_count(shared_scope) == 0

    assert Agent.get(requests, & &1) == %{
             "/retire/owner" => 1,
             "/retire/lost" => 2,
             "/retire/live" => 1,
             "/retire/kept" => 1,
             "/retire/live-queued" => 1,
             "/retire/lost-queued" => 1
           }
  end

  defp start_crawl(page, scope, req_options, extra \\ []) do
    opts = [
      scope: scope,
      workers: 1,
      timeout: 10_000,
      retries: 0,
      store: Store,
      req_options: req_options
    ]

    {:ok, opts} = start_crawl(page, Keyword.merge(opts, extra))
    opts
  end

  defp monitor_owned_processes(opts, handlers) do
    {:links, links} = Process.info(opts[:queue_owner], :links)
    supervisor = Process.whereis(Crawler.QueueSupervisor)

    [opts[:queue_owner] | links -- [supervisor]]
    |> Kernel.++(handlers)
    |> Enum.uniq()
    |> Enum.map(fn pid -> {pid, Process.monitor(pid)} end)
  end

  defp retire(opts, :stop), do: Crawler.stop(opts)
  defp retire(opts, :feeder_failure), do: Process.exit(opts[:queue], :kill)

  defp await_down(monitors) do
    Enum.each(monitors, fn {pid, ref} ->
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end)
  end
end
