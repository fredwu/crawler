defmodule Crawler.Parser.CssParser.BoundedGraphTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis.Budget
  alias Crawler.Limits
  alias Crawler.Parser.CssParser.DocumentStyles
  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Parser.CssParser.VariableGraph
  alias Crawler.Parser.CssParser.Variables
  alias Crawler.Parser.CssSheets

  @base "https://site.test/styles/a.css"

  test "tiny normal CSS needs no reservation based on the maximum work cap" do
    sheets = [sheet("a{background:var(--missing,url(a.png))}")]
    assert {:ok, outcome, budget} = Variables.analyze_result(sheets, true, [], budget(100_000))
    assert outcome.status == :ok
    assert [%{token: %{value: "a.png"}}] = outcome.pictures
    assert budget.peak < 100_000
    assert budget.scratch == 0
    assert budget.retained > 0
  end

  test "unfunded backing fails before graph indexing or picture creation" do
    source = :binary.copy("x", 8192)
    backing = binary_part(source, 0, 128)
    assert :binary.referenced_byte_size(backing) == 8192
    sheets = [%{sheet("a{background:var(--a)}") | base: backing}]

    {result, calls} =
      traced(
        fn -> Variables.analyze_result(sheets, true, [], budget(8192)) end,
        [{VariableGraph, :index_sheet, 2}, {VariableGraph, :add_picture, 4}]
      )

    assert result == {:error, {:limit, :analysis_bytes}}
    assert calls == []
  end

  test "graph allocation stops before the first index insertion when control cannot be funded" do
    {result, calls} =
      traced(
        fn ->
          Variables.analyze_result([sheet(":root{--a:url(a.png)}")], true, [], budget(4095))
        end,
        [{VariableGraph, :put_winner, 4}]
      )

    assert result == {:error, {:limit, :analysis_bytes}}
    assert calls == []
  end

  test "shared residual holds survive graph success and failure" do
    sheets = [sheet(":root{--a:url(a.png)}a{background:var(--a)}")]
    incoming = budget(200_000)
    {:ok, incoming} = Budget.charge(incoming, 1234, facts: 7)
    {:ok, incoming} = Budget.reserve(incoming, 777)
    assert {:ok, outcome, settled} = Variables.analyze_result(sheets, true, [], incoming)
    assert outcome.status == :ok
    assert settled.scratch == 777
    assert settled.retained > incoming.retained
    assert settled.counts == incoming.counts

    assert {:ok, _outcome, exact} =
             Variables.analyze_result(sheets, true, [], %{incoming | limit: settled.peak})

    assert exact.peak == settled.peak

    assert {:error, {:limit, :analysis_bytes}} =
             Variables.analyze_result(sheets, true, [], %{incoming | limit: settled.peak - 1})

    assert incoming.retained == 1234
    assert incoming.scratch == 777
  end

  test "memo and index memory fail explicitly even when the one-picture graph fits native caps" do
    sheets = [sheet(repeated(30))]
    assert %{status: :ok, pictures: [_]} = Variables.analyze(sheets)

    assert {:error, {:limit, :analysis_bytes}} =
             Variables.analyze_result(sheets, true, [], budget(30_000))

    assert {:ok, outcome, settled} = Variables.analyze_result(sheets, true, [], budget(2_000_000))
    assert outcome.stats.lookups == 31
    assert outcome.stats.cache_hits == 30
    assert settled.scratch == 0
    assert settled.peak > settled.retained
  end

  test "native work depth picture and revision outcomes are preserved with enough shared bytes" do
    for {sheets, opts, kind} <- [
          {[sheet(repeated(10))], [max_work: 1], :work},
          {[sheet(repeated(10))], [max_depth: 3], :depth},
          {[sheet(":root{--a:url(a.png),url(b.png)}a{background:var(--a)}")], [max_pictures: 1],
           :pictures}
        ] do
      assert {:ok, outcome, settled} =
               Variables.analyze_result(
                 sheets,
                 true,
                 Keyword.put(opts, :graph_revision, :pinned),
                 budget(2_000_000)
               )

      assert outcome.status == {:limited, kind}
      assert outcome.revision == :pinned
      assert outcome.pictures == []
      assert settled.scratch == 0
    end
  end

  test "a limit-outcome allocation failure remains typed instead of throwing from the catch branch" do
    sheets = [sheet("a{background:var(--missing)}")]
    {:ok, _, settled} = Variables.analyze_result(sheets, true, [max_work: 1], budget(200_000))

    for limit <- (settled.peak - 600)..settled.peak do
      result = Variables.analyze_result(sheets, true, [max_work: 1], budget(limit))
      assert match?({:ok, _, _}, result) or result == {:error, {:limit, :analysis_bytes}}
    end
  end

  test "DocumentStyles reserves before sorting and returns the full outcome once" do
    sheets = [
      sheet(":root{--a:url(a.png)}", :definitions, @base, 1),
      sheet("a{background:var(--a)}", :uses, @base, 2)
    ]

    assert {:ok, context, settled} =
             DocumentStyles.from_sheets_result(
               Enum.reverse(sheets),
               [graph_revision: :one],
               budget(300_000)
             )

    assert %{revision: :one, status: :ok, pictures: [_]} = DocumentStyles.snapshot(context)
    assert settled.scratch == 0

    {result, calls} =
      traced(fn -> DocumentStyles.from_sheets_result(sheets, [], budget(1)) end, [
        {Enum, :sort_by, 2}
      ])

    assert result == {:error, {:limit, :analysis_bytes}}
    assert calls == []

    assert %{status: {:limited, :work}} =
             DocumentStyles.snapshot(DocumentStyles.from_sheets(sheets, max_work: 1))
  end

  test "sheet projection and graph consume the same lexical ledger without resetting counters" do
    incoming = budget(300_000)

    assert {:ok, analysis, incoming} =
             Scanner.analyze_result(":root{--a:url(a.png)}a{background:var(--a)}", [], incoming)

    assert {:ok, sheet, incoming} = Variables.sheet_result(analysis, :local, @base, 0, incoming)
    counts = incoming.counts
    assert counts.facts > 0
    assert {:ok, context, settled} = DocumentStyles.from_sheets_result([sheet], [], incoming)
    assert settled.counts == counts
    assert settled.retained > incoming.retained

    assert {:ok, [_], projected} =
             Variables.picture_spans_result(
               DocumentStyles.snapshot(context).pictures,
               :local,
               settled
             )

    assert projected.counts == counts
    assert projected.scratch == 0
  end

  test "picture projection deduplicates spans and preserves inherited scratch" do
    picture = %{
      token_sheet: :local,
      token_base: @base,
      base_url: @base,
      base_sheet: :local,
      token: %{start: 0, length: 5, value: "a.png"}
    }

    {:ok, incoming} = Budget.reserve(budget(50_000), 333)

    assert {:ok, [token], settled} =
             Variables.picture_spans_result([picture, picture], :local, incoming)

    assert token == picture.token
    assert settled.scratch == 333
    assert settled.retained == Budget.cost(:list_cell)
  end

  test "cross-base picture projection uses the bounded canonical resolver and stops early" do
    picture = %{
      token_sheet: :local,
      token_base: "https://site.test/a.css",
      base_url: "https://site.test/b.css",
      base_sheet: :local,
      token: %{start: 0, length: 5, value: "a.png"}
    }

    {result, calls} =
      traced(
        fn -> Variables.picture_spans_result([picture, picture], :local, budget(4096)) end,
        [{Crawler.URL, :resolve_result, 3}]
      )

    assert result == {:error, {:limit, :analysis_bytes}}
    assert length(calls) == 1

    assert {:ok, [_], settled} =
             Variables.picture_spans_result([picture], :local, budget(300_000))

    assert settled.retained == Budget.cost(:list_cell)
    assert settled.scratch == 0
    different = %{picture | base_url: "https://other.test/b.css"}
    assert {:ok, [], _} = Variables.picture_spans_result([different], :local, budget(300_000))
  end

  test "CssSheets pure computation adopts the snapshot and resolves each raw/base once" do
    sheets = [sheet(":root{--a:url(a.png)}a{background:var(--a),var(--a)}")]
    snapshot = snapshot(sheets)
    opts = Limits.validate!(%{})

    {result, calls} =
      traced(
        fn -> CssSheets.compute_result(snapshot, opts, budget(1_000_000)) end,
        [{Crawler.URL, :resolve_result, 3}, {VariableGraph, :run_result, 4}]
      )

    assert {:ok, computed, settled} = result
    assert computed.outcome.status == :ok
    assert computed.context.css_revision == :revision
    assert computed.urls == ["https://site.test/styles/a.png"]
    assert length(Enum.filter(calls, &match?({Crawler.URL, _, _}, &1))) == 1
    assert length(Enum.filter(calls, &match?({VariableGraph, _, _}, &1))) == 1
    assert settled.scratch == 0

    assert {:error, {:limit, :analysis_bytes}} =
             CssSheets.compute_result(snapshot, opts, budget(10_000))
  end

  test "snapshot funding fails before any whole receipt or sheet list is allocated" do
    snapshot = snapshot([sheet("a{background:var(--missing,url(a.png))}")])
    snapshot = put_in(snapshot, [:group, :receipts], Map.new(1..100, &{&1, 100}))
    opts = Limits.validate!(%{})

    {result, calls} =
      traced(
        fn -> CssSheets.compute_result(snapshot, opts, budget(10_000)) end,
        [{Map, :values, 1}, {VariableGraph, :run_result, 4}]
      )

    assert result == {:error, {:limit, :analysis_bytes}}
    assert calls == []
  end

  test "CssSheets pending settlement changes fallbacks without losing native limit errors" do
    sheets = [sheet("a{background:var(--missing,url(fallback.png))}")]
    opts = Limits.validate!(%{})
    pending = put_in(snapshot(sheets), [:group, :pending], MapSet.new([:import]))
    assert {:ok, computed, _} = CssSheets.compute_result(pending, opts, budget(1_000_000))
    assert computed.outcome.pictures == []
    assert computed.urls == []

    assert {:ok, computed, _} =
             CssSheets.compute_result(snapshot(sheets), opts, budget(1_000_000))

    assert computed.urls == ["https://site.test/styles/fallback.png"]

    assert {:error, {:limit, {:css_graph, :work}}} =
             CssSheets.compute_result(
               snapshot(sheets),
               %{opts | max_css_work: 1},
               budget(1_000_000)
             )
  end

  test "projection byte failure stops the remaining picture URLs without partial success" do
    pictures =
      Enum.map(1..16, fn index ->
        %{
          token_sheet: :local,
          token_base: @base,
          base_url: @base,
          base_sheet: :local,
          token: %{start: index, length: 5, value: "#{index}.png"}
        }
      end)

    incoming = budget(10_000)

    {result, calls} =
      traced(
        fn ->
          CssSheets.project_result(
            pictures,
            %{sheets: []},
            %{emitted: MapSet.new()},
            :failed,
            incoming
          )
        end,
        [{Crawler.URL, :resolve_result, 3}]
      )

    assert result == {:error, {:limit, :analysis_bytes}}
    assert length(calls) == 1
    assert incoming.retained == 0
    assert incoming.scratch == 0
  end

  test "pure projection preserves already-emitted filtering and result order" do
    sheets = [sheet(":root{--a:url(a.png),url(b.png)}a{background:var(--a)}")]

    {:ok, computed, _} =
      CssSheets.compute_result(snapshot(sheets), Limits.validate!(%{}), budget(1_000_000))

    pictures = computed.outcome.pictures
    group = %{emitted: MapSet.new(["https://site.test/styles/a.png"])}

    assert {:ok, context, settled} =
             CssSheets.project_result(pictures, %{sheets: []}, group, :cached, budget(1_000_000))

    assert Enum.map(context.css_references.settlement, & &1.token.value) == ["b.png"]
    assert settled.scratch == 0
  end

  defp budget(bytes),
    do:
      Budget.new(%{
        max_total_bytes: bytes,
        max_facts: 10_000,
        max_regions: 100,
        max_occurrences: 10_000,
        max_edits: 10_000
      })

  defp sheet(css, id \\ :local, base \\ @base, order \\ 0),
    do: Variables.sheet(Scanner.analyze(css), id, base, order)

  defp repeated(depth) do
    ":root{--v0:url(a.png);" <>
      Enum.map_join(1..depth, fn n -> "--v#{n}:var(--v#{n - 1}),var(--v#{n - 1});" end) <>
      "}a{background:var(--v#{depth})}"
  end

  defp snapshot(sheets) do
    sheets = Enum.map(sheets, &Map.put(&1, :region_id, &1.id))

    %{
      group: %{
        sheets: Map.new(sheets, &{&1.id, &1}),
        pending: MapSet.new(),
        emitted: MapSet.new(),
        receipts: %{},
        emission_receipts: %{},
        output_bytes: 0,
        outcome: nil,
        urls: []
      },
      request: %{sheets: sheets},
      revision: :revision
    }
  end

  defp traced(fun, patterns) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :go -> send(parent, {:result, self(), fun.()})
        end
      end)

    for pattern <- patterns, do: :erlang.trace_pattern(pattern, true, [:local])
    :erlang.trace(pid, true, [:call, {:tracer, self()}])
    send(pid, :go)

    try do
      result =
        receive do
          {:result, ^pid, result} -> result
        after
          5_000 -> flunk("probe timeout")
        end

      receive do
        {:DOWN, ^monitor, :process, ^pid, :normal} -> :ok
      after
        5_000 -> flunk("probe did not exit")
      end

      {result, collect_calls(pid, [])}
    after
      for pattern <- patterns, do: :erlang.trace_pattern(pattern, false, [:local])
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end
  end

  defp collect_calls(pid, calls) do
    receive do
      {:trace, ^pid, :call, call} -> collect_calls(pid, [call | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end
end
