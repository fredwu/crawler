defmodule Crawler.RunDispatchAuthorityTest do
  use Crawler.TestCase, async: false

  alias Crawler.HeldParser
  alias Crawler.ManagedSnapshotHelpers
  alias Crawler.Options
  alias Crawler.QueueHandler
  alias Crawler.Store
  alias Crawler.Store.Authority

  setup do
    Store.dispose_scope(nil)
    original = Application.fetch_env(:crawler, :scope)
    Application.put_env(:crawler, :scope, unique_scope("ambient-dispatch-scope"))

    on_exit(fn ->
      case original do
        {:ok, scope} -> Application.put_env(:crawler, :scope, scope)
        :error -> Application.delete_env(:crawler, :scope)
      end

      Store.dispose_scope(nil)
    end)
  end

  for retirement <- [:reset, :stop], identity <- [nil, :absent] do
    test "a parser held with #{inspect(identity)} scope cannot create a child run after #{retirement}",
         context do
      root = Path.join(tmp(unique_scope("retired-parser")), "archive")
      on_exit(fn -> File.rm_rf(Path.dirname(root)) end)
      observer = self()
      install_route(context, "/held-parent", ~s(<a href="/retired-child">child</a>), observer)
      install_route(context, "/retired-child", "CHILD", observer)
      opts = options(context, root, "/held-parent")
      opts = if unquote(identity) == :absent, do: Map.delete(opts, :scope), else: opts
      task = Task.async(fn -> Crawler.crawl_now(opts) end)
      assert_receive {:parser_held, worker, page}, 2_000
      on_exit(fn -> send(worker, :release_parser) end)
      assert page.opts[:scope] == nil
      assert {:ok, %{state: :admitting, ready?: false}} = Crawler.export_status(page.opts)
      refute File.exists?(root)
      retired = observe_execution(worker, page.opts)

      case unquote(retirement) do
        :reset -> Store.drop_scope(nil)
        :stop -> Crawler.stop(page.opts)
      end

      before = run_state(page.opts.scope)
      assert_retired(task, retired)
      assert run_state(page.opts.scope) == before
      refute_receive {:requested, "/retired-child"}
      refute Store.find({context.url <> "/retired-child", nil})
      refute File.exists?(root)
    end
  end

  for identity <- [nil, :absent] do
    test "live #{inspect(identity)}-scope descendants share their run identity and page budget",
         context do
      root = Path.join(tmp(unique_scope("live-nil-dispatch")), "archive")
      on_exit(fn -> File.rm_rf(Path.dirname(root)) end)
      observer = self()
      install_route(context, "/live-parent", ~s(<a href="/live-child">child</a>), observer)
      install_route(context, "/live-child", ~s(<a href="/over-budget">extra</a>), observer)
      install_route(context, "/over-budget", "EXTRA", observer)
      opts = %{options(context, root, "/live-parent") | max_pages: 2}
      opts = if unquote(identity) == :absent, do: Map.delete(opts, :scope), else: opts
      state_before = :sys.get_state(Store)
      assert {:ok, bound} = QueueHandler.enqueue(opts)
      assert bound[:scope] == nil
      assert_receive {:parser_held, worker, parent}, 2_000
      on_exit(fn -> send(worker, :release_parser) end)
      assert parent.opts[:scope] == nil
      send(worker, :release_parser)
      await_idle(bound)
      child = Store.find_processed({context.url <> "/live-child", nil})
      assert child
      assert child.opts.scope == nil
      assert child.opts.generation === bound.generation
      assert Store.ops_count(nil) == 2
      state = :sys.get_state(Store)
      assert Map.keys(state.scopes) -- Map.keys(state_before.scopes) == [nil]

      assert Map.keys(state.exports) -- Map.keys(state_before.exports) ==
               [{nil, bound.generation}]

      export = ManagedSnapshotHelpers.ready_export(bound)
      source = ManagedSnapshotHelpers.resource_for_url(export, parent.url)
      target = ManagedSnapshotHelpers.reference_target(export, source, child.url)
      assert target["url"] == child.url
      ManagedSnapshotHelpers.assert_link_opens(export, source, target)

      assert {:error, :closed_export} =
               QueueHandler.enqueue(%{bound | url: context.url <> "/over-budget"})

      assert Process.alive?(bound.queue)
      assert Process.alive?(bound.queue_owner)
      assert Store.current?(nil, bound.generation, bound.queue)
      assert Store.queue_record(bound.queue).owner == bound.queue_owner
      assert Store.ops_count(nil) == 2
      assert Store.pending_count(nil) == 0
      refute Store.find({context.url <> "/over-budget", nil})
      refute_receive {:requested, "/over-budget"}
      assert :ok = Crawler.stop(bound)
      refute Store.current?(nil, bound.generation)
      refute Store.find({child.url, nil})
      refute Process.alive?(bound.queue)
    end
  end

  for retirement <- [:reset, :stop] do
    test "a held force manifest cannot repeat a root reset after #{retirement}", context do
      scope = unique_scope("force-manifest")
      root = Path.join(tmp(scope), "archive")

      on_exit(fn ->
        File.rm_rf(Path.dirname(root))
        Store.dispose_scope(scope)
      end)

      install_route(context, "/force-manifest", ~s({"start_url":"/force-child"}), self())
      install_route(context, "/force-child", "CHILD", self())

      opts =
        Map.merge(options(context, root, "/force-manifest"), %{
          scope: scope,
          force: true,
          fetch_kind: :manifest
        })

      task = Task.async(fn -> Crawler.crawl_now(opts) end)
      assert_receive {:parser_held, worker, page}, 2_000
      on_exit(fn -> send(worker, :release_parser) end)
      assert page.opts.depth == 1
      retired = observe_execution(worker, page.opts)

      case unquote(retirement) do
        :reset -> Store.drop_scope(scope)
        :stop -> Crawler.stop(page.opts)
      end

      before = run_state(scope)
      assert_retired(task, retired)
      assert run_state(scope) == before
      refute_receive {:requested, "/force-child"}
      refute File.exists?(root)
    end
  end

  test "a live force manifest keeps the startup generation for its depth-zero page", context do
    scope = unique_scope("live-force-manifest")
    root = Path.join(tmp(scope), "archive")

    on_exit(fn ->
      File.rm_rf(Path.dirname(root))
      Store.dispose_scope(scope)
    end)

    install_route(context, "/live-force-manifest", ~s({"start_url":"/live-force-child"}), self())
    install_route(context, "/live-force-child", "CHILD", self())

    opts =
      Map.merge(options(context, root, "/live-force-manifest"), %{
        scope: scope,
        force: true,
        fetch_kind: :manifest
      })

    assert {:ok, bound} = Crawler.crawl(opts.url, opts)
    on_exit(fn -> Crawler.stop(bound) end)
    assert_receive {:parser_held, worker, _page}, 2_000
    on_exit(fn -> send(worker, :release_parser) end)
    send(worker, :release_parser)
    await_idle(bound)
    child = Store.find_processed({context.url <> "/live-force-child", scope})
    assert child
    assert child.opts.generation === bound.generation
    refute child.opts.force
    export = ManagedSnapshotHelpers.ready_export(bound)
    source = ManagedSnapshotHelpers.resource_for_url(export, opts.url)
    target = ManagedSnapshotHelpers.reference_target(export, source, child.url)
    assert ManagedSnapshotHelpers.read_resource(export, target) == <<0xEF, 0xBB, 0xBF>> <> "CHILD"
    assert Store.current?(scope, bound.generation, bound.queue)
  end

  test "parser-returned page metadata cannot grant completion authority", context do
    root = Path.join(tmp(unique_scope("parser-completion-authority")), "archive")
    on_exit(fn -> File.rm_rf(Path.dirname(root)) end)
    install_route(context, "/completion-parent", "OLD", self())
    opts = options(context, root, "/completion-parent")
    task = Task.async(fn -> Crawler.crawl_now(opts) end)
    assert_receive {:parser_held, worker, old}, 2_000
    on_exit(fn -> send(worker, :release_parser) end)
    retired = observe_execution(worker, old.opts)
    generation = Store.drop_scope(nil)
    fresh_opts = %{url: old.url, scope: nil, generation: generation, queue: nil}
    assert {:ok, _} = Store.add({old.url, nil}, generation)
    assert {_, _} = Store.add_page_data({old.url, nil}, "FRESH", fresh_opts)
    fresh = Store.find({old.url, nil})
    before = run_state(nil)
    assert_retired(task, retired)
    send(worker, {:release_parser, fresh})
    assert Store.find({old.url, nil}) == fresh
    assert run_state(nil) == before
  end

  test "only explicit startup can force or rescope a supplied run", context do
    queue = paused_queue()
    source_scope = unique_scope("explicit-source")
    target_scope = unique_scope("explicit-target")

    on_exit(fn ->
      Store.dispose_scope(source_scope)
      Store.dispose_scope(target_scope)
    end)

    generation = Store.generation(source_scope)

    opts =
      Map.merge(options(context, nil, "/explicit-startup"), %{
        scope: target_scope,
        generation: generation,
        force: true,
        queue: queue
      })

    before = :sys.get_state(Store)
    assert {:error, :stale} = Crawler.crawl_reference(opts.url, opts)
    assert {:error, :stale} = Crawler.crawl_reference(opts.url, Map.to_list(opts))
    assert :sys.get_state(Store) == before
    assert {:paused, %OPQ.Queue{data: pending}, _} = OPQ.info(queue)
    assert :queue.is_empty(pending)
    assert {:ok, startup} = Crawler.crawl(opts.url, opts)
    assert startup.scope == target_scope
    refute startup.generation === generation
    assert Store.generation(source_scope) === generation
    assert Store.current?(target_scope, startup.generation, queue)
    assert {:ok, forced} = Crawler.crawl(startup.url, startup)
    refute forced.generation === startup.generation
    assert forced.scope == target_scope
  end

  test "standalone reference dispatch keeps ordinary startup defaults", context do
    queue = paused_queue()

    opts =
      options(context, nil, "/standalone-reference")
      |> Map.delete(:scope)
      |> Map.put(:queue, queue)

    scope = Application.fetch_env!(:crawler, :scope)
    on_exit(fn -> Store.dispose_scope(scope) end)
    assert {:ok, started} = Crawler.Dispatcher.dispatch({"href", opts.url}, opts)
    assert started.scope == scope
    assert Store.current?(scope, started.generation, queue)
  end

  test "a direct absent-scope sitemap shares the nil run and its page budget", context do
    queue = paused_queue()
    generation = Store.generation(nil)
    assert :ok = Store.note_enqueued(nil, generation, queue)
    assert :ok = Store.finish_work(nil, generation, false, queue)
    install_route(context, "/sitemap-child", "CHILD", self())

    opts =
      options(context, nil, "/direct-sitemap")
      |> Map.merge(%{
        generation: generation,
        queue: queue,
        max_pages: 1,
        content_type: "application/xml"
      })
      |> Map.delete(:scope)

    body = ~s(<urlset><url><loc>#{context.url}/sitemap-child</loc></url></urlset>)
    assert Crawler.Sitemap.ingest(opts, body)
    OPQ.resume(queue)
    await_idle(opts)
    child = Store.find_processed({context.url <> "/sitemap-child", nil})
    assert child
    assert child.opts.generation === generation
    assert Store.ops_count(nil) == 1
    before = run_state(nil)
    full = ~s(<urlset><url><loc>#{context.url}/sitemap-over-budget</loc></url></urlset>)
    assert Crawler.Sitemap.ingest(opts, full)
    after_state = run_state(nil)
    assert Map.drop(after_state, [:scope]) == Map.drop(before, [:scope])

    assert after_state.scope ==
             {:ok,
              %{
                elem(before.scope, 1)
                | control_documents: elem(before.scope, 1).control_documents + 1,
                  control_bytes: elem(before.scope, 1).control_bytes + byte_size(full),
                  reported_limit: {:limit, :max_pages}
              }}

    assert Store.ops_count(nil) == 1
    assert Store.pending_count(nil) == 0
    assert Store.inflight_count(nil) == 0
    refute Store.find({context.url <> "/sitemap-over-budget", nil})
  end

  test "standalone document CSS context does not enter queued or stored child options", context do
    queue = paused_queue()
    install_route(context, "/local-context-picture", "PICTURE", self())

    opts =
      options(context, nil, "/local-context-parent")
      |> Map.merge(%{content_type: "text/html", assets: ["css", "images"], queue: queue})
      |> Map.delete(:scope)

    html = """
    <style>:root { --picture: url("/local-context-picture"); }</style>
    <style>body { background: var(--picture); }</style>
    """

    observe_receives(queue)
    results = Crawler.Parser.parse_links(html, opts, &Crawler.Dispatcher.dispatch/2)
    assert [{:ok, bound}] = results |> List.flatten() |> Enum.reject(&is_nil/1)
    on_exit(fn -> Store.dispose_scope(bound.scope) end)

    assert_receive {:trace, ^queue, :receive,
                    {:"$gen_cast", {:enqueue, %Crawler.QueueTickets.Ticket{queue: ^queue}}}},
                   2_000

    assert {:paused, %OPQ.Queue{data: pending}, _} = OPQ.info(queue)
    assert [%Crawler.QueueTickets.Ticket{queue: ^queue}] = :queue.to_list(pending)
    assert %{outstanding: 1} = Crawler.QueueTickets.status(queue)

    assert %{job: %{opts: queued}} =
             :sys.get_state(Store).scheduler.frontier.jobs[bound.target_handle]

    refute Map.has_key?(queued, :document_styles)
    refute Map.has_key?(queued, :document_style_id)
    OPQ.resume(queue)
    await_idle(bound)
    stored = Store.find_processed({context.url <> "/local-context-picture", bound.scope})
    assert stored
    refute Map.has_key?(stored.opts, :document_styles)
    refute Map.has_key?(stored.opts, :document_style_id)
  end

  test "live parser replacement metadata cannot complete another scope's page", context do
    foreign_scope = unique_scope("foreign-parser-result")
    on_exit(fn -> Store.dispose_scope(foreign_scope) end)
    install_route(context, "/live-completion-parent", "ORIGINAL", self())
    opts = options(context, nil, "/live-completion-parent")
    task = Task.async(fn -> Crawler.crawl_now(opts) end)
    assert_receive {:parser_held, worker, original}, 2_000
    on_exit(fn -> send(worker, :release_parser) end)

    generation = Store.generation(foreign_scope)
    key = {original.url, foreign_scope}
    foreign_opts = %{url: original.url, scope: foreign_scope, generation: generation, queue: nil}
    assert {:ok, _} = Store.add(key, generation)
    assert {_, _} = Store.add_page_data(key, "FOREIGN", foreign_opts)
    foreign = Store.find(key)
    refute foreign.processed
    before = run_state(foreign_scope)
    send(worker, {:release_parser, foreign})
    returned = Task.await(task)
    assert %{foreign | credit: returned.credit} == returned
    assert %{return_token: token, retained: [_ | _]} = returned.credit
    assert is_reference(token)
    assert Store.find_processed({original.url, nil})
    assert Store.ops_count(nil) == 1
    assert Store.find(key) == foreign
    assert run_state(foreign_scope) == before
    assert Store.current?(nil, original.opts.generation)
  end

  test "a copied execution lease cannot grant another caller a worker claim", context do
    install_route(context, "/protected-lease", "PROTECTED", self())
    opts = options(context, nil, "/protected-lease")
    task = Task.async(fn -> Crawler.crawl_now(opts) end)
    assert_receive {:parser_held, worker, page}, 2_000
    on_exit(fn -> send(worker, :release_parser) end)
    state = :sys.get_state(Store)
    lease = state.execution_workers[worker]
    assert is_reference(lease)
    assert Authority.execution_current?(lease, worker)
    refute Authority.execution_current?(lease, self())
    assert :ets.info(Authority, :protection) == :protected
    assert :ets.info(Crawler.Store.Execution, :protection) == :protected
    assert :ets.info(Crawler.Store.Resources, :protection) == :protected

    assert {:error, :unadmitted_execution} =
             Crawler.crawl_now(Map.put(page.opts, :execution_lease, lease))

    assert :sys.get_state(Store).executions[lease] == state.executions[lease]
    refute Store.find_processed({page.url, nil})
    send(worker, :release_parser)
    assert %Store.Page{} = Task.await(task)
    assert Store.find_processed({page.url, nil})
    assert Store.ops_count(nil) == 1
  end

  defp observe_receives(pid) do
    assert :erlang.trace(pid, true, [:receive, {:tracer, self()}]) == 1
    on_exit(fn -> if Process.alive?(pid), do: :erlang.trace(pid, false, [:receive]) end)
    pid
  end

  defp observe_execution(worker, opts) do
    store = observe_receives(Process.whereis(Store))
    state = :sys.get_state(Store)
    lease = state.execution_workers[worker]
    assert is_reference(lease)
    assert Authority.execution_current?(lease, worker)
    record = Map.fetch!(state.executions, lease)
    assert record.opts.scope === opts.scope
    assert record.opts.generation === opts.generation

    %{
      store: store,
      worker: worker,
      monitor: Process.monitor(worker),
      lease: lease,
      arena: record.arena,
      run: {opts.scope, opts.generation},
      scope_keys: Map.keys(state.scopes)
    }
  end

  defp assert_retired(task, retired) do
    %{worker: worker, monitor: monitor, lease: lease, run: {scope, generation}} = retired
    assert {:warn, :stale} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 2_000
    refute Authority.execution_current?(lease)
    refute Authority.current?(scope, generation, nil)

    try do
      await_cleanup(retired)
    after
      :erlang.trace(retired.store, false, [:receive])
    end
  end

  defp await_cleanup(retired) do
    state = :sys.get_state(Store)

    if retired_clean?(state, retired) do
      assert :ets.lookup(Crawler.Store.Execution, retired.lease) == []
      assert :ets.lookup(Crawler.Store.Resources, {:arena, retired.arena}) == []
      assert :ets.lookup(Crawler.Store.Resources, {:run, retired.run}) == []

      assert :ets.match_object(
               Crawler.Store.Resources,
               {{:grant, :_, :_}, retired.lease, :_, :_}
             ) == []

      refute retired.lease in Map.values(state.execution_monitors)
      refute retired.lease in Map.values(state.execution_claims)
      refute Map.has_key?(state.execution_workers, retired.worker)
      refute Map.has_key?(state.resource_monitors, retired.worker)
      assert Map.keys(state.scopes) -- retired.scope_keys == []
    else
      store = retired.store

      assert_receive {:trace, ^store, :receive, event}
                     when not is_tuple(event) or elem(event, 0) != :system,
                     2_000

      await_cleanup(retired)
    end
  end

  defp retired_clean?(state, retired) do
    not Map.has_key?(state.executions, retired.lease) and
      not Map.has_key?(state.resources.arenas, retired.arena) and
      not Map.has_key?(state.resources.runs, retired.run) and
      not Map.has_key?(state.scheduler.frontier.runs, retired.run) and
      not Enum.any?(state.scheduler.claims, fn {_ref, claim} ->
        claim.run == retired.run
      end) and
      not Enum.any?(state.resources.receipts, fn {_ref, record} ->
        record.lease == retired.lease
      end) and
      not Enum.any?(state.claims.active, fn {_ref, claim} ->
        {claim.scope, claim.generation} == retired.run
      end)
  end

  defp run_state(scope) do
    state = :sys.get_state(Store)

    %{
      incarnation: state.incarnation,
      scope: Map.fetch(state.scopes, scope),
      cookies: Map.fetch(state.cookies, scope),
      robots: Map.fetch(state.robots, scope),
      authority: :ets.lookup(Authority, scope),
      pages:
        Map.new(
          Registry.select(Store.DB, [
            {{{:"$1", scope}, :_, :"$2"}, [], [{{:"$1", :"$2"}}]}
          ])
        )
    }
  end

  defp paused_queue do
    scope = unique_scope("reference-queue-owner")
    on_exit(fn -> Store.dispose_scope(scope) end)

    owner =
      start_supervised!({Crawler.Queue, Options.assign_defaults(%{scope: scope, workers: 1})})

    queue = Crawler.Queue.feeder(owner)
    OPQ.pause(queue)
    assert {:paused, _, _} = OPQ.info(queue)
    queue
  end

  defp install_route(context, path, body, observer) do
    ReqTestSite.stub(context.site, "GET", path, fn conn ->
      send(observer, {:requested, path})
      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, body)
    end)
  end

  defp options(context, root, path) do
    Options.assign_defaults(%{
      scope: nil,
      url: context.url <> path,
      site: context.url,
      req_options: context.req_options,
      respect_robots: false,
      store: Store,
      save_to: root,
      retries: 0,
      workers: 1,
      parser: HeldParser,
      hold_parser_url: context.url <> path,
      parser_observer: self()
    })
  end
end
