defmodule Crawler.Parser.JsBudgetTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis.Budget
  alias Crawler.Parser.JsParser
  alias Crawler.Parser.JsParser.Calls
  alias Crawler.Parser.JsParser.Scanner

  defp budget(opts \\ []) do
    Budget.new(
      Map.merge(
        %{
          max_total_bytes: 16_777_216,
          max_facts: 10_000,
          max_regions: 100,
          max_occurrences: 100,
          max_edits: 100
        },
        Map.new(opts)
      )
    )
  end

  test "strings and comments consume one aggregate fact allowance" do
    assert {:error, {:limit, :lexical_facts}} =
             Scanner.scan_result(~S|"one";/*two*/"three"|, :module, budget(max_facts: 2))

    assert {:ok, {_mask, [_], [_]}, b} =
             Scanner.scan_result(~S|"one";/*two*/|, :module, budget(max_facts: 2))

    assert b.counts.facts == 2
    assert b.scratch == 0
    assert {:error, {:limit, :lexical_facts}} = Scanner.scan_result(~S|"three"|, :module, b)
  end

  test "mask chunks and overlapping flatten buffers are bounded with no facts" do
    source = String.duplicate(" ", 4096)

    assert {:error, {:limit, :analysis_bytes}} =
             Scanner.scan_result(source, :module, budget(max_total_bytes: 4096))

    assert {:ok, {^source, [], []}, b} = Scanner.scan_result(source, :module, budget())
    assert b.retained == 4096 + Budget.cost(:binary) + Budget.cost(:token)
    assert b.peak > b.retained
    assert b.scratch == 0
  end

  test "grammar growth is charged when no literal facts are produced" do
    source = String.duplicate("(", 64)

    assert {:ok, _, _} =
             Scanner.scan_result(
               String.duplicate(" ", 64),
               :module,
               budget(max_total_bytes: 20_000)
             )

    assert {:error, {:limit, :analysis_bytes}} =
             Scanner.scan_result(source, :module, budget(max_total_bytes: 20_000))
  end

  test "specifier projection reuses the supplied scan and preserves order and escapes" do
    source = ~S|import "./a\x2ejs"; export {x} from "./b.js"; import("./c.js");|
    scan = Scanner.scan(source)
    assert {:ok, spans, b} = JsParser.specifier_spans_result(source, :module, scan, budget())
    assert spans == JsParser.specifier_spans(source, :module, scan)
    assert Enum.map(spans, &elem(&1, 3)) == ["./b.js", "./a.js", "./c.js"]
    assert b.counts.facts == 3
    assert b.scratch == 0

    assert {:error, {:limit, :lexical_facts}} =
             JsParser.specifier_spans_result(source, :module, scan, budget(max_facts: 1))
  end

  test "Calls iterates matches and importScripts arguments with a shared quota" do
    source = ~S|importScripts("one.js", "two.js", "three.js");|
    scan = Scanner.scan(source, :script)
    assert {:ok, calls, b} = Calls.spans_result(source, :script, scan, budget())
    assert calls == Calls.spans(source, :script, scan)
    assert Enum.map(calls, &elem(&1, 3)) == ["one.js", "two.js", "three.js"]
    assert b.scratch == 0

    assert {:error, {:limit, :lexical_facts}} =
             Calls.spans_result(source, :script, scan, budget(max_facts: 2))
  end

  test "nested scanner and projection reservations preserve their caller's live scratch" do
    {:ok, initial} = Budget.reserve(budget(), 700)
    source = ~S|import("./one.js"); new Worker("./worker.js");|
    assert {:ok, scan, b} = Scanner.scan_result(source, :module, initial)
    assert b.scratch == 700
    assert {:ok, _, b} = JsParser.specifier_spans_result(source, :module, scan, b)
    assert b.scratch == 700
    assert {:ok, _, b} = Calls.spans_result(source, :module, scan, b)
    assert b.scratch == 700
    assert b.peak <= b.limit
  end

  test "pattern iteration keeps initial and later statements in the same matching order" do
    source = ~S|import "./a.js"; import "./b.js"; import("./c.js"); import("./d.js");|
    scan = Scanner.scan(source)
    assert {:ok, spans, _} = JsParser.specifier_spans_result(source, :module, scan, budget())
    assert Enum.map(spans, &elem(&1, 3)) == ["./a.js", "./b.js", "./c.js", "./d.js"]
  end

  test "supplied scan identity remains authoritative" do
    source = ~S|import("./real.js"); new Worker("./worker.js");|
    empty_scan = {String.duplicate(" ", byte_size(source)), [], []}
    assert {:ok, [], _} = JsParser.specifier_spans_result(source, :module, empty_scan, budget())
    assert {:ok, [], _} = Calls.spans_result(source, :module, empty_scan, budget())
  end
end

defmodule Crawler.Parser.JsBudgetTraceTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis.Budget
  alias Crawler.Parser.JsParser
  alias Crawler.Parser.JsParser.Calls
  alias Crawler.Parser.JsParser.Scanner
  alias Crawler.Parser.JsParser.StringLiteral

  defp budget(facts) do
    Budget.new(%{
      max_total_bytes: 16_777_216,
      max_facts: facts,
      max_regions: 100,
      max_occurrences: 100,
      max_edits: 100
    })
  end

  def calls_to(module, function, arity, fun) do
    owner = self()
    tracer = spawn(fn -> collect(owner, 0) end)
    :erlang.trace_pattern({module, function, arity}, true, [:local])
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      result = fun.()
      :erlang.trace(self(), false, [:call])
      delivered = :erlang.trace_delivered(self())
      assert_receive {:trace_delivered, _pid, ^delivered}
      send(tracer, :report)
      assert_receive {:calls, count}
      {result, count}
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({module, function, arity}, false, [:local])
      Process.exit(tracer, :kill)
    end
  end

  defp collect(owner, count) do
    receive do
      {:trace, _pid, :call, _call} -> collect(owner, count + 1)
      :report -> send(owner, {:calls, count})
    end
  end

  test "scanner stops before inserting the first comment beyond the cap" do
    {result, count} =
      calls_to(Scanner, :add_comment, 2, fn ->
        Scanner.scan_result(String.duplicate("/**/", 128), :module, budget(2))
      end)

    assert result == {:error, {:limit, :lexical_facts}}
    assert count == 2
  end

  test "specifier quota stops before decoding the next literal" do
    source = ~S|import "./one.js"; import "./two.js"; import "./three.js";|
    scan = Scanner.scan(source)

    {result, count} =
      calls_to(StringLiteral, :decode, 1, fn ->
        JsParser.specifier_spans_result(source, :module, scan, budget(1))
      end)

    assert result == {:error, {:limit, :lexical_facts}}
    assert count == 1
  end

  test "importScripts quota stops inside a single argument list" do
    source = ~S|importScripts("one.js", "two.js", "three.js");|
    scan = Scanner.scan(source, :script)

    {result, count} =
      calls_to(StringLiteral, :decode, 1, fn ->
        Calls.spans_result(source, :script, scan, budget(2))
      end)

    assert result == {:error, {:limit, :lexical_facts}}
    assert count == 1
  end
end
