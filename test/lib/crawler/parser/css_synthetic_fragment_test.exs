defmodule Crawler.Parser.CssSyntheticFragmentTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis.Budget
  alias Crawler.Dispatcher
  alias Crawler.HTMLReferences
  alias Crawler.Limits
  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Parser.CssParser.Variables
  alias Crawler.Parser.CssSheets
  alias Crawler.Queue
  alias Crawler.ReqTestSite
  alias Crawler.Store
  alias Crawler.Store.Execution
  alias Crawler.Store.Retained
  alias Crawler.URL

  @root "https://css.test/root.css"
  @child "https://css.test/child.css"
  @root_source ~s|@import "child.css";.x{background:var(--a)}|

  test "cross-sheet quoted fragments never reach URL resolution or projected references" do
    for {raw, decoded} <- [
          {"#mask", "#mask"},
          {" \\23 mask ", " #mask "},
          {"\\000023 mask", "#mask"},
          {"\\9 #mask", "\t#mask"}
        ] do
      {sheets, analyses, outcome, budget} = graph(raw)

      assert [%{token: %{value: ^decoded} = token, token_sheet: :child, base_url: @root}] =
               outcome.pictures

      child = Enum.at(analyses, 1)
      assert child.source == ~s|:root{--a:image-set("#{raw}" 1x)}|
      assert [%{urls: [%{value: ^decoded}]}] = child.facts.bindings
      assert binary_part(child.source, token.start, token.length) == ~s|"#{raw}"|
      original = outcome
      {:ok, budget} = Budget.reserve(budget, 333)
      counts = budget.counts

      {result, calls} =
        traced(fn -> project(sheets, outcome, budget) end, [{URL, :resolve_result, 3}])

      assert {:ok, context, settled} = result
      assert context.css_tokens == %{root: [], child: []}
      assert context.css_references == %{root: []}
      assert calls == []
      assert settled.scratch == 333
      assert settled.counts == counts
      assert outcome == original
    end
  end

  test "same-sheet fragment spans stay inactive while raw scanner and graph facts remain" do
    source = ~s|.x{background:var(--missing,image-set(" #mask " 1x))}|
    {sheet, analysis, budget} = scan_sheet(source, :root, @root, 0, budget())
    assert {:ok, outcome, budget} = Variables.analyze_result([sheet], true, [], budget)
    assert [%{token: %{value: " #mask "} = token}] = outcome.pictures
    assert binary_part(source, token.start, token.length) == ~s|" #mask "|
    assert analysis.uses != []

    {result, calls} =
      traced(fn -> project([sheet], outcome, budget) end, [{URL, :resolve_result, 3}])

    assert {:ok, %{css_tokens: %{root: []}, css_references: %{root: []}}, _} = result
    assert calls == []
  end

  test "a real cross-sheet picture keeps its synthetic reference and original source location" do
    {sheets, _analyses, outcome, budget} =
      graph("picture.png", @root, "https://css.test/nested/child.css")

    assert {:ok, context, settled} = project(sheets, outcome, budget)
    assert context.css_tokens == %{root: [], child: []}
    assert context.css_references.root == outcome.pictures
    assert settled.scratch == 0

    assert [
             %{
               token_base: "https://css.test/nested/child.css",
               base_url: @root,
               token: %{value: "picture.png"}
             }
           ] = outcome.pictures
  end

  test "filter workspace is prepaid from the residual budget before trimming" do
    value = :binary.copy(" ", 2048) <> "#mask"
    {sheets, _analyses, outcome, budget} = graph(value)

    incoming = %{
      budget
      | limit:
          budget.retained + budget.scratch + 1024 + Budget.cost(:binary) + byte_size(value) - 1
    }

    {result, calls} =
      traced(
        fn -> project(sheets, outcome, incoming) end,
        [{HTMLReferences, :local_reference?, 1}, {URL, :resolve_result, 3}]
      )

    assert result == {:error, {:limit, :analysis_bytes}}
    assert calls == []
    assert incoming.counts == budget.counts
    assert incoming.retained == budget.retained
  end

  test "filtering a fragment preserves the order of remaining real pictures" do
    source = ~s|:root{--a:image-set("first.png" 1x," #mask " 2x,"last.png" 3x)}|

    {sheets, _analyses, outcome, budget} =
      graph_source(source, @root, "https://css.test/nested/child.css")

    assert Enum.map(outcome.pictures, & &1.token.value) == ["first.png", " #mask ", "last.png"]
    assert {:ok, context, _} = project(sheets, outcome, budget)
    assert Enum.map(context.css_references.root, & &1.token.value) == ["first.png", "last.png"]
  end

  @tag :services
  test "managed projection keeps fragment facts without discovery or admission" do
    opts = managed_options()

    {sheets, _analyses, _outcome, _budget} =
      graph(" \\23 mask ", opts.url, String.replace_suffix(opts.url, "root.css", "child.css"))

    group = %{
      style_group: opts.style_group,
      source_revision: :crypto.hash(:sha256, "managed-fragment"),
      sheets: sheets
    }

    {result, calls} =
      traced(
        fn -> CssSheets.resolve_groups(opts, [group]) end,
        [{URL, :resolve_result, 3}, {Dispatcher, :dispatch, 2}, {Store, :admit_job, 4}]
      )

    assert {:ok, %{css_references: %{root: []}, css_tokens: %{root: [], child: []}}} = result
    refute Enum.any?(calls, &fragment_resolution?/1)
    refute Enum.any?(calls, &match?({_, {Dispatcher, :dispatch, _}}, &1))
    refute Enum.any?(calls, &match?({_, {Store, :admit_job, _}}, &1))
    assert Store.pending_count(opts.scope) == 1

    cached =
      :sys.get_state(CssSheets).scopes[{opts.scope, opts.generation}].groups[opts.style_group]

    assert [%{token: %{value: " #mask "}}] = cached.outcome.pictures
    assert cached.urls == []
    spans = Scanner.analyze(~s|.x{background:url(" #ordinary ")}|).resources

    {urls, calls} =
      traced(
        fn -> CssSheets.take_urls(opts, @root_source, spans) end,
        [{URL, :resolve, 2}, {URL, :resolve_result, 3}]
      )

    assert urls == []
    refute Enum.any?(calls, &fragment_resolution?/1)

    cached =
      :sys.get_state(CssSheets).scopes[{opts.scope, opts.generation}].groups[opts.style_group]

    assert cached.emitted == MapSet.new()
  end

  @tag :services
  test "deferred settlement does not resolve dispatch or admit a fragment picture" do
    opts = managed_options()

    {result, calls} =
      traced(
        fn -> deferred(opts, " \\23 mask ") end,
        [
          {URL, :resolve_result, 3},
          {URL, :resolve, 2},
          {Dispatcher, :dispatch, 2},
          {Store, :admit_job, 4}
        ]
      )

    assert {:ok, _revision} = result
    refute Enum.any?(calls, &fragment_resolution?/1)
    refute Enum.any?(calls, &match?({_, {Dispatcher, :dispatch, _}}, &1))
    refute Enum.any?(calls, &match?({_, {Store, :admit_job, _}}, &1))
    assert Store.pending_count(opts.scope) == 1
    assert Process.alive?(Process.whereis(Store))
    assert Process.alive?(Process.whereis(CssSheets))
  end

  @tag :services
  test "deferred settlement dispatches and admits a real external picture" do
    opts = managed_options()

    {result, calls} =
      traced(
        fn -> deferred(opts, "picture.png") end,
        [{Dispatcher, :dispatch, 2}, {Store, :admit_job, 4}]
      )

    assert {:ok, _revision} = result
    expected = String.replace_suffix(opts.url, "root.css", "picture.png")

    assert Enum.any?(calls, fn
             {_, {Dispatcher, :dispatch, [{_tag, _raw, _attr, ^expected}, _opts]}} -> true
             {_, {Dispatcher, :dispatch, [{_attr, ^expected}, _opts]}} -> true
             _ -> false
           end)

    assert Enum.any?(calls, fn
             {_, {Store, :admit_job, [%{url: ^expected}, _prepared, :fetch, :reference]}} -> true
             _ -> false
           end)

    assert Store.pending_count(opts.scope) == 2
    OPQ.resume(opts.queue)
    assert_receive {:synthetic_external_requested, "/picture.png"}, 2_000
    Crawler.TestHelpers.await_idle(opts)
  end

  defp project(sheets, outcome, budget),
    do:
      CssSheets.project_result(
        outcome.pictures,
        %{sheets: sheets},
        %{emitted: MapSet.new()},
        :revision,
        budget
      )

  defp graph(raw, root \\ @root, child \\ @child) do
    source = ~s|:root{--a:image-set("#{raw}" 1x)}|
    graph_source(source, root, child)
  end

  defp graph_source(source, root, child) do
    {root_sheet, root_analysis, budget} = scan_sheet(@root_source, :root, root, 0, budget())
    {child_sheet, child_analysis, budget} = scan_sheet(source, :child, child, 1, budget)
    sheets = [root_sheet, child_sheet]
    {:ok, outcome, budget} = Variables.analyze_result(sheets, true, [], budget)

    analyses = [
      %{source: @root_source, facts: root_analysis},
      %{source: source, facts: child_analysis}
    ]

    {sheets, analyses, outcome, budget}
  end

  defp scan_sheet(source, id, base, order, budget) do
    {:ok, budget} = Budget.charge(budget, Budget.cost(:binary) + byte_size(source))
    {:ok, analysis, budget} = Scanner.analyze_result(source, [], budget)
    {:ok, sheet, budget} = Variables.sheet_result(analysis, id, base, order, budget)

    {Map.merge(sheet, %{
       region_id: id,
       imports: Enum.filter(analysis.resources, &(Map.get(&1, :kind) == :import))
     }), analysis, budget}
  end

  defp budget, do: Budget.new(Limits.analysis(Limits.validate!(%{})))

  defp fragment_resolution?({_pid, {URL, function, [raw | _]}})
       when function in [:resolve, :resolve_result],
       do: HTMLReferences.local_reference?(raw)

  defp fragment_resolution?(_call), do: false

  defp managed_options do
    context = ReqTestSite.open()
    ReqTestSite.stub(context.site, "GET", "/root.css", &Plug.Conn.resp(&1, 200, "seed"))
    observer = self()

    ReqTestSite.stub(context.site, "GET", "/picture.png", fn conn ->
      send(observer, {:synthetic_external_requested, conn.request_path})

      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.resp(200, "picture")
    end)

    scope = "synthetic-fragment-#{System.unique_integer([:positive])}"

    opts = %{
      scope: scope,
      url: context.url <> "/root.css",
      site: context.url,
      workers: 1,
      interval: 0,
      timeout: 5_000,
      attempt_timeout: 5_000,
      retries: 0,
      respect_robots: false,
      assets: ["css", "images"],
      max_body: 262_144,
      max_analysis_bytes: 2_000_000,
      max_css_work: 1_000,
      req_options: context.req_options,
      style_group: {:fragments, scope}
    }

    owner = start_supervised!({Queue, opts})
    queue = Queue.feeder(owner)
    OPQ.pause(queue)
    OPQ.info(queue)
    {:ok, opts} = Crawler.crawl(opts.url, Map.put(opts, :queue, queue))
    on_exit(fn -> Crawler.stop(opts) end)
    assert Store.pending_count(scope) == 1
    opts
  end

  defp deferred(opts, raw) do
    {sheets, _analyses, _outcome, _budget} =
      graph(raw, opts.url, String.replace_suffix(opts.url, "root.css", "child.css"))

    Execution.run(opts, fn owned ->
      snapshot = stage(owned, sheets)
      assert {:ok, :compute} = Store.schedule_css(owned, owned.style_group, snapshot.revision)
      CssSheets.run_settlement(owned, owned.style_group, snapshot.revision)
    end)
  end

  defp stage(opts, sheets) do
    source = :crypto.hash(:sha256, :erlang.term_to_binary(sheets))

    sheets =
      Enum.map(sheets, fn sheet ->
        id = {source, sheet.id, sheet.base}
        tag = fn items -> Enum.map(items, &Map.put(&1, :sheet_id, id)) end

        imports =
          Enum.flat_map(sheet.imports, fn token ->
            case URL.resolve(token.value, sheet.base) do
              {:ok, url} -> [url]
              :skip -> []
            end
          end)

        Map.put(
          %{
            sheet
            | id: id,
              bindings: tag.(sheet.bindings),
              registrations: tag.(sheet.registrations),
              uses: tag.(sheet.uses),
              imports: imports
          },
          :source_revision,
          source
        )
      end)

    prepared = %{
      style_group: opts.style_group,
      source_revision: source,
      sheets: sheets,
      failed: [],
      joined: [opts.url]
    }

    {:ok, bytes} = Retained.bytes(prepared, opts.max_analysis_bytes)
    bytes = bytes + 16_384
    cache = Process.whereis(CssSheets)

    {:ok, descriptor} =
      GenServer.call(cache, {:describe, opts, {opts.scope, opts.generation, opts.style_group}})

    capacities = %{
      snapshot: descriptor.bytes + 2 * bytes,
      output: descriptor.bytes + 2 * bytes + 128 * opts.max_css_work
    }

    {:ok, facts} = Store.reserve_resource(opts, :css_facts, bytes, cache)
    {:ok, snapshot} = Store.reserve_resource(opts, :css_snapshot, capacities.snapshot, cache)
    {:ok, output} = Store.reserve_resource(opts, :scratch, capacities.output, cache)
    :ok = Store.retain_resource(facts, Process.whereis(Store))
    opts = Map.put(opts, :css_obligation_receipt, facts)
    prepared = Map.merge(prepared, %{bytes: bytes, capacities: capacities})

    {:ok, ref} =
      Store.deliver_resource(
        facts,
        cache,
        {:register, opts, prepared, snapshot, output, :resolve}
      )

    receive do
      {:crawler_resource_delivery, ^snapshot, _lease, _origin, ^ref, {:snapshot, payload}} ->
        payload

      {^ref, error} ->
        flunk("snapshot rejected: #{inspect(error)}")
    after
      2_000 -> flunk("snapshot was not delivered")
    end
  end

  defp traced(fun, patterns) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :go -> send(parent, {:result, self(), fun.()})
        end
      end)

    for {module, _, _} = pattern <- patterns do
      Code.ensure_loaded!(module)
      :erlang.trace_pattern(pattern, true, [:local])
    end

    :erlang.trace(pid, true, [:call, :set_on_spawn, {:tracer, self()}])
    send(pid, :go)

    try do
      result =
        receive do
          {:result, ^pid, result} -> result
          {:DOWN, ^monitor, :process, ^pid, reason} -> flunk("probe exited: #{inspect(reason)}")
        after
          5_000 -> flunk("probe timeout")
        end

      receive do
        {:DOWN, ^monitor, :process, ^pid, :normal} -> :ok
      after
        5_000 -> flunk("probe did not exit")
      end

      barrier = :erlang.trace_delivered(:all)
      {result, collect_calls(barrier, [])}
    after
      for pattern <- patterns, do: :erlang.trace_pattern(pattern, false, [:local])
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end
  end

  defp collect_calls(barrier, calls) do
    receive do
      {:trace, pid, :call, call} -> collect_calls(barrier, [{pid, call} | calls])
      {:trace_delivered, :all, ^barrier} -> Enum.reverse(calls)
    after
      5_000 -> flunk("trace barrier timeout")
    end
  end
end
