defmodule Crawler.FetcherAuthorityTest do
  use Crawler.TestCase, async: false

  alias Crawler.Fetcher
  alias Crawler.Options
  alias Crawler.SnapshotHelpers
  alias Crawler.Store

  defmodule CapturingFilter do
    def filter(_url, opts) do
      send(opts.observer, {:direct_fetch, self(), opts})

      if opts[:hold_direct_fetch] do
        receive do
          :release -> :ok
        end
      end

      {:ok, true}
    end
  end

  defmodule RejectingFilter do
    def filter(_url, opts) do
      send(opts.observer, :duplicate_filter_called)
      {:error, :reference_rejected}
    end
  end

  defmodule FailingAliasStore do
    def add_page_data({url, _scope}, _body, %{alias_failure_url: url}),
      do: {:error, :alias_storage_failed}

    def add_page_data(key, body, opts), do: Store.add_page_data(key, body, opts)
  end

  test "a direct fetch without a scope acquires one token and preserves nil-scope page identity",
       context do
    page = context.url <> "/direct-authority"

    ReqTestSite.expect_once(
      context.site,
      "GET",
      "/direct-authority",
      &Plug.Conn.resp(&1, 200, "DIRECT")
    )

    opts = options(context, page)

    assert %Store.Page{body: "DIRECT", opts: stored} = Fetcher.fetch(opts)
    assert_receive {:direct_fetch, _, observed}
    assert observed.generation == stored.generation
    assert stored.generation == Store.generation(nil)
    refute Map.has_key?(observed, :scope)
    assert Store.find({page, nil}).body == "DIRECT"
    Store.delete({page, nil}, stored.generation)
  end

  test "a direct fetch does not refresh an explicit stale token", context do
    scope = unique_scope("direct-explicit-stale")
    stale = Store.generation(scope)
    Store.drop_scope(scope)

    opts =
      Map.merge(options(context, context.url <> "/direct-stale"), %{
        scope: scope,
        generation: stale
      })

    assert {:warn, :stale} = Fetcher.fetch(opts)
    refute_received {:direct_fetch, _, _}
    refute Store.find({opts.url, scope})
    Store.dispose_scope(scope)
  end

  test "a keyword direct fetch binds once without adding a scope", context do
    url = context.url <> "/keyword-direct"
    on_exit(fn -> Store.dispose_scope(nil) end)

    ReqTestSite.expect_once(context.site, "GET", "/keyword-direct", fn conn ->
      Plug.Conn.resp(conn, 200, "KEYWORD")
    end)

    opts = options(context, url) |> Map.put(:respect_robots, false) |> Map.to_list()
    assert %Store.Page{body: "KEYWORD", opts: stored} = Fetcher.fetch(opts)
    assert_receive {:direct_fetch, _, observed}
    assert observed.generation === stored.generation
    refute Map.has_key?(observed, :scope)
    assert Store.find({url, nil}).body == "KEYWORD"
  end

  test "a keyword direct fetch preserves an explicit stale generation", context do
    generation = Store.generation(nil)
    Store.drop_scope(nil)
    on_exit(fn -> Store.dispose_scope(nil) end)

    opts =
      context
      |> options(context.url <> "/keyword-stale")
      |> Map.put(:generation, generation)
      |> Map.to_list()

    assert {:warn, :stale} = Fetcher.fetch(opts)
    refute_received {:direct_fetch, _, _}
    refute Store.find({opts[:url], nil})
  end

  test "an absent-scope duplicate asset keeps its seen result before URL filtering", context do
    url = context.url <> "/direct-duplicate"
    on_exit(fn -> Store.dispose_scope(nil) end)

    ReqTestSite.expect_once(context.site, "GET", "/direct-duplicate", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.resp(200, "PNG")
    end)

    opts = Map.merge(options(context, url), %{html_tag: "img", respect_robots: false})
    assert %Store.Page{} = Fetcher.fetch(opts)
    original = Store.find({url, nil})

    assert {:warn, "Fetch failed check 'not_fetched_yet?'" <> _} =
             Fetcher.fetch(%{opts | url_filter: RejectingFilter})

    refute_received :duplicate_filter_called
    assert Store.find({url, nil}) == original
  end

  test "an absent-scope stored document upgrade admits the reference only once", context do
    url = context.url <> "/direct-stored-svg"
    on_exit(fn -> Store.dispose_scope(nil) end)

    ReqTestSite.expect_once(context.site, "GET", "/direct-stored-svg", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("image/svg+xml") |> Plug.Conn.resp(200, "<svg/>")
    end)

    opts = Map.merge(options(context, url), %{html_tag: "img", respect_robots: false})
    assert %Store.Page{opts: stored} = Fetcher.fetch(opts)
    assert_receive {:direct_fetch, _, _}
    assert {_, _} = Store.processed({url, nil}, stored.generation)
    assert %Store.Page{body: "<svg/>"} = Fetcher.fetch(%{opts | html_tag: "a"})
    assert_receive {:direct_fetch, _, admitted}
    refute Map.has_key?(admitted, :scope)
    refute_received {:direct_fetch, _, _}
    assert Store.find_processed({url, nil}).opts.html_tag == "a"
  end

  test "an absent-scope redirect rolls back its newly created alias after storage failure",
       context do
    url = context.url <> "/direct-alias-source"
    landing = context.url <> "/direct-alias-landing"
    on_exit(fn -> Store.dispose_scope(nil) end)

    ReqTestSite.expect_once(context.site, "GET", "/direct-alias-source", fn conn ->
      conn |> Plug.Conn.put_resp_header("location", landing) |> Plug.Conn.resp(302, "")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/direct-alias-landing", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, "LANDED")
    end)

    opts =
      Map.merge(options(context, url), %{
        respect_robots: false,
        store: FailingAliasStore,
        alias_failure_url: landing
      })

    assert {:error, :alias_storage_failed} = Fetcher.fetch(opts)
    refute Store.find({landing, nil})
    assert Store.find({url, nil})
  end

  test "a direct nil-scope worker held before robots cannot acquire the next run's cache",
       context do
    old_url = context.url <> "/direct-retired"
    observer = self()

    old =
      Task.async(fn ->
        options(context, old_url)
        |> Map.merge(%{observer: observer, hold_direct_fetch: true})
        |> Fetcher.fetch()
      end)

    assert_receive {:direct_fetch, worker, observed}, 2_000
    on_exit(fn -> send(worker, :release) end)
    fresh_generation = Store.drop_scope(nil)
    refute fresh_generation == observed.generation
    fresh_url = context.url <> "/direct-fresh"

    ReqTestSite.expect_once(
      context.site,
      "GET",
      "/direct-fresh",
      &Plug.Conn.resp(&1, 200, "FRESH")
    )

    assert %Store.Page{body: "FRESH", opts: fresh} = Fetcher.fetch(options(context, fresh_url))
    assert fresh.generation == fresh_generation
    robots = :sys.get_state(Store).robots
    send(worker, :release)
    assert {:warn, _reason} = Task.await(old)
    assert :sys.get_state(Store).robots == robots
    refute Store.find({old_url, nil})
    assert Store.find({fresh_url, nil}).body == "FRESH"
    Store.delete({fresh_url, nil}, fresh_generation)
  end

  test "stopping standalone options without a generation leaves nil-scope authority intact" do
    generation = Store.generation(nil)
    assert :ok = Crawler.stop(%{})
    assert :ok = Crawler.stop(%{scope: nil})
    assert Store.current?(nil, generation)
  end

  for retirement <- [:reset, :stop] do
    test "#{retirement} fences a direct nil-scope fetch held before snapshot publication",
         context do
      url = context.url <> "/nil-scope-publication"
      root = tmp(unique_scope("nil-scope-publication"))
      on_exit(fn -> File.rm_rf(root) end)
      observer = self()
      {:ok, hits} = Agent.start_link(fn -> 0 end)

      ReqTestSite.stub(context.site, "GET", "/nil-scope-publication", fn conn ->
        hit = Agent.get_and_update(hits, &{&1, &1 + 1})
        body = if hit == 0, do: "OLD", else: "FRESH"
        conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, body)
      end)

      before_publish = fn ->
        send(observer, {:nil_snapshot_held, self()})
        receive do: (:release -> :ok)
      end

      opts = Map.merge(options(context, url), %{save_to: root, before_publish: before_publish})
      old = Task.async(fn -> Fetcher.fetch(opts) end)
      assert_receive {:nil_snapshot_held, worker}, 2_000
      on_exit(fn -> send(worker, :release) end)
      old_page = Store.find({url, nil})
      generation = old_page.opts.generation

      fresh_generation =
        case unquote(retirement) do
          :reset ->
            Store.drop_scope(nil)

          :stop ->
            assert :ok = Crawler.stop(old_page.opts)
            Store.generation(nil)
        end

      refute fresh_generation == generation
      assert %Store.Page{body: "FRESH"} = Fetcher.fetch(Map.delete(opts, :before_publish))
      page = Store.find({url, nil})
      file = SnapshotHelpers.saved(root, url)
      snapshot = File.read!(file)
      assert snapshot == <<0xEF, 0xBB, 0xBF, "FRESH">>
      send(worker, :release)
      assert {:warn, :stale} = Task.await(old)
      assert Store.find({url, nil}) == page
      assert File.read!(file) == snapshot
      assert Path.wildcard(Path.join(root, "**/.crawler-*.tmp"), match_dot: true) == []
      Store.delete({url, nil}, fresh_generation)
    end
  end

  defp options(context, url) do
    opts =
      Options.assign_defaults(%{
        url: url,
        req_options: context.req_options,
        store: Store,
        observer: self(),
        url_filter: CapturingFilter,
        retries: 0
      })

    Map.delete(opts, :scope)
  end
end
