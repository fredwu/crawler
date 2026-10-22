defmodule Crawler.CssCacheFailureTest do
  use Crawler.TestCase, async: false

  alias Crawler.Parser.CssParser
  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Parser.CssParser.Variables
  alias Crawler.Parser.CssSheets
  alias Crawler.Store
  alias Crawler.Store.Authority
  alias Crawler.Store.DB

  for action <- [:reset, :stop, :queue_retirement] do
    test "#{action} survives CSS exit and does not wait for the derived cache", context do
      scope = unique_scope("css-failure-#{unquote(action)}")
      generation = Store.generation(scope)
      Store.note_enqueued(scope, generation, self())
      opts = sheet_options(scope, generation)
      old_body = ~s|:root { --old: url("old.png"); }|
      assert {:ok, []} = CssSheets.remember(opts, old_body, Scanner.analyze(old_body))

      page_url = context.url <> "/css-failure-survivor"

      ReqTestSite.expect_once(
        context.site,
        "GET",
        "/css-failure-survivor",
        &Plug.Conn.resp(&1, 200, "SURVIVOR")
      )

      assert {:ok, unrelated} =
               start_crawl(page_url,
                 scope: unique_scope("cache-survivor"),
                 req_options: context.req_options,
                 store: Store,
                 retries: 0,
                 interval: 1
               )

      await_idle(unrelated)
      page = Store.find_processed({page_url, unrelated.scope})
      store = Process.whereis(Store)
      registry = Process.whereis(DB)
      css = Process.whereis(CssSheets)
      monitor = Process.monitor(css)
      :sys.suspend(css)
      on_exit(fn -> restore_css_cache() end)

      retiring =
        Task.async(fn ->
          case unquote(action) do
            :reset -> Store.drop_scope(scope)
            :stop -> Crawler.stop(opts)
            :queue_retirement -> Store.release_queue(opts.queue)
          end
        end)

      wait(2_000, fn -> refute Authority.current?(scope, generation, opts.queue) end)
      assert Process.alive?(css)
      assert :ok = Supervisor.terminate_child(Crawler, CssSheets)
      assert_receive {:DOWN, ^monitor, :process, ^css, :shutdown}, 2_000
      result = Task.await(retiring, 2_000)
      if unquote(action) != :reset, do: assert(result == :ok)
      assert Process.whereis(Store) == store
      assert Process.whereis(DB) == registry
      assert Process.alive?(unrelated.queue)
      assert Process.alive?(unrelated.queue_owner)
      assert Store.current?(unrelated.scope, unrelated.generation, unrelated.queue)
      assert Store.find_processed({page_url, unrelated.scope}) == page
      assert {:ok, fresh_cache} = Supervisor.restart_child(Crawler, CssSheets)
      refute fresh_cache == css
      assert :sys.get_state(CssSheets).scopes == %{}
      fresh_generation = Store.generation(scope)
      fresh = Map.put(sheet_options(scope, fresh_generation), :queue, nil)

      assert [%{value: "fresh.png"}] =
               CssParser.spans(~s|body { background: var(--old, url("fresh.png")); }|, fresh)

      assert {:ok, []} = CssSheets.remember(opts, old_body, Scanner.analyze(old_body))
      Store.dispose_scope(scope)
    end
  end

  test "a fresh generation is isolated before retired CSS entries are cleaned" do
    scope = unique_scope("css-generation-namespace")
    old_generation = Store.generation(scope)
    old = Map.put(sheet_options(scope, old_generation), :queue, nil)
    body = ~s|:root { --old: url("old.png"); }|
    assert {:ok, []} = CssSheets.remember(old, body, Scanner.analyze(body))
    css = Process.whereis(CssSheets)
    :sys.suspend(css)
    on_exit(fn -> if Process.alive?(css), do: :sys.resume(css) end)
    generation = Store.drop_scope(scope)
    refute generation == old_generation
    :sys.resume(css)
    fresh = %{old | generation: generation}

    assert [%{value: "fresh.png"}] =
             CssParser.spans(~s|body { background: var(--old, url("fresh.png")); }|, fresh)

    Store.dispose_scope(scope)
  end

  for action <- [:remember, :preview] do
    test "#{action} contains graph failure and preserves the original group" do
      scope = unique_scope("css-limit-#{unquote(action)}")
      generation = Store.generation(scope)
      assert :ok = Store.note_enqueued(scope, generation, self())
      on_exit(fn -> Store.dispose_scope(scope) end)
      opts = sheet_options(scope, generation)
      original = ":root{--old:url(old.png)}a{background:var(--old)}"
      assert {:ok, [_token]} = CssSheets.remember(opts, original, Scanner.analyze(original))
      css = Process.whereis(CssSheets)
      store = Process.whereis(Store)
      before = cached_scope(scope, generation)
      limited = deep_css("var(--v256)")

      request =
        if unquote(action) == :preview, do: Map.put(opts, :css_sheet, :replace), else: opts

      error =
        assert_raise Variables.LimitError, fn ->
          CssSheets.remember(request, limited, Scanner.analyze(limited))
        end

      assert error.limit == :depth
      assert Process.whereis(CssSheets) == css
      assert Process.whereis(Store) == store
      assert cached_scope(scope, generation) == before
      assert CssSheets.take_urls(opts, original, []) == ["http://cache.test/old.png"]
      assert {:ok, [_token]} = CssSheets.remember(opts, original, Scanner.analyze(original))
      assert_unrelated_group(opts)
      fresh = Store.drop_scope(scope)
      assert {:ok, []} = CssSheets.remember(request, limited, Scanner.analyze(limited))
      assert CssSheets.take_urls(opts, limited, []) == []
      assert CssSheets.settle(opts) == []
      assert Store.current?(scope, fresh)
      assert Process.whereis(CssSheets) == css
    end
  end

  test "a limited fallback settlement rolls back pending and failed import state" do
    scope = unique_scope("css-limit-settlement")
    generation = Store.generation(scope)
    assert :ok = Store.note_enqueued(scope, generation, self())
    on_exit(fn -> Store.dispose_scope(scope) end)
    opts = sheet_options(scope, generation)
    body = "@import 'pending.css';" <> deep_css("var(--missing,var(--v256))")
    assert {:ok, []} = CssSheets.remember(opts, body, Scanner.analyze(body))
    before = cached_scope(scope, generation)
    css = Process.whereis(CssSheets)

    error =
      assert_raise Variables.LimitError, fn ->
        CssSheets.settle(%{opts | url: "http://cache.test/pending.css"})
      end

    assert error.limit == :depth
    assert cached_scope(scope, generation) == before
    assert Process.whereis(CssSheets) == css
    assert CssSheets.take_urls(opts, body, []) == []
    assert {:ok, []} = CssSheets.remember(opts, body, Scanner.analyze(body))
    assert_unrelated_group(opts)
  end

  defp deep_css(use) do
    ":root{--v0:url(deep.png);" <>
      Enum.map_join(1..256, fn n -> "--v#{n}:var(--v#{n - 1});" end) <>
      "}a{background:url(direct.png),#{use}}"
  end

  defp cached_scope(scope, generation),
    do: Map.fetch!(:sys.get_state(CssSheets).scopes, {scope, generation})

  defp assert_unrelated_group(opts) do
    opts = Map.put(opts, :url, "http://cache.test/unrelated.css")
    body = ":root{--healthy:url(healthy.png)}a{background:var(--healthy)}"
    assert {:ok, [_token]} = CssSheets.remember(opts, body, Scanner.analyze(body))
    assert CssSheets.take_urls(opts, body, []) == ["http://cache.test/healthy.png"]
  end

  defp sheet_options(scope, generation) do
    %{scope: scope, generation: generation, queue: self(), url: "http://cache.test/app.css"}
  end

  defp restore_css_cache do
    case Process.whereis(CssSheets) do
      nil -> Supervisor.restart_child(Crawler, CssSheets)
      pid -> :sys.resume(pid)
    end
  end
end
