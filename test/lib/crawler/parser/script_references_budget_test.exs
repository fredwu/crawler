defmodule Crawler.Parser.ScriptReferencesBudgetTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis.Budget
  alias Crawler.ImportMap
  alias Crawler.Parser.JsBudgetTraceTest
  alias Crawler.Parser.JsParser.Scanner
  alias Crawler.Parser.ScriptReferences
  alias Crawler.Parser.SourceMap
  alias Crawler.URL

  @opts %{
    url: "https://example.test/page/index.html",
    referrer_url: "https://example.test/scripts/main.js",
    document_base: "https://example.test/assets/",
    document_url: "https://example.test/page/index.html",
    javascript_goal: :module
  }

  defp budget(opts \\ []) do
    Budget.new(
      Map.merge(
        %{
          max_total_bytes: 32_000_000,
          max_facts: 10_000,
          max_regions: 100,
          max_occurrences: 100,
          max_edits: 100
        },
        Map.new(opts)
      )
    )
  end

  defp collect(ref, refs, budget) do
    with {:ok, budget} <-
           Budget.charge(budget, Budget.cost(:occurrence),
             occurrences: if(is_binary(ref.url), do: 1, else: 0)
           ) do
      {:ok, [ref | refs], budget}
    end
  end

  test "bounded references preserve source order and worker and module contexts" do
    source = ~S|new Worker("./worker.js",{type:"module"}); import "./one.js"; import("./two.js");|
    scan = Scanner.scan(source)
    assert {:ok, refs, b} = ScriptReferences.reduce(source, @opts, scan, budget(), [], &collect/3)
    refs = Enum.reverse(refs)
    assert refs == ScriptReferences.list(source, @opts, scan)

    assert Enum.map(refs, & &1.url) == [
             "https://example.test/assets/worker.js",
             "https://example.test/scripts/one.js",
             "https://example.test/scripts/two.js"
           ]

    assert hd(refs).worker_base == hd(refs).url
    assert hd(refs).goal == :module
    assert b.counts.occurrences == 3
    assert b.scratch == 0
  end

  test "occurrence cap is checked before the next URL resolution" do
    source = ~S|import "./one.js"; import "./two.js"; import "./three.js";|
    scan = Scanner.scan(source)

    {result, calls} =
      JsBudgetTraceTest.calls_to(URL, :resolve_result, 3, fn ->
        ScriptReferences.reduce(source, @opts, scan, budget(max_occurrences: 1), [], &collect/3)
      end)

    assert result == {:error, {:limit, :occurrences}}
    assert calls == 1
  end

  test "an already exhausted occurrence allowance performs no URL resolution" do
    source = ~S|new Worker("./worker.js");|
    scan = Scanner.scan(source)
    {:ok, b} = Budget.count(budget(max_occurrences: 1), :occurrences)

    {result, calls} =
      JsBudgetTraceTest.calls_to(URL, :resolve_result, 3, fn ->
        ScriptReferences.reduce(source, @opts, scan, b, [], &collect/3)
      end)

    assert result == {:error, {:limit, :occurrences}}
    assert calls == 0
  end

  test "a source map annotation respects an already exhausted occurrence allowance" do
    source = "//# sourceMappingURL=app.js.map"
    scan = Scanner.scan(source)
    {:ok, b} = Budget.count(budget(max_occurrences: 1), :occurrences)

    {result, calls} =
      JsBudgetTraceTest.calls_to(URL, :resolve_result, 3, fn ->
        ScriptReferences.reduce(source, @opts, scan, b, [], &collect/3)
      end)

    assert result == {:error, {:limit, :occurrences}}
    assert calls == 0
  end

  test "callback errors retain their reason and stop later resolution" do
    source = ~S|import "./one.js"; import "./two.js";|
    scan = Scanner.scan(source)

    {result, calls} =
      JsBudgetTraceTest.calls_to(URL, :resolve_result, 3, fn ->
        ScriptReferences.reduce(source, @opts, scan, budget(), [], fn _ref, _acc, _budget ->
          {:error, {:limit, :edits}}
        end)
      end)

    assert result == {:error, {:limit, :edits}}
    assert calls == 1
  end

  test "blocked and unmapped modules do not commit an occurrence slot" do
    source = ~S|import "blocked"; import "missing"; import "./one.js";|
    map = ImportMap.parse(~S|{"imports":{"blocked":null}}|, @opts.document_base)
    opts = Map.put(@opts, :import_map, map)
    scan = Scanner.scan(source)

    assert {:ok, [ref], b} =
             ScriptReferences.reduce(
               source,
               opts,
               scan,
               budget(max_occurrences: 1),
               [],
               &collect/3
             )

    assert ref.url == "https://example.test/scripts/one.js"
    assert b.counts.occurrences == 1
  end

  test "classic scripts ignore static imports and retain dynamic imports" do
    source = ~S|import "./static.js"; import("./dynamic.js");|
    opts = Map.put(@opts, :javascript_goal, :script)
    scan = Scanner.scan(source, :script)
    assert {:ok, [ref], _} = ScriptReferences.reduce(source, opts, scan, budget(), [], &collect/3)
    assert ref.spec == "./dynamic.js"
    assert ref.goal == :module
  end

  test "supplied scans are reused by semantic reduction" do
    source = ~S|import "./one.js"; new Worker("./worker.js");|
    scan = Scanner.scan(source)

    {{:ok, refs, _}, calls} =
      JsBudgetTraceTest.calls_to(Scanner, :scan, 2, fn ->
        ScriptReferences.reduce(source, @opts, scan, budget(), [], &collect/3)
      end)

    assert length(refs) == 2
    assert calls == 0
  end

  test "embedded map sources stop before resolving the first overflow URL" do
    data = Base.encode64(~S|{"version":3,"sources":["one.ts","two.ts","three.ts"],"mappings":""}|)
    source = "//# sourceMappingURL=data:application/json;base64," <> data
    scan = Scanner.scan(source)

    {result, calls} =
      JsBudgetTraceTest.calls_to(URL, :resolve_result, 3, fn ->
        ScriptReferences.reduce(source, @opts, scan, budget(max_occurrences: 1), [], &collect/3)
      end)

    assert result == {:error, {:limit, :occurrences}}
    assert calls == 1
  end

  test "managed map regions prevent a duplicate JSON read" do
    data = Base.encode64(~S|{"version":3,"sources":["one.ts"],"mappings":""}|)
    url = "data:application/json;base64," <> data
    source = "//# sourceMappingURL=" <> url
    scan = Scanner.scan(source)
    opts = Map.put(@opts, :source_map_regions, %{url => :already_scanned})

    {{:ok, [note], b}, calls} =
      JsBudgetTraceTest.calls_to(
        Crawler.ImportMap.JSON,
        :decode_located_result,
        2,
        fn ->
          ScriptReferences.reduce(source, opts, scan, budget(), [], &collect/3)
        end
      )

    assert note.url == nil
    assert b.counts.occurrences == 0
    assert calls == 0
  end

  test "reference reduction preserves an outer reservation" do
    source = ~S|import "./one.js";|
    scan = Scanner.scan(source)
    {:ok, b} = Budget.reserve(budget(), 700)
    assert {:ok, [_], b} = ScriptReferences.reduce(source, @opts, scan, b, [], &collect/3)
    assert b.scratch == 700
  end

  test "an explicitly cached nil note does not call source map resolution" do
    source = "//# sourceMappingURL=app.js.map"
    scan = Scanner.scan(source)
    opts = Map.put(@opts, :source_map_note, nil)

    {{:ok, [], _}, calls} =
      JsBudgetTraceTest.calls_to(SourceMap, :javascript_result, 4, fn ->
        ScriptReferences.reduce(source, opts, scan, budget(), [], &collect/3)
      end)

    assert calls == 0
  end

  test "an explicitly cached real note is reused without another mapping step" do
    source = "//# sourceMappingURL=app.js.map"
    scan = Scanner.scan(source)
    {:ok, note, b} = SourceMap.javascript_result(source, @opts, scan, budget())
    opts = Map.put(@opts, :source_map_note, note)

    {{:ok, [ref], _}, calls} =
      JsBudgetTraceTest.calls_to(SourceMap, :javascript_result, 4, fn ->
        ScriptReferences.reduce(source, opts, scan, b, [], &collect/3)
      end)

    assert ref.map_note == note
    assert ref.url == "https://example.test/scripts/app.js.map"
    assert calls == 0
  end

  test "a missing cached note retains the canonical mapping step" do
    source = "//# sourceMappingURL=app.js.map"
    scan = Scanner.scan(source)

    {{:ok, [_], _}, calls} =
      JsBudgetTraceTest.calls_to(SourceMap, :javascript_result, 4, fn ->
        ScriptReferences.reduce(source, @opts, scan, budget(), [], &collect/3)
      end)

    assert calls == 1
  end

  test "precomputed inline source base resolves once across mapping and reduction" do
    data = Base.encode64(~S|{"version":3,"sources":[],"mappings":""}|)

    source =
      "//# sourceURL=../inline/main.js\n//# sourceMappingURL=data:application/json;base64," <>
        data

    opts = @opts |> Map.delete(:referrer_url) |> Map.put(:inline_source, true)
    {:ok, scan, b} = Scanner.scan_result(source, :module, budget())
    {:ok, notes, b} = SourceMap.lexical_notes_result(source, scan, b)
    opts = Map.put(opts, :source_map_notes, notes)

    {{:ok, [ref], _}, calls} =
      JsBudgetTraceTest.calls_to(URL, :resolve_result, 3, fn ->
        with {:ok, note, b} <- SourceMap.javascript_result(source, opts, scan, b) do
          ScriptReferences.reduce(
            source,
            Map.put(opts, :source_map_note, note),
            scan,
            b,
            [],
            &collect/3
          )
        end
      end)

    assert ref.map_note.base == "https://example.test/inline/main.js"
    assert calls == 1
  end

  test "source map notes keep byte order and append embedded source refs" do
    data = Base.encode64(~S|{"version":3,"sources":["one.ts","two.ts"],"mappings":""}|)
    source = ~s|import "./one.js";\n//# sourceMappingURL=data:application/json;base64,#{data}|
    scan = Scanner.scan(source)
    assert {:ok, refs, b} = ScriptReferences.reduce(source, @opts, scan, budget(), [], &collect/3)
    refs = Enum.reverse(refs)
    assert refs == ScriptReferences.list(source, @opts, scan)

    assert Enum.map(refs, & &1.url) == [
             "https://example.test/scripts/one.js",
             nil,
             "https://example.test/scripts/one.ts",
             "https://example.test/scripts/two.ts"
           ]

    assert b.counts.occurrences == 3
  end
end
