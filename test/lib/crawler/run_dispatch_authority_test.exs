defmodule Crawler.RunDispatchAuthorityTest do
  use Crawler.TestCase, async: false

  alias Crawler.HeldParser
  alias Crawler.Options
  alias Crawler.QueueHandler
  alias Crawler.SnapshotHelpers
  alias Crawler.Store

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
      root = tmp(unique_scope("retired-parser"))
      on_exit(fn -> File.rm_rf(root) end)
      observer = self()
      install_route(context, "/held-parent", ~s(<a href="/retired-child">child</a>), observer)
      install_route(context, "/retired-child", "CHILD", observer)
      opts = options(context, root, "/held-parent")
      opts = if unquote(identity) == :absent, do: Map.delete(opts, :scope), else: opts
      task = Task.async(fn -> Crawler.crawl_now(opts) end)
      assert_receive {:parser_held, worker, page}, 2_000
      on_exit(fn -> send(worker, :release_parser) end)
      assert page.opts[:scope] == nil
      snapshot = File.read!(SnapshotHelpers.saved(root, page.url))

      case unquote(retirement) do
        :reset -> Store.drop_scope(nil)
        :stop -> Crawler.stop(page.opts)
      end

      before = :sys.get_state(Store)
      send(worker, :release_parser)
      assert {:warn, :stale} = Task.await(task)
      wait(fn -> assert :sys.get_state(Store) == before end)
      refute_receive {:requested, "/retired-child"}
      refute Store.find({context.url <> "/retired-child", nil})
      refute File.exists?(SnapshotHelpers.saved(root, context.url <> "/retired-child"))
      assert File.read!(SnapshotHelpers.saved(root, page.url)) == snapshot
    end
  end

  for identity <- [nil, :absent] do
    test "live #{inspect(identity)}-scope descendants share their run identity and page budget",
         context do
      root = tmp(unique_scope("live-nil-dispatch"))
      on_exit(fn -> File.rm_rf(root) end)
      observer = self()
      install_route(context, "/live-parent", ~s(<a href="/live-child">child</a>), observer)
      install_route(context, "/live-child", ~s(<a href="/over-budget">extra</a>), observer)
      install_route(context, "/over-budget", "EXTRA", observer)
      opts = %{options(context, root, "/live-parent") | max_pages: 2}
      opts = if unquote(identity) == :absent, do: Map.delete(opts, :scope), else: opts
      scopes_before = Map.keys(:sys.get_state(Store).scopes)
      assert {:ok, bound} = QueueHandler.enqueue(opts)
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
      assert Map.keys(:sys.get_state(Store).scopes) -- scopes_before == [nil]
      assert {:ok, reused} = QueueHandler.enqueue(%{bound | url: context.url <> "/over-budget"})
      assert reused.queue_owner == bound.queue_owner
      await_idle(reused)
      refute_receive {:requested, "/over-budget"}
      assert :ok = Crawler.stop(reused)
      refute Store.current?(nil, bound.generation)
      refute Store.find({child.url, nil})
      refute Process.alive?(bound.queue)
    end
  end

  for retirement <- [:reset, :stop] do
    test "a held force manifest cannot repeat a root reset after #{retirement}", context do
      scope = unique_scope("force-manifest")
      root = tmp(scope)

      on_exit(fn ->
        File.rm_rf(root)
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

      case unquote(retirement) do
        :reset -> Store.drop_scope(scope)
        :stop -> Crawler.stop(page.opts)
      end

      before = :sys.get_state(Store)
      send(worker, :release_parser)
      assert {:warn, :stale} = Task.await(task)
      wait(fn -> assert :sys.get_state(Store) == before end)
      refute_receive {:requested, "/force-child"}
      refute File.exists?(SnapshotHelpers.saved(root, context.url <> "/force-child"))
    end
  end

  test "a live force manifest keeps the startup generation for its depth-zero page", context do
    scope = unique_scope("live-force-manifest")
    root = tmp(scope)

    on_exit(fn ->
      File.rm_rf(root)
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
    assert child.opts.force
    assert Store.current?(scope, bound.generation, bound.queue)
  end

  test "parser-returned page metadata cannot grant completion authority", context do
    root = tmp(unique_scope("parser-completion-authority"))
    on_exit(fn -> File.rm_rf(root) end)
    install_route(context, "/completion-parent", "OLD", self())
    opts = options(context, root, "/completion-parent")
    task = Task.async(fn -> Crawler.crawl_now(opts) end)
    assert_receive {:parser_held, worker, old}, 2_000
    on_exit(fn -> send(worker, :release_parser) end)
    generation = Store.drop_scope(nil)
    fresh_opts = %{url: old.url, scope: nil, generation: generation, queue: nil}
    assert {:ok, _} = Store.add({old.url, nil}, generation)
    assert {_, _} = Store.add_page_data({old.url, nil}, "FRESH", fresh_opts)
    fresh = Store.find({old.url, nil})
    before = :sys.get_state(Store)
    send(worker, {:release_parser, fresh})
    assert {:warn, :stale} = Task.await(task)
    assert Store.find({old.url, nil}) == fresh
    assert :sys.get_state(Store) == before
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
    assert {:ok, rejected} = Crawler.crawl_reference(opts.url, opts)
    assert rejected.generation === generation
    assert {:ok, rejected_list} = Crawler.crawl_reference(opts.url, Map.to_list(opts))
    assert rejected_list.generation === generation
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
    before = :sys.get_state(Store)
    full = ~s(<urlset><url><loc>#{context.url}/sitemap-over-budget</loc></url></urlset>)
    assert Crawler.Sitemap.ingest(opts, full)
    assert :sys.get_state(Store) == before
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

    results = Crawler.Parser.parse_links(html, opts, &Crawler.Dispatcher.dispatch/2)
    assert [{:ok, bound}] = results |> List.flatten() |> Enum.reject(&is_nil/1)
    on_exit(fn -> Store.dispose_scope(bound.scope) end)
    assert {:paused, %OPQ.Queue{data: pending}, _} = OPQ.info(queue)
    assert [queued] = :queue.to_list(pending)
    refute Map.has_key?(queued, :document_styles)
    refute Map.has_key?(queued, :document_style_id)
    OPQ.resume(queue)
    await_idle(bound)
    stored = Store.find_processed({context.url <> "/local-context-picture", bound.scope})
    assert stored
    refute Map.has_key?(stored.opts, :document_styles)
    refute Map.has_key?(stored.opts, :document_style_id)
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
