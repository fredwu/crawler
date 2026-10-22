defmodule Crawler.StoreIncarnationTest do
  use Crawler.TestCase, async: false

  alias Crawler.HeldParser
  alias Crawler.Options
  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Parser.CssSheets
  alias Crawler.Robots
  alias Crawler.Snapper
  alias Crawler.SnapshotHelpers
  alias Crawler.Store
  alias Crawler.Store.DB

  for phase <- [:response, :publication] do
    test "a Store restart rejects an external worker held at #{phase}", context do
      exercise_restart(unquote(phase), context)
    end
  end

  defp exercise_restart(phase, context) do
    scope = unique_scope("store-incarnation-#{phase}")
    root = tmp(scope)
    on_exit(fn -> File.rm_rf(root) end)
    {queue, external_processes} = external_queue()
    page_url = context.url <> "/store-incarnation/#{phase}"
    opts = crawl_options(context, scope, queue, root)
    install_route(context.site, phase, self())
    before_publish = publication_gate(phase, self())

    assert {:ok, old} = start_crawl(page_url, Keyword.put(opts, :before_publish, before_publish))
    assert_receive {:held, ^phase, worker}, 2_000
    on_exit(fn -> send(worker, :release) end)
    worker_monitor = Process.monitor(worker)
    assert Store.inflight_count(scope) == 1
    assert Store.pending_count(scope) == 1

    assert {:ok, old_claim} =
             Store.start_work(%{scope: scope, generation: old.generation, max_pages: 3})

    nil_publication = hold_nil_publication(phase, root, page_url)
    nil_parser = hold_nil_parser(phase, context, queue, root)
    restart_store()
    finish_nil_publication(nil_publication)
    finish_nil_parser(nil_parser)

    refute Store.current?(scope, old.generation, queue)
    refute Crawler.running?(old)
    assert Process.alive?(worker)
    assert Enum.all?(external_processes, &Process.alive?/1)
    assert {:ok, fresh} = start_crawl(page_url, opts)
    refute fresh.generation == old.generation
    assert fresh.queue == old.queue
    assert fresh[:queue_owner] == nil
    await_idle(fresh)
    page = Store.find_processed({page_url, scope})
    assert %Store.Page{body: "FRESH"} = page
    file = SnapshotHelpers.saved(root, page_url)
    snapshot = File.read!(file)
    assert snapshot == <<0xEF, 0xBB, 0xBF, "FRESH">>

    assert_stale_work(old, file)

    assert {:ok, fresh_claim} =
             Store.start_work(%{scope: scope, generation: fresh.generation, max_pages: 3})

    assert Store.inflight_count(scope) == 1
    assert :ok = Store.finish_claim(old_claim)
    assert Store.inflight_count(scope) == 1
    assert :ok = Store.finish_claim(fresh_claim)

    send(worker, :release)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 5_000
    assert Store.find_processed({page_url, scope}) == page
    assert File.read!(file) == snapshot
    assert Store.ops_count(scope) == 1
    assert Store.inflight_count(scope) == 0
    assert Store.pending_count(scope) == 0
    assert Store.current?(scope, fresh.generation, queue)
    assert Path.wildcard(Path.join([root, "**", ".crawler-*.tmp"])) == []
    assert Enum.all?(external_processes, &Process.alive?/1)
    assert :ok = Crawler.stop(fresh)
    assert Process.alive?(queue)
  end

  defp hold_nil_parser(:publication, _context, _queue, _root), do: nil

  defp hold_nil_parser(:response, context, queue, root) do
    observer = self()
    url = context.url <> "/retired-parser-root"

    ReqTestSite.expect_once(context.site, "GET", "/retired-parser-root", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.resp(200, ~s(<a href="/retired-parser-child">child</a>))
    end)

    ReqTestSite.stub(context.site, "GET", "/retired-parser-child", fn conn ->
      send(observer, :retired_parser_child_requested)
      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, "CHILD")
    end)

    opts =
      Options.assign_defaults(%{
        scope: nil,
        generation: Store.generation(nil),
        queue: queue,
        url: url,
        site: context.url,
        req_options: context.req_options,
        respect_robots: false,
        store: Store,
        save_to: root,
        retries: 0,
        parser: HeldParser,
        hold_parser_url: url,
        parser_observer: observer
      })

    assert :ok = Store.note_enqueued(nil, opts.generation, queue)
    task = Task.async(fn -> Crawler.crawl_now(opts) end)
    assert_receive {:parser_held, worker, _page}, 2_000
    on_exit(fn -> send(worker, :release_parser) end)
    {task, opts}
  end

  defp finish_nil_parser(nil), do: :ok

  defp finish_nil_parser({task, opts}) do
    before = :sys.get_state(Store)
    snapshot = File.read!(SnapshotHelpers.saved(opts.save_to, opts.url))
    send(task.pid, :release_parser)
    assert {:warn, :stale} = Task.await(task)
    assert :sys.get_state(Store) == before
    refute_receive :retired_parser_child_requested
    refute File.exists?(SnapshotHelpers.saved(opts.save_to, opts.site <> "/retired-parser-child"))
    assert File.read!(SnapshotHelpers.saved(opts.save_to, opts.url)) == snapshot
  end

  defp hold_nil_publication(:response, _root, _url), do: nil

  defp hold_nil_publication(:publication, root, url) do
    observer = self()

    opts = %{
      url: url <> "/nil-scope",
      save_to: root,
      content_type: "text/html",
      generation: Store.generation(nil),
      before_publish: fn -> hold(observer, :nil_publication) end
    }

    task = Task.async(fn -> Snapper.snap("OLD-NIL", opts) end)
    assert_receive {:held, :nil_publication, worker}, 2_000
    on_exit(fn -> send(worker, :release) end)
    {task, opts}
  end

  defp finish_nil_publication(nil), do: :ok

  defp finish_nil_publication({task, old}) do
    fresh = old |> Map.put(:generation, Store.generation(nil)) |> Map.delete(:before_publish)
    assert {:ok, _} = Snapper.snap("FRESH-NIL", fresh)
    file = SnapshotHelpers.saved(fresh.save_to, fresh.url)
    snapshot = File.read!(file)
    assert snapshot == <<0xEF, 0xBB, 0xBF, "FRESH-NIL">>
    send(task.pid, :release)
    assert {:error, :stale} = Task.await(task)
    assert File.read!(file) == snapshot
    Store.dispose_scope(nil)
  end

  defp crawl_options(context, scope, queue, root) do
    [
      scope: scope,
      queue: queue,
      save_to: root,
      retries: 0,
      store: Store,
      req_options: context.req_options
    ]
  end

  defp install_route(site, phase, observer) do
    {:ok, requests} = Agent.start_link(fn -> 0 end)

    ReqTestSite.expect(site, "GET", "/store-incarnation/#{phase}", fn conn ->
      attempt = Agent.get_and_update(requests, &{&1, &1 + 1})
      if phase == :response and attempt == 0, do: hold(observer, phase)
      body = if attempt == 0, do: "OLD", else: "FRESH"
      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, body)
    end)
  end

  defp publication_gate(:publication, observer), do: fn -> hold(observer, :publication) end
  defp publication_gate(:response, _observer), do: fn -> :ok end

  defp hold(observer, phase) do
    send(observer, {:held, phase, self()})

    receive do
      :release -> :ok
    end
  end

  defp restart_store do
    store = Process.whereis(Store)
    registry = Process.whereis(DB)
    queues = Process.whereis(Crawler.QueueSupervisor)
    monitor = Process.monitor(store)
    gate = registry_shutdown_gate(registry)

    ExUnit.CaptureLog.capture_log(fn ->
      Process.exit(store, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^store, :killed}, 5_000
      assert_receive {:registry_shutdown_held, ^gate}, 5_000

      wait(5_000, fn ->
        fresh_store = Process.whereis(Store)
        assert is_pid(fresh_store)
        refute fresh_store == store
        assert Process.alive?(Process.whereis(Crawler))
        assert Process.whereis(DB) == registry
      end)

      send(gate, :release)

      wait(5_000, fn ->
        children = Supervisor.which_children(Crawler)
        assert {Store, fresh_store, :worker, _} = List.keyfind(children, Store, 0)

        assert {Crawler.QueueSupervisor, fresh_queues, :supervisor, _} =
                 List.keyfind(children, Crawler.QueueSupervisor, 0)

        assert is_pid(fresh_store)
        assert is_pid(fresh_queues)
        refute fresh_store == store
        refute fresh_queues == queues
        assert Process.whereis(Store) == fresh_store
        assert Process.whereis(Crawler.QueueSupervisor) == fresh_queues
        assert is_pid(Process.whereis(DB))
        refute Process.whereis(DB) == registry
        assert Store.ops_count() == 0
      end)
    end)
  end

  defp registry_shutdown_gate(registry) do
    observer = self()

    spec =
      Supervisor.child_spec(
        {Task,
         fn ->
           Process.flag(:trap_exit, true)
           send(observer, {:registry_gate_ready, self()})

           receive do
             {:EXIT, ^registry, :shutdown} ->
               send(observer, {:registry_shutdown_held, self()})

               receive do
                 :release -> :ok
               end
           end
         end},
        id: :shutdown_gate,
        restart: :temporary,
        shutdown: :infinity
      )

    assert {:ok, gate} = Supervisor.start_child(registry, spec)
    on_exit(fn -> Process.exit(gate, :kill) end)
    assert_receive {:registry_gate_ready, ^gate}, 5_000
    gate
  end

  defp assert_stale_work(old, file) do
    scope = old.scope
    generation = old.generation
    queue = old.queue
    key = {old.url, scope}
    assert {:ok, stale_crawl} = start_crawl(old.url <> "/stale-child", old)
    assert stale_crawl.generation == generation
    refute Store.work_pending?(scope, generation, queue)
    assert :stale = Store.start_work(old)
    assert :stale = Store.note_enqueued(scope, generation, queue)
    assert :stale = Store.try_claim(scope, 3, generation, queue)
    assert :stale = Store.finish_work(scope, generation, true, queue)
    assert {:error, :stale} = Store.add(key, generation, queue)
    assert {:error, :stale} = Store.add_page_data(key, "STALE", old)
    assert {:error, :stale} = Store.register_alias(key, generation, queue)
    assert {:error, :stale} = Store.retain_alias(key, "STALE", old)
    assert :stale = Store.processed(key, generation, queue)
    assert :stale = Store.complete_page(key, generation, queue)
    assert :stale = Store.delete(key, generation, queue)
    assert :stale = Store.rollback_alias(key, generation, queue, true)
    css = ~s|:root { --retired: url("retired.png"); }|
    css_before = Map.get(:sys.get_state(CssSheets).scopes, {scope, old.generation})
    assert {:ok, []} = CssSheets.remember(old, css, Scanner.analyze(css))
    assert [] = CssSheets.take_urls(old, css, [])
    refute CssSheets.replay?(old, css)
    assert [] = CssSheets.settle(old)
    assert Map.get(:sys.get_state(CssSheets).scopes, {scope, old.generation}) == css_before
    origin = Crawler.Site.origin(old.url)
    assert {:error, :stale} = Store.claim_robots(scope, origin, generation, queue)

    assert {:error, :stale} =
             Store.finish_robots(scope, origin, Robots.allow_all(), generation, queue)

    assert {:error, :stale} =
             Store.forget_robots(scope, origin, Robots.allow_all(), generation, queue)

    Store.save_cookies(scope, old.url, ["retired=1"], generation, %{queue: queue})
    assert Store.cookie_header(scope, old.url, generation, %{queue: queue}) == nil
    assert :ok = Store.ops_inc(scope, generation, queue)
    assert :ok = Store.inflight_dec(scope, generation, queue)
    temp = file <> ".stale"
    on_exit(fn -> File.rm(temp) end)
    File.write!(temp, "STALE")
    assert {:error, :stale} = Store.publish_file(scope, generation, file, temp, queue)
    refute File.exists?(temp)
  end

  defp external_queue do
    {:links, before} = Process.info(self(), :links)
    {:ok, queue} = OPQ.init(worker: Crawler.Dispatcher.Worker, workers: 2, interval: 10)
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
