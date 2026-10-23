defmodule Crawler.RunAuthorityTest do
  use Crawler.TestCase, async: false

  alias Crawler.Parser.CssParser
  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Parser.CssSheets
  alias Crawler.Robots
  alias Crawler.Store
  alias Crawler.Store.Authority

  defmodule HeldFilter do
    def filter(_url, %{hold_before_robots: observer}) do
      send(observer, {:before_robots, self()})

      receive do
        :release -> {:ok, true}
      end
    end

    def filter(_url, _opts), do: {:ok, true}
  end

  for action <- [:reset, :stop, :queue_death] do
    test "#{action} fences every held CSS and robots operation" do
      scope = unique_scope("authority-#{unquote(action)}")
      queue = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> Process.exit(queue, :kill) end)
      generation = Store.generation(scope)
      assert :ok = Store.note_enqueued(scope, generation, queue)
      opts = sheet_opts(scope, generation, queue)
      origin = "http://authority.test"
      observer = self()
      old_body = ~s|:root { --old: url("old.png"); }|
      old_analysis = Scanner.analyze(old_body)

      worker =
        Task.async(fn ->
          assert :owner = Store.claim_robots(scope, origin, generation, queue)
          send(observer, :held_authority)

          receive do
            :release ->
              assert {:ok, []} = CssSheets.remember(opts, old_body, old_analysis)

              assert {:ok, []} =
                       CssSheets.remember(
                         Map.put(opts, :css_sheet, :replace),
                         old_body,
                         old_analysis
                       )

              assert [] = CssSheets.take_urls(opts, old_body, [])
              refute CssSheets.replay?(opts, old_body)
              assert [] = CssSheets.settle(opts)
              assert {:error, :stale} = Store.claim_robots(scope, origin, generation, queue)

              assert {:error, :stale} =
                       Store.finish_robots(
                         scope,
                         origin,
                         Robots.disallow_all(),
                         generation,
                         queue
                       )

              assert {:error, :stale} =
                       Store.forget_robots(scope, origin, Robots.allow_all(), generation, queue)

              assert :ok =
                       Store.save_cookies(scope, origin, ["old=1"], generation, %{queue: queue})
          end
        end)

      assert_receive :held_authority

      case unquote(action) do
        :reset ->
          Store.drop_scope(scope)

        :stop ->
          Crawler.stop(opts)

        :queue_death ->
          monitor = Process.monitor(queue)
          Process.exit(queue, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^queue, :killed}
          wait(2_000, fn -> assert Store.queue_scopes(queue) == [] end)
      end

      fresh_generation = Store.generation(scope)
      refute generation == fresh_generation
      fresh = sheet_opts(scope, fresh_generation, nil)
      assert :owner = Store.claim_robots(scope, origin, fresh_generation)
      assert :ok = Store.finish_robots(scope, origin, Robots.allow_all(), fresh_generation)
      fresh_body = ~s|body { background: var(--old, url("fresh.png")); }|
      assert [%{value: "fresh.png"}] = CssParser.spans(fresh_body, fresh)
      css_before = Map.get(:sys.get_state(CssSheets).scopes, {scope, fresh_generation})
      send(worker.pid, :release)
      Task.await(worker)
      assert Map.get(:sys.get_state(CssSheets).scopes, {scope, fresh_generation}) == css_before
      assert {:ready, rules} = Store.claim_robots(scope, origin, fresh_generation)
      assert Robots.allowed?(rules, origin <> "/private", "Crawler")
      assert Store.cookie_header(scope, origin, fresh_generation) == nil
      assert :ok = Store.dispose_scope(scope)
    end
  end

  test "CSS requests queued before reset validate authority when the mutation runs" do
    scope = unique_scope("queued-css-revocation")
    generation = Store.generation(scope)
    opts = sheet_opts(scope, generation, nil)
    body = ~s|:root { --old: url("old.png"); }|
    css = Process.whereis(CssSheets)
    :sys.suspend(css)
    on_exit(fn -> if Process.alive?(css), do: :sys.resume(css) end)
    remembering = Task.async(fn -> CssSheets.remember(opts, body, Scanner.analyze(body)) end)

    wait(2_000, fn ->
      {:messages, messages} = Process.info(css, :messages)

      assert Enum.any?(messages, fn
               {:"$gen_call", {caller, _},
                {:describe,
                 %{scope: ^scope, generation: ^generation, queue: nil, execution_lease: lease},
                 {^scope, ^generation, _}}} ->
                 Authority.execution_current?(lease, caller)

               _ ->
                 false
             end)
    end)

    resetting = Task.async(fn -> Store.drop_scope(scope) end)
    wait(2_000, fn -> refute Authority.current?(scope, generation, nil) end)
    :sys.resume(css)
    assert {:ok, []} = Task.await(remembering)
    fresh_generation = Task.await(resetting)
    fresh = sheet_opts(scope, fresh_generation, nil)

    assert [%{value: "fresh.png"}] =
             CssParser.spans(~s|body { background: var(--old, url("fresh.png")); }|, fresh)

    Store.dispose_scope(scope)
  end

  test "a retired queue cannot mutate shared-scope caches through its surviving generation" do
    scope = unique_scope("shared-authority")
    generation = Store.generation(scope)
    survivor = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(survivor, :kill) end)
    assert :ok = Store.note_enqueued(scope, generation, self())
    assert :ok = Store.note_enqueued(scope, generation, survivor)
    assert :ok = Store.release_queue(self())
    assert Store.generation(scope) == generation
    refute Authority.current?(scope, generation, self())
    assert Authority.current?(scope, generation, survivor)
    opts = sheet_opts(scope, generation, self())
    body = ~s|:root { --old: url("old.png"); }|
    assert {:ok, []} = CssSheets.remember(opts, body, Scanner.analyze(body))

    assert {:error, :stale} =
             Store.claim_robots(scope, "http://authority.test", generation, self())

    Store.save_cookies(scope, "http://authority.test", ["old=1"], generation, %{queue: self()})

    assert Store.cookie_header(scope, "http://authority.test", generation, %{queue: survivor}) ==
             nil

    Store.dispose_scope(scope)
  end

  test "queue retirement releases robots waiters so a surviving queue can acquire ownership" do
    scope = unique_scope("robots-queue-waiter")
    generation = Store.generation(scope)
    origin = "http://authority.test"
    survivor = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(survivor, :kill) end)
    Store.note_enqueued(scope, generation, self())
    Store.note_enqueued(scope, generation, survivor)
    assert :owner = Store.claim_robots(scope, origin, generation, self())

    waiter =
      Task.async(fn ->
        assert :retry = Store.claim_robots(scope, origin, generation, survivor)
        assert :owner = Store.claim_robots(scope, origin, generation, survivor)
        Store.finish_robots(scope, origin, Robots.allow_all(), generation, survivor)
      end)

    wait(2_000, fn ->
      assert {:loading, _, _, _, [_]} = get_in(:sys.get_state(Store).robots, [scope, origin])
    end)

    assert :ok = Store.release_queue(self())
    assert :ok = Task.await(waiter)
    assert {:ready, rules} = Store.claim_robots(scope, origin, generation, survivor)
    assert Robots.allowed?(rules, origin <> "/page", "Crawler")
    Store.dispose_scope(scope)
  end

  test "stopped scopes retain no authority or empty revision records" do
    before = :sys.get_state(Store)
    authority_before = :ets.info(Authority, :size)

    disposed =
      for index <- 1..100 do
        scope = unique_scope("dispose-#{index}")
        generation = Store.generation(scope)
        opts = sheet_opts(scope, generation, nil)
        body = ~s|:root { --old: url("old.png"); }|
        assert {:ok, []} = CssSheets.remember(opts, body, Scanner.analyze(body))
        assert :ok = Crawler.stop(opts)
        refute Store.current?(scope, generation)
        refute Authority.current?(scope, generation, nil)
        refute Map.has_key?(:sys.get_state(Store).scopes, scope)
        next = Store.generation(scope)
        refute next == generation
        Store.dispose_scope(scope)
        scope
      end

    assert :sys.get_state(Store).scopes == before.scopes

    wait(2_000, fn ->
      refute Enum.any?(:sys.get_state(CssSheets).scopes, fn {{scope, _generation}, _} ->
               scope in disposed
             end)
    end)

    assert :ets.info(Authority, :size) == authority_before
  end

  test "standalone scoped CSS parsing does not create run state" do
    scope = unique_scope("pure-css")
    opts = %{scope: scope, url: "http://authority.test/app.css"}

    assert [%{value: "local.png"}] =
             CssParser.spans(~s|body { background: url("local.png"); }|, opts)

    refute Enum.any?(:sys.get_state(CssSheets).scopes, fn {{run_scope, _generation}, _} ->
             run_scope == scope
           end)

    refute Map.has_key?(:sys.get_state(Store).scopes, scope)
  end

  test "a worker released from a filter after reset cannot acquire fresh robots state", context do
    scope = unique_scope("held-robots-acquisition")
    old_url = context.url <> "/retired"
    fresh_url = context.url <> "/fresh"
    observer = self()

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      send(observer, :fresh_robots_request)
      Plug.Conn.resp(conn, 200, "User-agent: *\nAllow: /\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/fresh", &Plug.Conn.resp(&1, 200, "FRESH"))

    assert {:ok, old} =
             start_crawl(old_url,
               scope: scope,
               req_options: context.req_options,
               store: Store,
               respect_robots: true,
               url_filter: HeldFilter,
               hold_before_robots: self(),
               retries: 0,
               workers: 2,
               interval: 1
             )

    assert_receive {:before_robots, worker}, 2_000
    on_exit(fn -> send(worker, :release) end)
    monitor = Process.monitor(worker)
    Store.drop_scope(scope)

    assert {:ok, fresh} =
             start_crawl(fresh_url,
               scope: scope,
               queue: old.queue,
               req_options: context.req_options,
               store: Store,
               respect_robots: true,
               retries: 0
             )

    assert_receive :fresh_robots_request, 2_000
    await_idle(fresh)
    robots_before = :sys.get_state(Store).robots
    send(worker, :release)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2_000
    assert :sys.get_state(Store).robots == robots_before
    refute Store.find({old_url, scope})
    assert %Store.Page{body: "FRESH"} = Store.find_processed({fresh_url, scope})
  end

  defp sheet_opts(scope, generation, queue) do
    %{
      scope: scope,
      generation: generation,
      queue: queue,
      url: "http://authority.test/app.css",
      referrer_url: "http://authority.test/app.css",
      style_group: "http://authority.test/page"
    }
  end
end
