defmodule Crawler.StoreRestartTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store
  alias Crawler.Store.DB

  test "a Store crash retires managed queues and permits fresh crawls", context do
    observer = self()
    scope = unique_scope("store-restart")
    {external, external_processes} = external_queue()
    store = Process.whereis(Store)
    registry = Process.whereis(DB)
    queue_supervisor = Process.whereis(Crawler.QueueSupervisor)

    ReqTestSite.expect_once(context.site, "GET", "/store-restart/held", fn conn ->
      send(observer, {:held_request, self()})

      receive do
        :release ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.resp(200, "HELD")
      end
    end)

    ReqTestSite.stub(context.site, "GET", "/store-restart/queued", fn conn ->
      send(observer, :retired_request)

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "QUEUED")
    end)

    for path <- ["fresh", "external"] do
      ReqTestSite.expect_once(context.site, "GET", "/store-restart/#{path}", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.resp(200, "RECOVERED")
      end)
    end

    assert {:ok, old} =
             start_crawl(context.url <> "/store-restart/held",
               scope: scope,
               workers: 1,
               interval: 50,
               retries: 0,
               store: Store,
               req_options: context.req_options
             )

    assert_receive {:held_request, handler}, 2_000
    on_exit(fn -> send(handler, :release) end)
    assert {:ok, _queued} = start_crawl(context.url <> "/store-restart/queued", old)
    assert Store.pending_count(scope) == 2
    assert Store.inflight_count(scope) == 1

    owned = owned_processes(old, queue_supervisor)
    monitors = monitor_processes([store, registry, queue_supervisor, handler | owned])

    ExUnit.CaptureLog.capture_log(fn ->
      Process.exit(store, :kill)
      await_down(monitors)

      wait(5_000, fn ->
        children = Supervisor.which_children(Crawler)
        assert {Store, fresh_store, :worker, _} = List.keyfind(children, Store, 0)

        assert {Crawler.QueueSupervisor, fresh_supervisor, :supervisor, [DynamicSupervisor]} =
                 List.keyfind(children, Crawler.QueueSupervisor, 0)

        assert is_pid(fresh_store)
        assert is_pid(fresh_supervisor)
        refute fresh_store == store
        refute fresh_supervisor == queue_supervisor
        assert Process.whereis(Store) == fresh_store
        assert Process.whereis(Crawler.QueueSupervisor) == fresh_supervisor
        assert is_pid(Process.whereis(DB))
        refute Process.whereis(DB) == registry
        assert DynamicSupervisor.which_children(fresh_supervisor) == []
      end)
    end)

    assert Store.queue_record(old.queue) == nil
    assert Store.queue_scopes(old.queue) == []
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
    refute Store.find({context.url <> "/store-restart/held", scope})
    refute Crawler.running?(old)
    refute_received :retired_request
    assert Enum.all?(external_processes, &Process.alive?/1)

    assert {:ok, fresh} =
             start_crawl(context.url <> "/store-restart/fresh",
               scope: scope,
               workers: 1,
               retries: 0,
               store: Store,
               req_options: context.req_options
             )

    await_idle(fresh)

    assert %Store.Page{body: "RECOVERED"} =
             Store.find_processed({context.url <> "/store-restart/fresh", scope})

    assert Store.queue_record(fresh.queue) == %{owner: fresh.queue_owner, scope: scope}
    assert Store.queue_scopes(fresh.queue) == [scope]
    assert Store.ops_count(scope) == 1

    assert {:ok, caller_owned} =
             start_crawl(context.url <> "/store-restart/external",
               scope: unique_scope("external-after-restart"),
               queue: external,
               retries: 0,
               store: Store,
               req_options: context.req_options
             )

    on_exit(fn -> Store.drop_scope(caller_owned.scope) end)
    await_idle(caller_owned)

    assert %Store.Page{body: "RECOVERED"} =
             Store.find_processed({context.url <> "/store-restart/external", caller_owned.scope})

    assert caller_owned[:queue_owner] == nil
    assert :ok = Crawler.stop(caller_owned)
    assert Process.alive?(external)
  end

  defp owned_processes(opts, queue_supervisor) do
    {:links, links} = Process.info(opts.queue_owner, :links)
    children = links -- [queue_supervisor]
    assert opts.queue in children
    assert Process.whereis(:"opq-#{inspect(opts.queue)}") in children

    worker_supervisor =
      Enum.find(children, fn pid ->
        {:dictionary, dictionary} = Process.info(pid, :dictionary)
        dictionary[:"$initial_call"] == {:supervisor, OPQ.WorkerSupervisor, 1}
      end)

    assert is_pid(worker_supervisor)

    assert Enum.any?(children, fn pid ->
             match?(%GenStage{mod: OPQ.RateLimiter}, :sys.get_state(pid))
           end)

    [{_, worker, :worker, _}] = Supervisor.which_children(worker_supervisor)
    assert is_pid(worker)
    [opts.queue_owner, worker | children]
  end

  defp monitor_processes(pids) do
    pids
    |> Enum.uniq()
    |> Enum.map(fn pid -> {pid, Process.monitor(pid)} end)
  end

  defp await_down(monitors) do
    Enum.each(monitors, fn {pid, ref} ->
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end)
  end

  defp external_queue do
    {:links, before} = Process.info(self(), :links)
    {:ok, queue} = OPQ.init(worker: Crawler.Dispatcher.Worker, workers: 1)
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
