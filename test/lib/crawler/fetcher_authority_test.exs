defmodule Crawler.FetcherAuthorityTest do
  use Crawler.TestCase, async: false

  alias Crawler.Fetcher
  alias Crawler.ManagedSnapshotHelpers
  alias Crawler.Options
  alias Crawler.Store
  alias Crawler.Store.Authority

  setup do
    Store.dispose_scope(nil)
    on_exit(fn -> Store.dispose_scope(nil) end)
    :ok
  end

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
    assert Map.fetch!(observed, :scope) == nil
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

    assert {:error, :stale} = Fetcher.fetch(opts)
    refute_received {:direct_fetch, _, _}
    refute Store.find({opts.url, scope})
    Store.dispose_scope(scope)
  end

  test "a keyword direct fetch pins nil scope once", context do
    url = context.url <> "/keyword-direct"
    on_exit(fn -> Store.dispose_scope(nil) end)

    ReqTestSite.expect_once(context.site, "GET", "/keyword-direct", fn conn ->
      Plug.Conn.resp(conn, 200, "KEYWORD")
    end)

    opts = options(context, url) |> Map.put(:respect_robots, false) |> Map.to_list()
    assert %Store.Page{body: "KEYWORD", opts: stored} = Fetcher.fetch(opts)
    assert_receive {:direct_fetch, _, observed}
    assert observed.generation === stored.generation
    assert Map.fetch!(observed, :scope) == nil
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

    assert {:error, :stale} = Fetcher.fetch(opts)
    refute_received {:direct_fetch, _, _}
    refute Store.find({opts[:url], nil})
  end

  test "a new direct reference context applies its filter without changing the stored asset",
       context do
    url = context.url <> "/direct-duplicate"
    on_exit(fn -> Store.dispose_scope(nil) end)

    ReqTestSite.expect_once(context.site, "GET", "/direct-duplicate", fn conn ->
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.resp(200, "PNG")
    end)

    opts = Map.merge(options(context, url), %{html_tag: "img", respect_robots: false})
    assert %Store.Page{} = Fetcher.fetch(opts)
    original = Store.find({url, nil})

    assert {:error, :reference_rejected} =
             Fetcher.fetch(%{opts | url_filter: RejectingFilter})

    assert_received :duplicate_filter_called
    assert Store.find({url, nil}) == original
  end

  test "a custom redirect filter gives a document upgrade its own private attempt", context do
    url = context.url <> "/direct-stored-svg"
    on_exit(fn -> Store.dispose_scope(nil) end)

    {:ok, calls} = Agent.start_link(fn -> 0 end)

    ReqTestSite.expect(context.site, "GET", "/direct-stored-svg", fn conn ->
      Agent.update(calls, &(&1 + 1))
      conn |> Plug.Conn.put_resp_content_type("image/svg+xml") |> Plug.Conn.resp(200, "<svg/>")
    end)

    opts = Map.merge(options(context, url), %{html_tag: "img", respect_robots: false})
    assert %Store.Page{opts: stored} = Fetcher.fetch(opts)
    assert_receive {:direct_fetch, _, _}
    assert {_, _} = Store.processed({url, nil}, stored.generation)
    assert %Store.Page{body: "<svg/>"} = Fetcher.fetch(%{opts | html_tag: "a"})
    assert_receive {:direct_fetch, _, admitted}
    assert admitted.scope == nil
    refute_received {:direct_fetch, _, _}
    assert Store.find_processed({url, nil}).opts.html_tag == "a"
    assert Agent.get(calls, & &1) == 2
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
    refute Store.find({url, nil})
    state = :sys.get_state(Store)

    assert [record] =
             for(
               {_id, %{job: job} = record} <- state.scheduler.frontier.jobs,
               job.logical_key == url,
               do: record
             )

    assert %{status: :failed, reason: :alias_storage_failed} = record.outcome
  end

  test "a direct nil-scope worker held before robots cannot acquire the next run's cache",
       context do
    old_url = context.url <> "/direct-retired"
    observer = self()

    supervisor = start_supervised!(Task.Supervisor)

    old =
      Task.Supervisor.async_nolink(supervisor, fn ->
        options(context, old_url)
        |> Map.merge(%{observer: observer, hold_direct_fetch: true})
        |> Fetcher.fetch()
      end)

    assert_receive {:direct_fetch, worker, observed}, 2_000
    on_exit(fn -> send(worker, :release) end)
    retired = observe_fetch_execution(worker, observed)
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
    assert_cancelled_fetch(old, retired)
    send(worker, :release)
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
      root = Path.join(tmp(unique_scope("nil-scope-publication")), "archive")
      on_exit(fn -> File.rm_rf(Path.dirname(root)) end)
      observer = self()
      {:ok, hits} = Agent.start_link(fn -> 0 end)

      ReqTestSite.stub(context.site, "GET", "/nil-scope-publication", fn conn ->
        hit = Agent.get_and_update(hits, &{&1, &1 + 1})
        body = if hit == 0, do: "OLD", else: "FRESH"

        conn
        |> Plug.Conn.put_resp_content_type("application/octet-stream")
        |> Plug.Conn.resp(200, body)
      end)

      opts = Map.merge(options(context, url), %{save_to: root, respect_robots: false})
      assert {:ok, staged} = ManagedSnapshotHelpers.stage_copy(opts)
      generation = staged.generation
      old_page = Store.find({url, nil})
      assert old_page.body == "OLD"
      supervisor = start_supervised!(Task.Supervisor)

      old =
        Task.Supervisor.async_nolink(supervisor, fn ->
          ManagedSnapshotHelpers.finalize_copy(staged, fn %{owned: owned, filesystem: filesystem} ->
            send(observer, {:nil_snapshot_held, self(), owned, filesystem.filesystem})

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive {:nil_snapshot_held, worker, owned, filesystem}, 2_000
      on_exit(fn -> send(worker, :release) end)
      retired = observe_fetch_execution(worker, owned)
      filesystem_monitor = Process.monitor(filesystem)
      refute File.exists?(root)

      fresh_generation =
        case unquote(retirement) do
          :reset ->
            Store.drop_scope(nil)

          :stop ->
            assert :ok = Crawler.stop(staged)
            Store.generation(nil)
        end

      refute fresh_generation == generation
      assert {:ok, {:error, :stale}} = Task.yield(old, 2_000)
      assert_retired_execution(retired)
      assert_receive {:DOWN, ^filesystem_monitor, :process, ^filesystem, _}, 2_000
      assert {:ok, fresh} = ManagedSnapshotHelpers.stage_copy(opts)
      assert fresh.generation == fresh_generation
      assert {:ok, :committed} = ManagedSnapshotHelpers.finalize_copy(fresh)
      export = ManagedSnapshotHelpers.ready_export(fresh)
      resource = ManagedSnapshotHelpers.resource_for_url(export, url)
      file = ManagedSnapshotHelpers.artifact_path(export, resource)
      assert resource["content_type"] == "application/octet-stream"
      snapshot = File.read!(file)
      assert snapshot == "FRESH"
      page = Store.find({url, nil})
      assert page.body == "FRESH"
      send(worker, :release)
      assert Store.find({url, nil}) == page
      assert File.read!(file) == snapshot

      assert Path.wildcard(Path.join(Path.dirname(root), "**/.crawler-*.tmp"), match_dot: true) ==
               []

      Store.delete({url, nil}, fresh_generation)
    end
  end

  defp observe_fetch_execution(worker, opts) do
    store = Process.whereis(Store)
    assert :erlang.trace(store, true, [:receive, {:tracer, self()}]) == 1
    on_exit(fn -> if Process.alive?(store), do: :erlang.trace(store, false, [:receive]) end)
    state = :sys.get_state(Store)
    lease = Map.fetch!(state.execution_workers, worker)
    execution = Map.fetch!(state.executions, lease)
    assert Authority.execution_current?(lease, worker)
    assert execution.opts.generation === opts.generation
    assert execution.opts.scope == nil

    %{
      store: store,
      worker: worker,
      lease: lease,
      arena: execution.arena,
      run: {nil, opts.generation},
      monitor: Process.monitor(worker)
    }
  end

  defp assert_cancelled_fetch(task, retired) do
    assert {:ok, {:warn, :stale}} = Task.yield(task, 2_000)
    assert_retired_execution(retired)
  end

  defp assert_retired_execution(retired) do
    %{worker: worker, monitor: monitor, lease: lease, run: {scope, generation}} = retired
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 2_000
    refute Authority.execution_current?(lease)
    refute Authority.current?(scope, generation, nil)

    try do
      await_fetch_cleanup(retired)
    after
      :erlang.trace(retired.store, false, [:receive])
    end
  end

  defp await_fetch_cleanup(retired) do
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

      await_fetch_cleanup(retired)
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
        retries: 0,
        save_to: nil
      })

    Map.delete(opts, :scope)
  end
end
