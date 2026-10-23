defmodule Crawler.WorkerAuthorityTest do
  use Crawler.TestCase, async: false

  alias Crawler.Options
  alias Crawler.QueueHandler
  alias Crawler.Store
  alias Crawler.Store.Authority

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
      gate = hold_execution(scope, opts.url)

      try do
        assert :erlang.trace(gate.store, true, [:receive, {:tracer, self()}]) == 1
        send(old.pid, :start)
        assert_receive {:execution_begin_held, worker, bound}, 2_000
        state = :sys.get_state(Store)
        lease = Map.fetch!(state.execution_workers, worker)
        execution = Map.fetch!(state.executions, lease)
        assert Authority.execution_current?(lease, worker)
        assert :ets.info(Authority, :protection) == :protected
        assert state.scheduler.claims[bound.scheduler_claim].run == {scope, bound.generation}
        assert execution.opts.scheduler_claim == bound.scheduler_claim
        assert Store.inflight_count(scope) == 1
        generation = Store.generation(scope)
        monitor = Process.monitor(worker)

        case unquote(retirement) do
          :reset -> Store.drop_scope(scope)
          :stop -> Crawler.stop(bound)
        end

        assert %Store.Page{} = Crawler.crawl_now(options(context, scope, "/fresh-worker"))
        fresh = Store.find_processed({context.url <> "/fresh-worker", scope})
        assert fresh
        assert {:warn, :stale} = Task.await(old)
        assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 2_000

        await_execution_cleanup(%{
          store: gate.store,
          worker: worker,
          lease: lease,
          arena: execution.arena,
          run: {scope, generation}
        })

        assert Store.find_processed({context.url <> "/fresh-worker", scope}) == fresh
        refute Store.find({context.url <> "/old-worker", scope})
        refute_receive {:requested, "/old-worker"}
        assert Store.ops_count(scope) == 1
        assert Store.inflight_count(scope) == 0
        assert Store.pending_count(scope) == 0
        assert bound.generation === generation
        assert bound.scope === scope
        refute Authority.current?(scope, generation, nil)
        assert Authority.current?(scope, fresh.opts.generation, nil)
      after
        release_execution_gate(gate)
      end
    end
  end

  test "raw workers preserve explicit stale authority", context do
    scope = unique_scope("stale-worker")
    opts = Map.put(options(context, scope, "/stale-worker"), :generation, Store.generation(scope))
    Store.drop_scope(scope)
    on_exit(fn -> Store.dispose_scope(scope) end)
    install_route(context, "/stale-worker", self())
    before = :sys.get_state(Store)
    assert {:error, :stale} = Crawler.crawl_now(opts)
    assert :sys.get_state(Store) == before
    refute_receive {:requested, "/stale-worker"}
  end

  test "target and funding acquisition reject missing authority without creating run state",
       context do
    scope = unique_scope("missing-claim-authority")
    opts = options(context, scope, "/unbound-worker")
    before = :sys.get_state(Store)
    deadline = Crawler.Deadline.after_ms(1_000, :attempt)
    assert {:error, :stale} = Store.await_direct(make_ref(), deadline)
    assert {:error, :stale} = Store.reserve_resource(opts, :snapshot, 1)

    assert {:error, :stale} =
             Store.reserve_resource(Map.put(opts, :generation, nil), :snapshot, 1)

    assert :stale = Store.note_enqueued(scope, nil, self())
    assert :sys.get_state(Store) == before
  end

  for entry <- [:enqueue, :reference] do
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

      assert :erlang.trace(queue, true, [:receive, {:tracer, self()}]) == 1
      on_exit(fn -> if Process.alive?(queue), do: :erlang.trace(queue, false, [:receive]) end)

      result =
        case unquote(entry) do
          :enqueue -> QueueHandler.enqueue(raw)
          :reference -> Crawler.crawl_reference(raw.url, raw)
        end

      assert {:ok, old} = result

      assert_receive {:trace, ^queue, :receive,
                      {:"$gen_cast", {:enqueue, %Crawler.QueueTickets.Ticket{queue: ^queue}}}},
                     2_000

      assert {:paused, %OPQ.Queue{data: pending}, _} = OPQ.info(queue)
      assert [%Crawler.QueueTickets.Ticket{queue: ^queue} = ticket] = :queue.to_list(pending)
      assert %{outstanding: 1} = Crawler.QueueTickets.status(queue)
      old_generation = old.generation
      assert Store.current?(scope, old_generation, queue)
      Store.drop_scope(scope)

      assert {:ok, fresh} =
               QueueHandler.enqueue(%{raw | url: context.url <> "/fresh-submission"})

      assert {:paused, %OPQ.Queue{data: pending}, _} = OPQ.info(queue)
      assert [^ticket] = :queue.to_list(pending)
      assert %{outstanding: 1} = Crawler.QueueTickets.status(queue)
      refute Store.current?(scope, old_generation, queue)
      assert Crawler.Store.Authority.current?(scope, fresh.generation, queue)
      assert Process.alive?(queue)
      assert Process.alive?(owner)
      OPQ.resume(queue)
      await_idle(fresh)
      assert Store.find_processed({fresh.url, scope})
      refute Store.find({raw.url, scope})
      refute_receive {:requested, "/old-submission"}
      assert Store.ops_count(scope) == 1
      assert Store.pending_count(scope) == 0
      assert Store.inflight_count(scope) == 0
      assert Process.alive?(queue)
      assert Process.alive?(owner)
      refute fresh[:generation] === old_generation
    end
  end

  defp hold_execution(scope, url) do
    observer = self()
    store = Process.whereis(Store)
    hook = make_ref()

    callback = fn
      :armed,
      {:in,
       {:"$gen_call", {worker, _},
        {:begin_execution, %{scope: ^scope, url: ^url} = opts, _deadline}}},
      _ ->
        :erlang.suspend_process(worker)
        send(observer, {:execution_begin_held, worker, opts})
        {:held, worker}

      state, _event, _name ->
        state
    end

    assert :ok = :sys.install(store, {hook, callback, :armed})
    gate = %{store: store, hook: hook}
    on_exit(fn -> release_execution_gate(gate) end)
    gate
  end

  defp release_execution_gate(%{store: store, hook: hook}) do
    if Process.alive?(store) do
      :sys.remove(store, hook)
      :erlang.trace(store, false, [:receive])
    end
  end

  defp await_execution_cleanup(retired) do
    state = :sys.get_state(Store)

    clean? =
      not Map.has_key?(state.executions, retired.lease) and
        not Map.has_key?(state.resources.arenas, retired.arena) and
        not Map.has_key?(state.resources.runs, retired.run) and
        not Map.has_key?(state.scheduler.frontier.runs, retired.run) and
        not Enum.any?(state.resources.receipts, fn {_ref, receipt} ->
          receipt.lease == retired.lease
        end) and
        not Enum.any?(state.scheduler.claims, fn {_ref, claim} -> claim.run == retired.run end) and
        not Enum.any?(state.claims.active, fn {_ref, claim} ->
          {claim.scope, claim.generation} == retired.run
        end)

    if clean? do
      assert :ets.lookup(Crawler.Store.Execution, retired.lease) == []
      assert :ets.lookup(Crawler.Store.Resources, {:arena, retired.arena}) == []
      assert :ets.lookup(Crawler.Store.Resources, {:run, retired.run}) == []

      assert :ets.match_object(Crawler.Store.Resources, {{:grant, :_, :_}, retired.lease, :_, :_}) ==
               []

      refute Map.has_key?(state.execution_workers, retired.worker)
      refute Map.has_key?(state.resource_monitors, retired.worker)
    else
      store = retired.store

      assert_receive {:trace, ^store, :receive, event}
                     when not is_tuple(event) or elem(event, 0) != :system,
                     2_000

      await_execution_cleanup(retired)
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
