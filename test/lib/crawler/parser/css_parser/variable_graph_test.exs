defmodule Crawler.Parser.CssParser.VariableGraphTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.CssParser
  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Parser.CssParser.Variables

  test "a 416-byte repeated-alias graph produces one identity within a finite work budget" do
    css = repeated_aliases(14)
    assert byte_size(css) == 416

    result = Variables.analyze([sheet(css)], true, max_work: 2_000)

    assert result.status == :ok
    assert values(result) == ["picture.png"]
    assert result.stats.lookups == 15
    assert result.stats.cache_entries == 15
    assert result.stats.cache_hits == 14
    assert result.stats.work < 1_000
  end

  test "deeper repeated aliases reuse completed subgraphs" do
    for depth <- [4, 8, 14, 30, 60] do
      result = Variables.analyze([sheet(repeated_aliases(depth))])

      assert result.status == :ok
      assert length(result.pictures) == 1
      assert result.stats.lookups == depth + 1
      assert result.stats.cache_hits == depth
      assert result.stats.work < 8 * (depth + 1) * (depth + 1)
    end
  end

  test "a shared DAG node is reused across distinct paths and repeated uses" do
    graph =
      sheet("""
      :root{--top:var(--left),var(--right);--left:var(--shared);--right:var(--shared);--shared:url(shared.png)}
      a{background:var(--top),var(--top)}
      """)

    result = Variables.analyze([graph])
    assert result.status == :ok
    assert values(result) == ["shared.png"]
    assert result.stats.lookups == 4
    assert result.stats.cache_hits == 2

    fallbacks =
      sheet("""
      :root{--a:var(--missing,url(a.png)),var(--missing,url(b.png))}a{background:var(--a)}
      """)

    assert values(Variables.analyze([fallbacks])) == ["a.png", "b.png"]
  end

  test "unrelated binding growth adds index work without adding graph lookups" do
    original = sheet(repeated_aliases(14))
    result = Variables.analyze([original])

    for count <- [100, 1_000, 10_000] do
      bindings =
        Enum.map(1..count, fn index ->
          %{
            name: "--unrelated#{index}",
            urls: [],
            aliases: [],
            rule_id: 0,
            sheet_id: original.id,
            base: original.base
          }
        end)

      expanded = Variables.analyze([%{original | bindings: original.bindings ++ bindings}])

      assert expanded.status == :ok
      assert expanded.pictures == result.pictures
      assert expanded.stats.lookups == result.stats.lookups
      assert expanded.stats.cache_hits == result.stats.cache_hits
      assert expanded.stats.indexed == result.stats.indexed + count
      assert expanded.stats.work == result.stats.work + count
    end
  end

  test "rule and sheet contexts retain separate winning bindings and base URLs" do
    definitions =
      sheet(":root{--icon:url(icon.png)}", :definitions, "https://site.test/tokens/a.css")

    uses =
      sheet(
        "a{background:var(--icon)}b{--icon:url(local.png);background:var(--icon)}",
        :uses,
        "https://site.test/styles/b.css",
        1
      )

    result = Variables.analyze([definitions, uses])
    assert result.status == :ok
    assert values(result) == ["local.png"]

    other = sheet("a{background:var(--icon)}", :other, "https://site.test/other/c.css", 2)
    result = Variables.analyze([definitions, uses, other])
    assert values(result) == ["local.png", "local.png"]
    assert Enum.map(result.pictures, & &1.base_url) == [uses.base, other.base]

    rules =
      sheet(
        "a{--icon:url(a.png);background:var(--icon)}b{--icon:url(b.png);background:var(--icon)}"
      )

    assert values(Variables.analyze([rules])) == ["a.png", "b.png"]
  end

  test "registrations, nested fallbacks and fallback mode keep their original contexts" do
    definitions =
      sheet(
        """
        @property --registered { syntax: "<url>"; initial-value: url(initial.png); }
        :root{--plain:url(plain.png);--registered:url(registered.png)}
        """,
        :definitions,
        "https://site.test/tokens/a.css"
      )

    uses =
      sheet(
        """
        a{background:var(--plain),var(--registered),var(--missing,var(--also,url(fallback.png)))}
        """,
        :uses,
        "https://site.test/styles/b.css",
        1
      )

    pending = Variables.analyze([definitions, uses], false, graph_revision: :pending)
    assert values(pending) == ["plain.png", "registered.png"]
    assert Enum.map(pending.pictures, & &1.base_url) == [uses.base, definitions.base]
    assert pending.revision == :pending

    settled = Variables.analyze([definitions, uses], true, graph_revision: :settled)
    assert values(settled) == ["plain.png", "registered.png", "fallback.png"]
    assert settled.revision == :settled

    initial =
      sheet("""
      @property --icon { syntax: "<url>"; initial-value: url(initial.png); }
      :root{--alias:var(--icon,url(hidden.png))}a{background:var(--alias)}
      """)

    assert values(Variables.analyze([initial])) == ["initial.png"]
  end

  test "cycles terminate without activating fallbacks of set variables" do
    cyclic =
      sheet("""
      :root{--a:var(--b,url(hidden-a.png)),url(a.png);--b:var(--a,url(hidden-b.png)),url(b.png)}
      a{background:var(--a),var(--b)}
      """)

    result = Variables.analyze([cyclic])
    assert result.status == :ok
    assert values(result) == ["a.png", "b.png"]

    nested = sheet("a{background:var(--missing,var(--missing,url(hidden.png)))}")
    assert values(Variables.analyze([nested])) == []
  end

  test "work, depth and distinct output limits return explicit outcomes without partial pictures" do
    graph = sheet(repeated_aliases(14))

    assert %{status: {:limited, :work}, pictures: [], stats: %{work: work}} =
             Variables.analyze([graph], true, max_work: 10)

    assert work <= 10

    assert %{status: {:limited, :depth}, pictures: []} =
             Variables.analyze([graph], true, max_depth: 5)

    outputs = sheet(":root{--a:url(a.png),url(b.png)}a{background:var(--a)}")

    assert %{status: {:limited, :pictures}, pictures: []} =
             Variables.analyze([outputs], true, max_pictures: 1)

    assert %{status: :ok, pictures: [_picture]} =
             Variables.analyze([graph], true, max_pictures: 1)
  end

  test "a later graph revision resolves new definitions instead of reusing an old result" do
    first = sheet(":root{--a:url(first.png)}a{background:var(--a)}")
    second = sheet(":root{--a:url(second.png)}a{background:var(--a)}")
    assert values(Variables.analyze([first], true, graph_revision: 1)) == ["first.png"]
    assert values(Variables.analyze([second], true, graph_revision: 2)) == ["second.png"]
  end

  test "invalid graph budgets are rejected" do
    for key <- [:max_work, :max_pictures, :max_depth], invalid <- [0, -1, :infinity, nil] do
      assert_raise ArgumentError, fn -> Variables.analyze([], true, [{key, invalid}]) end
    end
  end

  test "list adapters reject a limited graph instead of returning partial direct resources" do
    analysis = Scanner.analyze(over_depth_css())
    sheets = [Variables.sheet(analysis, :local, :local, 0)]
    result = Variables.analyze(sheets)
    assert %{status: {:limited, :depth}, pictures: []} = result

    adapters = [
      fn -> Variables.pictures!(result) end,
      fn -> Variables.all_pictures(sheets) end,
      fn -> Variables.variable_spans(sheets, :local) end,
      fn -> Variables.span_tokens(analysis) end
    ]

    for adapter <- adapters do
      error = assert_raise Variables.LimitError, adapter
      assert error.limit == :depth
    end
  end

  test "standalone CSS APIs fail the whole stylesheet after a graph limit" do
    css = over_depth_css()
    assert Enum.any?(Scanner.analyze(css).resources, &(&1.value == "direct.png"))

    for parse <- [&CssParser.spans/1, &CssParser.parse/1] do
      error = assert_raise Variables.LimitError, fn -> parse.(css) end
      assert error.limit == :depth
    end
  end

  defp over_depth_css do
    ":root{--v0:url(deep.png);" <>
      Enum.map_join(1..256, fn n -> "--v#{n}:var(--v#{n - 1});" end) <>
      "}a{background:url(direct.png),var(--v256)}"
  end

  defp repeated_aliases(depth) do
    ":root{--v0:url(picture.png);" <>
      Enum.map_join(1..depth, fn n -> "--v#{n}:var(--v#{n - 1}),var(--v#{n - 1});" end) <>
      "}a{background:var(--v#{depth})}"
  end

  defp sheet(css, id \\ :local, base \\ :local, order \\ 0) do
    Variables.sheet(Scanner.analyze(css), id, base, order)
  end

  defp values(result), do: Enum.map(result.pictures, & &1.token.value)
end
