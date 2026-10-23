defmodule Crawler.Parser.CssWriterFenceTest do
  use ExUnit.Case, async: false

  import Crawler.TestHelpers, only: [wait: 1]

  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Parser.CssParser.Variables
  alias Crawler.Parser.CssSheets
  alias Crawler.Store
  alias Crawler.Store.Authority
  alias Crawler.Store.Execution

  @body "a{background:var(--missing,url(frozen.png))}"
  @group {:writer_fence, :frozen}

  setup do
    {tmp, 0} = System.cmd("pwd", ["-P"], cd: System.tmp_dir!())

    root =
      Path.join(
        String.trim(tmp),
        "crawler-css-fence-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    scope = make_ref()

    on_exit(fn ->
      Store.dispose_scope(scope)

      wait(fn ->
        refute Enum.any?(Map.keys(:sys.get_state(CssSheets).scopes), fn {stored_scope, _} ->
                 stored_scope == scope
               end)
      end)

      wait(fn ->
        refute Enum.any?(:sys.get_state(Store).resources.receipts, fn {_, record} ->
                 elem(record.run, 0) == scope
               end)
      end)

      wait(fn ->
        refute Enum.any?(:sys.get_state(Store).exports, fn {{owner, _}, _} -> owner === scope end)
      end)

      File.rm_rf!(root)
    end)

    opts = %{
      url: "https://css.test/dir/root.css",
      scope: scope,
      style_group: @group,
      mode: :stylesheet,
      save_to: Path.join(root, "archive"),
      max_body: 262_144,
      max_analysis_bytes: 2_000_000,
      max_manifest_bytes: 262_144,
      max_css_work: 1_000,
      attempt_timeout: 5_000,
      respect_robots: false
    }

    %{opts: opts, scope: scope}
  end

  test "real close preserves generation and cached receipts but fences finalizer registration",
       c do
    opts = failed_target(c.opts)
    before = frozen(opts)
    receipts = retained(before)
    assert {:ok, closed} = Store.close_export(opts)
    assert Authority.current?(opts.scope, opts.generation, opts.queue)
    refute Authority.export_writable?(opts.scope, opts.generation, opts.queue)

    assert {:error, :fixture_finalizer_end} =
             Execution.run_finalizer(Map.merge(opts, closed), fn owned ->
               assert Authority.current?(
                        owned.scope,
                        owned.generation,
                        owned.queue,
                        owned.execution_lease
                      )

               refute Authority.export_writable?(
                        owned.scope,
                        owned.generation,
                        owned.queue,
                        owned.execution_lease
                      )

               assert owned.target_handle == closed.target_handle
               late = Map.merge(owned, %{style_group: @group, mode: :stylesheet})
               body = "a{background:var(--late,url(late.png))}"
               assert CssSheets.remember(late, body, Scanner.analyze(body)) == {:ok, []}
               assert frozen(opts) == before
               assert_cache_holders(receipts)
               {:error, :fixture_finalizer_end}
             end)

    send(CssSheets, :cleanup)
    assert frozen(opts) == before
    assert_cache_holders(receipts)
    Store.dispose_scope(c.scope)

    wait(fn ->
      refute Map.has_key?(:sys.get_state(CssSheets).scopes, {opts.scope, opts.generation})
      Enum.each(receipts, &assert(receipt(&1) == nil))
    end)

    refute Authority.current?(opts.scope, opts.generation, opts.queue)
    assert CssSheets.resolve_groups(opts, [bundle(opts, "stale.png")]) == {:error, :stale}
  end

  test "closed writer cannot register groups or settle failures through a current finalizer", c do
    opts = failed_target(c.opts)
    before = frozen(opts)
    assert {:ok, closed} = Store.close_export(opts)

    assert {:error, :fixture_finalizer_end} =
             Execution.run_finalizer(Map.merge(opts, closed), fn owned ->
               assert CssSheets.resolve_groups(owned, [bundle(owned, "late.png")]) ==
                        {:error, :stale}

               assert CssSheets.settle(owned) == []
               assert frozen(opts) == before
               {:error, :fixture_finalizer_end}
             end)
  end

  test "closed writer cannot emit cached URLs and settlement snapshot grants are released", c do
    opts = failed_target(c.opts)
    before = frozen(opts)
    assert before.group.urls == ["https://css.test/dir/frozen.png"]
    assert before.group.emitted == MapSet.new()
    assert {:ok, closed} = Store.close_export(opts)

    assert {:error, :fixture_finalizer_end} =
             Execution.run_finalizer(Map.merge(opts, closed), fn owned ->
               late = Map.put(owned, :style_group, @group)
               assert CssSheets.take_urls(late, @body, []) == []

               assert CssSheets.run_settlement(late, @group, before.group.revision) ==
                        {:error, :stale}

               assert GenServer.call(CssSheets, {:abort, late, key(opts), before.group.revision}) ==
                        {:error, :stale}

               assert frozen(opts) == before
               {:error, :fixture_finalizer_end}
             end)

    wait(fn -> assert css_receipts(opts) == MapSet.new(retained(before)) end)
  end

  test "late commit grants are rejected without changing the committed group", c do
    opts = failed_target(c.opts)
    before = frozen(opts)
    assert {:ok, closed} = Store.close_export(opts)

    assert {:error, :fixture_finalizer_end} =
             Execution.run_finalizer(Map.merge(opts, closed), fn owned ->
               cache = Process.whereis(CssSheets)

               assert {:ok, output} =
                        Store.reserve_resource(owned, :scratch, before.group.output_bytes, cache)

               result = %{
                 outcome: before.group.outcome,
                 urls: before.group.urls,
                 bytes: before.group.output_bytes,
                 emit?: true
               }

               assert {:ok, ref} =
                        Store.deliver_resource(
                          output,
                          cache,
                          {:commit, owned, key(opts), before.group.revision, result}
                        )

               assert_receive {^ref, {:error, :stale}}, 2_000
               assert frozen(opts) == before
               {:error, :fixture_finalizer_end}
             end)

    wait(fn -> assert css_receipts(opts) == MapSet.new(retained(before)) end)
  end

  test "before close real registration emission and settlement remain writable", c do
    opts = failed_target(c.opts)
    assert Authority.export_writable?(opts.scope, opts.generation, opts.queue)
    assert CssSheets.take_urls(opts, @body, []) == ["https://css.test/dir/frozen.png"]
    assert CssSheets.settle(opts) == []
    group = frozen(opts).group
    assert group.emitted == MapSet.new(group.urls)
    assert MapSet.member?(group.failed, opts.url)
    assert group.outcome.status == :ok
  end

  test "retiring one queue after the run deadline cannot restore CSS authority", c do
    site = Crawler.ReqTestSite.open()
    body = "completed page survives CSS cleanup"
    url = site.url <> "/completed"

    Crawler.ReqTestSite.expect_once(site.site, "GET", "/completed", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.resp(200, body)
    end)

    retiring_owner =
      start_supervised!(
        {Crawler.Queue, %{scope: c.scope, workers: 1, interval: 0, timeout: 5_000}}
      )

    retiring_queue = Crawler.Queue.feeder(retiring_owner)
    generation = Store.generation(c.scope)
    assert :ok = Store.note_enqueued(c.scope, generation, retiring_queue)
    assert :ok = Store.finish_work(c.scope, generation, false, retiring_queue)

    assert {:ok, opts} =
             Crawler.TestHelpers.start_crawl(
               url,
               Map.merge(c.opts, %{
                 generation: generation,
                 save_to: nil,
                 store: Store,
                 req_options: Crawler.ReqTestSite.req_options(site),
                 run_timeout: 2_000
               })
             )

    wait(fn ->
      assert Store.find_processed({url, c.scope})
      refute Crawler.running?(opts)
    end)

    assert {:ok, [%{value: "frozen.png"}]} =
             Execution.run(opts, fn owned ->
               CssSheets.remember(owned, @body, Scanner.analyze(@body))
             end)

    before = frozen(opts)
    receipts = retained(before)
    assert [_ | _] = receipts
    assert_cache_holders(receipts)
    assert %{body: ^body, opts: page_opts} = completed = Store.find_processed({url, c.scope})

    page_receipts =
      [page_opts[:page_resource], page_opts[:body_resource]]
      |> Enum.filter(&is_reference/1)
      |> Enum.uniq()

    assert [_ | _] = page_receipts
    state = :sys.get_state(Store)
    counts = Map.take(state.persistent_counts, page_receipts)
    assert map_size(counts) == length(page_receipts)
    assert Enum.all?(counts, fn {_receipt, count} -> count > 0 end)
    assert state.scopes[c.scope].outcome == :open

    assert MapSet.new(Map.keys(state.scopes[c.scope].work)) ==
             MapSet.new([retiring_queue, opts.queue])

    assert opts.generation === generation
    assert Authority.current?(c.scope, generation, retiring_queue)
    assert Authority.current?(c.scope, generation, opts.queue)

    :ok = :sys.suspend(CssSheets)

    try do
      wait(fn ->
        state = :sys.get_state(Store)
        assert state.scopes[c.scope].outcome == {:limited, {:deadline, :run}}
        assert Crawler.Store.State.generation(state, c.scope) === generation
        refute Authority.current?(c.scope, generation, nil)
      end)

      assert_cache_holders(receipts)
      assert :ok = Crawler.Queue.stop(retiring_owner)
      refute Process.alive?(retiring_queue)
      assert Store.queue_scopes(retiring_queue) == []
      assert Store.queue_scopes(opts.queue) == [c.scope]
      assert Process.alive?(opts.queue)
      assert Process.alive?(opts.queue_owner)
      assert Crawler.Store.State.generation(:sys.get_state(Store), c.scope) === generation
      refute Store.current?(c.scope, generation, opts.queue)
      refute Authority.current?(c.scope, generation, nil)
      refute Authority.current?(c.scope, generation, opts.queue)
      refute Authority.export_writable?(c.scope, generation, opts.queue)
      assert :ets.lookup(Authority, c.scope) == []
      assert :ets.lookup(Crawler.Store.Export.Writers, c.scope) == []
    after
      :ok = :sys.resume(CssSheets)
    end

    send(CssSheets, :cleanup)

    wait(fn ->
      refute Map.has_key?(:sys.get_state(CssSheets).scopes, {c.scope, generation})
      Enum.each(receipts, &assert(receipt(&1) == nil))
      assert Store.find_processed({url, c.scope}) === completed
      assert Store.find_processed({url, c.scope}).body === body
      state = :sys.get_state(Store)
      assert Map.take(state.persistent_counts, page_receipts) === counts

      for receipt <- page_receipts do
        assert MapSet.member?(state.persistent_resources, receipt)
        assert Map.has_key?(state.resources.receipts[receipt].holders, Process.whereis(Store))
      end
    end)

    assert Store.queue_scopes(opts.queue) == [c.scope]
    assert Store.queue_record(opts.queue) == %{owner: opts.queue_owner, scope: c.scope}
    assert Process.alive?(opts.queue)
    refute Authority.current?(c.scope, generation, opts.queue)
  end

  defp failed_target(opts) do
    parent = self()

    assert :ok =
             Execution.run(Map.put(opts, :save_to, nil), fn owned ->
               assert {:ok, [%{value: "frozen.png"}]} =
                        CssSheets.remember(owned, @body, Scanner.analyze(@body))

               send(parent, {:css_generation, owned.generation})
               :ok
             end)

    assert_receive {:css_generation, generation}, 5_000

    assert Execution.run_job(Map.put(opts, :generation, generation), fn owned ->
             send(parent, {:admitted, owned})
             {:error, :fixture_failure}
           end) == {:error, :fixture_failure}

    assert_receive {:admitted, owned}, 5_000

    wait(fn ->
      assert Crawler.Store.ExportRun.quiescent?(
               :sys.get_state(Store),
               {owned.scope, owned.generation}
             )
    end)

    Map.drop(owned, [:execution_lease, :crawler_deadline, :scheduler_claim])
  end

  defp bundle(opts, picture) do
    source = "a{background:var(--missing,url(#{picture}))}"
    sheet = Variables.sheet(Scanner.analyze(source), :root, opts.url, 0) |> Map.put(:imports, [])

    %{
      style_group: {:writer_fence, :late},
      source_revision: :crypto.hash(:sha256, source),
      sheets: [sheet]
    }
  end

  defp key(opts), do: {opts.scope, opts.generation, @group}

  defp frozen(opts) do
    state = :sys.get_state(CssSheets)
    run = {opts.scope, opts.generation}
    group = state.scopes[run].groups[@group]

    receipts =
      Map.keys(group.receipts) ++ Map.keys(group.emission_receipts) ++ [group.output_receipt]

    %{
      group: group,
      jobs: Map.take(state.jobs, [key(opts)]),
      scopes: state.scopes[run],
      retained: MapSet.intersection(state.retained, MapSet.new(receipts)),
      next: state.next
    }
  end

  defp retained(frozen),
    do:
      Map.keys(frozen.group.receipts) ++
        Map.keys(frozen.group.emission_receipts) ++ [frozen.group.output_receipt]

  defp receipt(receipt), do: :sys.get_state(Store).resources.receipts[receipt]

  defp assert_cache_holders(receipts) do
    cache = Process.whereis(CssSheets)
    Enum.each(receipts, fn receipt -> assert Map.has_key?(receipt(receipt).holders, cache) end)
  end

  defp css_receipts(opts) do
    :sys.get_state(Store).resources.receipts
    |> Enum.filter(fn {_receipt, record} ->
      record.run == {opts.scope, opts.generation} and
        record.kind in [:css_facts, :css_snapshot, :scratch]
    end)
    |> MapSet.new(fn {receipt, _record} -> receipt end)
  end
end
