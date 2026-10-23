defmodule Crawler.StoreIncarnationTest do
  use Crawler.TestCase, async: false

  alias Crawler.HeldParser
  alias Crawler.ManagedSnapshotHelpers, as: Managed
  alias Crawler.Options
  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Parser.CssSheets
  alias Crawler.Robots
  alias Crawler.Store
  alias Crawler.Store.DB

  setup do
    generation = Store.drop_scope(nil)
    on_exit(fn -> Store.dispose_scope(nil) end)
    {:ok, nil_generation: generation}
  end

  for phase <- [:response, :publication] do
    test "a Store restart rejects work held at #{phase} and preserves an external queue",
         context do
      exercise_restart(unquote(phase), context)
    end
  end

  defp exercise_restart(phase, context) do
    scope = unique_scope("store-incarnation-#{phase}")
    parent = tmp(scope)
    root = Path.join(parent, "snapshot")
    on_exit(fn -> File.rm_rf(parent) end)
    {queue, external_processes} = external_queue()
    page_url = context.url <> "/store-incarnation/#{phase}"
    opts = crawl_options(context, scope, queue, root)
    install_route(context.site, phase, self())
    {old, old_task} = start_held(phase, page_url, opts)
    assert_receive {:held, ^phase, worker}, 2_000
    on_exit(fn -> send(worker, :release) end)
    worker_monitor = Process.monitor(worker)
    assert Store.inflight_count(scope) == 1
    assert Store.pending_count(scope) == 1

    old_state = :sys.get_state(Store)

    old_target =
      if phase == :response,
        do: old.target_handle,
        else: old_state.exports[{scope, old.generation}].helper.finalizer.id

    assert {:running, old_claim} = old_state.scheduler.frontier.jobs[old_target].status

    nil_publication = hold_nil_publication(phase, context, root, page_url)
    nil_parser = hold_nil_parser(phase, context, queue, root)
    restart_store()
    finish_nil_publication(nil_publication)
    finish_nil_parser(nil_parser)

    refute Store.current?(scope, old.generation, queue)
    refute Crawler.running?(old)
    assert Process.alive?(worker)
    assert Enum.all?(external_processes, &Process.alive?/1)

    assert {:ok, fresh} =
             start_crawl(
               page_url,
               Keyword.merge(opts,
                 parser: HeldParser,
                 hold_parser_url: page_url,
                 parser_observer: self()
               )
             )

    assert_receive {:parser_held, fresh_executor, fresh_page}, 2_000
    on_exit(fn -> send(fresh_executor, :release_parser) end)
    refute fresh.generation == old.generation
    assert fresh.queue == queue
    assert fresh[:queue_owner] == nil
    fresh_claim = fresh_page.opts.scheduler_claim
    assert Store.inflight_count(scope) == 1
    assert {:error, :stale} = Store.complete_job(old_claim, Crawler.Job.Outcome.new(:failed))

    assert {:running, ^fresh_claim} =
             :sys.get_state(Store).scheduler.frontier.jobs[fresh.target_handle].status

    assert Store.inflight_count(scope) == 1
    send(fresh_executor, :release_parser)
    export = Managed.ready_export(fresh)
    await_idle(fresh)

    page =
      wait(fn -> assert %Store.Page{body: "FRESH"} = Store.find_processed({page_url, scope}) end)

    resource = Managed.resource_for_url(export, page_url)
    file = Managed.artifact_path(export, resource)
    snapshot = File.read!(file)
    assert snapshot == fresh_bytes(phase)

    assert_stale_work(old, old_target)

    send(worker, :release)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 5_000
    finish_held(old_task)
    assert Store.find_processed({page_url, scope}) == page
    assert File.read!(file) == snapshot
    assert Store.ops_count(scope) == 1
    assert Store.inflight_count(scope) == 0
    assert Store.pending_count(scope) == 0
    assert Store.current?(scope, fresh.generation, queue)
    assert Path.wildcard(Path.join([root, "**", ".crawler-*.tmp"])) == []
    assert Enum.all?(external_processes, &Process.alive?/1)
    assert :ok = Crawler.stop(fresh)

    wait(fn ->
      state = :sys.get_state(Store)
      run = {scope, fresh.generation}
      refute Map.has_key?(state.exports, run)
      refute Map.has_key?(state.resources.runs, run)
      refute Enum.any?(state.export_actors, fn {_actor, owner} -> owner == run end)
    end)

    assert Process.alive?(queue)
  end

  defp start_held(:response, url, opts) do
    assert {:ok, old} = start_crawl(url, opts)
    {old, nil}
  end

  defp start_held(:publication, url, opts) do
    assert {:ok, old} =
             opts |> Map.new() |> Map.merge(%{url: url, queue: nil}) |> Managed.stage_copy()

    observer = self()

    task =
      Task.async(fn -> Managed.finalize_copy(old, fn _ -> hold(observer, :publication) end) end)

    {old, task}
  end

  defp finish_held(nil), do: :ok
  defp finish_held(task), do: assert({:error, :stale} = Task.await(task))
  defp fresh_bytes(:response), do: <<0xEF, 0xBB, 0xBF, "FRESH">>
  defp fresh_bytes(:publication), do: "FRESH"

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
        generation: context.nil_generation,
        queue: queue,
        url: url,
        site: context.url,
        req_options: context.req_options,
        respect_robots: false,
        store: Store,
        save_to: Path.join(Path.dirname(root), "nil-parser"),
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_manifest_bytes: 1_048_576,
        retries: 0,
        parser: HeldParser,
        hold_parser_url: url,
        parser_observer: observer
      })

    assert :ok = Store.note_enqueued(nil, opts.generation, queue)
    task = Task.async(fn -> Crawler.crawl_now(opts) end)
    assert_receive {:parser_held, worker, _page}, 2_000
    on_exit(fn -> send(worker, :release_parser) end)
    {task, worker, opts}
  end

  defp finish_nil_parser(nil), do: :ok

  defp finish_nil_parser({task, worker, opts}) do
    before = :sys.get_state(Store)
    refute File.exists?(opts.save_to <> "/manifest.json")
    send(worker, :release_parser)
    assert {:error, :stale} = Task.await(task)
    assert :sys.get_state(Store) == before
    refute_receive :retired_parser_child_requested
    refute File.exists?(opts.save_to <> "/manifest.json")
  end

  defp hold_nil_publication(:response, _context, _root, _url), do: nil

  defp hold_nil_publication(:publication, context, root, url) do
    observer = self()
    nil_url = url <> "/nil-scope"
    path = URI.parse(nil_url).path
    {:ok, requests} = Agent.start_link(fn -> 0 end)

    ReqTestSite.expect(context.site, "GET", path, fn conn ->
      attempt = Agent.get_and_update(requests, &{&1, &1 + 1})
      body = if attempt == 0, do: "OLD-NIL", else: "FRESH-NIL"

      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream")
      |> Plug.Conn.resp(200, body)
    end)

    opts = %{
      url: nil_url,
      scope: nil,
      save_to: Path.join(Path.dirname(root), "nil-publication"),
      req_options: context.req_options,
      respect_robots: false,
      max_body: 1_048_576,
      max_analysis_bytes: 16_000_000,
      max_manifest_bytes: 1_048_576,
      retries: 0
    }

    assert {:ok, old} = Managed.stage_copy(Map.put(opts, :generation, context.nil_generation))

    task =
      Task.async(fn ->
        Managed.finalize_copy(old, fn frame ->
          send(observer, {:nil_publication_filesystem, frame.filesystem.filesystem})
          hold(observer, :nil_publication)
        end)
      end)

    assert_receive {:nil_publication_filesystem, filesystem}, 2_000
    monitor = Process.monitor(filesystem)
    assert_receive {:held, :nil_publication, worker}, 2_000
    on_exit(fn -> send(worker, :release) end)
    {task, worker, opts, filesystem, monitor}
  end

  defp finish_nil_publication(nil), do: :ok

  defp finish_nil_publication({task, worker, opts, filesystem, monitor}) do
    assert_receive {:DOWN, ^monitor, :process, ^filesystem, :normal}, 5_000
    assert {:ok, fresh} = Managed.stage_copy(opts)
    assert {:ok, :committed} = Managed.finalize_copy(fresh)
    export = Managed.ready_export(fresh)
    resource = Managed.resource_for_url(export, fresh.url)
    file = Managed.artifact_path(export, resource)
    snapshot = File.read!(file)
    assert snapshot == "FRESH-NIL"
    send(worker, :release)
    assert {:error, :stale} = Task.await(task)
    assert File.read!(file) == snapshot
    Store.dispose_scope(nil)
  end

  defp crawl_options(context, scope, queue, root) do
    [
      scope: scope,
      queue: queue,
      save_to: root,
      max_body: 1_048_576,
      max_analysis_bytes: 16_000_000,
      max_manifest_bytes: 1_048_576,
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
      type = if phase == :response, do: "text/html", else: "application/octet-stream"
      conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.resp(200, body)
    end)
  end

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

  defp assert_stale_work(old, target) do
    scope = old.scope
    generation = old.generation
    queue = old.queue
    key = {old.url, scope}
    assert {:error, :stale} = start_crawl(old.url <> "/stale-child", old)
    refute Store.current?(scope, generation, queue)
    refute Store.work_pending?(scope, generation, queue)

    assert {:error, :stale} =
             Store.await_direct(target, Crawler.Deadline.after_ms(1_000, :attempt))

    assert :stale = Store.note_enqueued(scope, generation, queue)
    assert :stale = Store.try_claim(scope, 3, generation, queue)
    assert :stale = Store.finish_work(scope, generation, true, queue)
    assert {:error, :stale} = Store.add(key, generation, queue)
    assert {:error, :stale} = Store.add_page_data(key, "STALE", old)
    assert {:error, :stale} = Store.register_alias(key, generation, queue)
    assert {:error, :stale} = Store.retain_alias(key, "STALE", old)
    assert :stale = Store.processed(key, generation, queue)
    assert {:error, :stale} = Store.complete_page(key, generation, queue)
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
    assert {:error, :stale} = Store.close_export(old)
    assert {:error, :stale} = Store.reserve_resource(old, :snapshot, 1)
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
