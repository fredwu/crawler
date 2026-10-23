defmodule Crawler.Parser.CssParser.BoundedScannerTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis.Budget
  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Parser.CssParser.Value
  alias Crawler.Parser.CssParser.Variables

  test "bounded results retain canonical syntax and byte spans" do
    sources = [
      ~S|@import "theme.css" layer(foo) supports(display:grid) screen;.x{background:url(a.png)}|,
      ~S|.x{background:image-set("a.png" 1x,url(b.png) 2x);mask:image(ltr "c.png",#fff)}|,
      ~S|.x{--a:url(a.png);--b:var(--a,var(--c,url(c.png)));background:var(--b,url(b.png))}|,
      ~S|@property --a {syntax:"<url>";initial-value:url(a.png)}.x{background:var(--a)}|,
      "/* first */.x{background:url(\"a.png\" /* next */)}/* last */",
      ".x{background:url(a\\20 b.png);mask:url(\"unfinished",
      ".x{background:url(bad(ignored));mask:url(real.png)}",
      "@namespace url(namespace);.x{fill:url(#local);background:url(real.png)}"
    ]

    for source <- sources do
      assert {:ok, actual, _budget} = Scanner.analyze_result(source, [], budget())
      assert actual == Scanner.analyze(source)
    end

    source = "--x:url(x.png);background:var(--x,url(fallback.png));@import url(ignored.css);"

    assert {:ok, actual, _budget} =
             Scanner.analyze_result(source, [mode: :declarations], budget())

    assert actual == Scanner.analyze(source, mode: :declarations)
  end

  test "resources stop at the shared fact limit" do
    source = String.duplicate(".x{background:url(x)}", 128)

    assert {:error, {:limit, :lexical_facts}} =
             Scanner.analyze_result(source, [], budget(max_facts: 2))
  end

  test "comment collection stops at the shared fact limit" do
    source = String.duplicate("/**/", 128)

    assert {:error, {:limit, :lexical_facts}} =
             Scanner.analyze_result(source, [], budget(max_facts: 2))
  end

  test "custom declarations consume fact slots" do
    source = ".x{" <> String.duplicate("--x:x;", 128) <> "}"

    assert {:error, {:limit, :lexical_facts}} =
             Scanner.analyze_result(source, [], budget(max_facts: 2))
  end

  test "nested fallback records consume aggregate fact slots" do
    source =
      ".x{background:" <>
        String.duplicate("var(--x,", 128) <> "url(x)" <> String.duplicate(")", 128) <> "}"

    assert {:error, {:limit, :lexical_facts}} =
             Scanner.analyze_result(source, [], budget(max_facts: 4))
  end

  test "a large scalar with no resource output still consumes bytes" do
    assert {:ok, _, _} = Scanner.analyze_result("x", [], budget(max_total_bytes: 8_192))

    for source <- [String.duplicate("x", 8_192), "\"" <> String.duplicate("x", 8_192) <> "\""] do
      assert {:error, {:limit, :analysis_bytes}} =
               Scanner.analyze_result(source, [], budget(max_total_bytes: 8_192))
    end
  end

  test "function and rule stacks consume bytes without output facts" do
    assert {:ok, _, _} = Scanner.analyze_result("f(x){}", [], budget(max_total_bytes: 8_192))

    for source <- [String.duplicate("f(", 256), String.duplicate("{", 256)] do
      assert {:error, {:limit, :analysis_bytes}} =
               Scanner.analyze_result(source, [], budget(max_total_bytes: 8_192))
    end
  end

  test "sequential scanner calls share the residual fact quota" do
    assert {:ok, _first, next} = Scanner.analyze_result("/**/", [], budget(max_facts: 1))
    assert {:error, {:limit, :lexical_facts}} = Scanner.analyze_result("/**/", [], next)
  end

  test "quota failure precedes construction of the next URL token" do
    {result, calls} =
      traced({Value, :token, 4}, fn ->
        Scanner.analyze_result(String.duplicate("url(x)", 128), [], budget(max_facts: 2))
      end)

    assert result == {:error, {:limit, :lexical_facts}}
    assert calls == 2
  end

  test "quota failure precedes scanning the next comment body" do
    {result, calls} =
      traced({Value, :comment_length, 1}, fn ->
        Scanner.analyze_result(String.duplicate("/**/", 128), [], budget(max_facts: 2))
      end)

    assert result == {:error, {:limit, :lexical_facts}}
    assert calls == 2
  end

  test "quota failure precedes construction of the next nested fallback" do
    source =
      ".x{background:" <>
        String.duplicate("var(--x,", 128) <> "url(x)" <> String.duplicate(")", 128) <> "}"

    {result, calls} =
      traced({Scanner, :empty_fallback, 0}, fn ->
        Scanner.analyze_result(source, [], budget(max_facts: 5))
      end)

    assert result == {:error, {:limit, :lexical_facts}}
    assert calls == 4
  end

  test "all transient holds are released after a successful scan" do
    {:ok, held} = Budget.reserve(budget(), 777)

    source =
      ".x{--a:url(a) url(b);--b:var(--a,var(--c,url(c) url(d)));background:var(--b,url(e))}"

    assert {:ok, actual, next} = Scanner.analyze_result(source, [], held)
    assert actual == Scanner.analyze(source)
    assert next.scratch == 777
    assert next.peak > next.retained + next.scratch
    assert next.retained > 0
  end

  test "a successful peak fits exactly and rejects one byte less" do
    source = ".x{--a:url(a) url(b);background:var(--a,var(--b,url(c)))}"
    assert {:ok, expected, measured} = Scanner.analyze_result(source, [], budget())

    assert {:ok, ^expected, next} =
             Scanner.analyze_result(source, [], budget(max_total_bytes: measured.peak))

    assert next.peak == measured.peak

    assert {:error, {:limit, :analysis_bytes}} =
             Scanner.analyze_result(source, [], budget(max_total_bytes: measured.peak - 1))
  end

  test "sheet projection reuses existing facts through one charged tag reducer" do
    source =
      "@property --a{syntax: \"<url>\";initial-value:url(a)}.x{--b:var(--a);background:var(--b,url(b))}"

    analysis = Scanner.analyze(source)
    expected = Variables.sheet(analysis, :sheet, "https://example.test/", 3)

    assert {:ok, ^expected, next} =
             Variables.sheet_result(analysis, :sheet, "https://example.test/", 3, budget())

    assert next.scratch == 0

    assert next.counts.facts ==
             length(analysis.bindings) + length(analysis.registrations) + length(analysis.uses)

    assert {:error, {:limit, :lexical_facts}} =
             Variables.sheet_result(
               analysis,
               :sheet,
               "https://example.test/",
               3,
               budget(max_facts: 1)
             )

    assert {:error, {:limit, :analysis_bytes}} =
             Variables.sheet_result(
               analysis,
               :sheet,
               "https://example.test/",
               3,
               budget(max_total_bytes: 600)
             )
  end

  defp traced(mfa, fun) do
    owner = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :go -> send(owner, {:traced_result, self(), fun.()})
        end
      end)

    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(pid, true, [:call])
    send(pid, :go)

    try do
      collect_trace(pid, monitor, nil, 0)
    after
      :erlang.trace_pattern(mfa, false, [:local])
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end
  end

  defp collect_trace(pid, monitor, result, count) do
    receive do
      {:trace, ^pid, :call, _call} ->
        collect_trace(pid, monitor, result, count + 1)

      {:traced_result, ^pid, value} ->
        collect_trace(pid, monitor, value, count)

      {:DOWN, ^monitor, :process, ^pid, :normal} ->
        {result, count}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        flunk("traced scanner failed: #{inspect(reason)}")
    after
      5_000 -> flunk("traced scanner did not finish")
    end
  end

  defp budget(opts \\ []) do
    Budget.new(
      Map.new(
        Keyword.merge(
          [
            max_total_bytes: 16_777_216,
            max_facts: 100_000,
            max_regions: 1_000,
            max_occurrences: 100_000,
            max_edits: 100_000
          ],
          opts
        )
      )
    )
  end
end
