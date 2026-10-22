defmodule Crawler.WorkerAuthorityTest do
  use Crawler.TestCase, async: false

  alias Crawler.Options
  alias Crawler.QueueHandler
  alias Crawler.Store
  alias Crawler.StoreGate

  for retirement <- [:reset, :stop], identity <- [:named, :absent] do
    test "a raw worker binds its #{identity} scope before a claim survives #{retirement}",
         context do
      scope = if unquote(identity) == :named, do: unique_scope("raw-worker"), else: nil
      on_exit(fn -> Store.dispose_scope(scope) end)
      opts = options(context, scope, "/old-worker")
      opts = if unquote(identity) == :absent, do: Map.delete(opts, :scope), else: opts
      observer = self()
      install_route(context, "/old-worker", observer)
      install_route(context, "/fresh-worker", observer)

      old = Task.async(fn -> receive do: (:start -> Crawler.crawl_now(opts)) end)
      gate = StoreGate.hold(old.pid, &match?({:start_work, _}, &1))
      send(old.pid, :start)
      assert_receive {:store_call_held, worker, {:start_work, bound}}, 2_000
      assert worker == old.pid
      assert Store.inflight_count(scope) == 1
      generation = Store.generation(scope)

      case unquote(retirement) do
        :reset -> Store.drop_scope(scope)
        :stop -> Crawler.stop(bound)
      end

      assert %Store.Page{} = Crawler.crawl_now(options(context, scope, "/fresh-worker"))
      fresh = Store.find_processed({context.url <> "/fresh-worker", scope})
      assert fresh
      StoreGate.resume(gate)
      assert {:warn, :stale} = Task.await(old)
      assert Store.find_processed({context.url <> "/fresh-worker", scope}) == fresh
      refute Store.find({context.url <> "/old-worker", scope})
      refute_receive {:requested, "/old-worker"}
      assert Store.ops_count(scope) == 1
      assert Store.inflight_count(scope) == 0
      assert bound[:generation] === generation
      assert Map.has_key?(bound, :scope) == Map.has_key?(opts, :scope)
    end
  end

  test "raw workers preserve explicit stale authority", context do
    scope = unique_scope("stale-worker")
    opts = Map.put(options(context, scope, "/stale-worker"), :generation, Store.generation(scope))
    Store.drop_scope(scope)
    on_exit(fn -> Store.dispose_scope(scope) end)
    install_route(context, "/stale-worker", self())
    before = :sys.get_state(Store)
    assert :stale = Crawler.crawl_now(opts)
    assert :sys.get_state(Store) == before
    refute_receive {:requested, "/stale-worker"}
  end

  test "submission and claim acquisition reject missing authority without creating run state",
       context do
    scope = unique_scope("missing-claim-authority")
    opts = options(context, scope, "/unbound-worker")
    before = :sys.get_state(Store)
    assert :stale = Store.start_work(opts)
    assert :stale = Store.start_work(Map.put(opts, :generation, nil))
    assert :stale = Store.note_enqueued(scope, nil, self())
    assert :sys.get_state(Store) == before
  end

  for entry <- [:enqueue, :requeue] do
    test "raw #{entry} binds authority before a paused queue crosses reset", context do
      scope = unique_scope("paused-raw-submission")
      owner_scope = unique_scope("submission-queue-owner")

      on_exit(fn ->
        Store.dispose_scope(scope)
        Store.dispose_scope(owner_scope)
      end)

      owner_opts = options(context, owner_scope, "/queue-owner")
      owner = start_supervised!({Crawler.Queue, owner_opts})
      queue = Crawler.Queue.feeder(owner)
      OPQ.pause(queue)
      assert {:paused, _, _} = OPQ.info(queue)
      observer = self()
      install_route(context, "/old-submission", observer)
      install_route(context, "/fresh-submission", observer)
      raw = Map.put(options(context, scope, "/old-submission"), :queue, queue)

      apply(QueueHandler, unquote(entry), [raw])
      assert {:paused, %OPQ.Queue{data: pending}, _} = OPQ.info(queue)
      assert :queue.len(pending) == 1
      old_generation = Store.generation(scope)
      Store.drop_scope(scope)

      assert {:ok, fresh} =
               QueueHandler.enqueue(%{raw | url: context.url <> "/fresh-submission"})

      assert {:paused, %OPQ.Queue{data: pending}, _} = OPQ.info(queue)
      assert :queue.len(pending) == 2
      OPQ.resume(queue)
      await_idle(fresh)
      assert Store.find_processed({fresh.url, scope})
      refute Store.find({raw.url, scope})
      refute_receive {:requested, "/old-submission"}
      assert Store.ops_count(scope) == 1
      refute fresh[:generation] === old_generation
    end
  end

  defp install_route(context, path, observer) do
    ReqTestSite.stub(context.site, "GET", path, fn conn ->
      send(observer, {:requested, path})
      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, path)
    end)
  end

  defp options(context, scope, path) do
    Options.assign_defaults(%{
      scope: scope,
      url: context.url <> path,
      site: context.url,
      req_options: context.req_options,
      respect_robots: false,
      store: Store,
      workers: 1,
      retries: 0
    })
  end
end
