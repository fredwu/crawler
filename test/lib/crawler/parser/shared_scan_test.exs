defmodule Crawler.Parser.SharedScanTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis
  alias Crawler.Parser.CssParser
  alias Crawler.Parser.JsParser
  alias Crawler.Parser.JsParser.Calls
  alias Crawler.Parser.JsParser.Scanner
  alias Crawler.Parser.ScriptReferences
  alias Crawler.Parser.SourceMap

  @opts %{url: "https://example.test/scripts/app.js", content_type: "application/javascript"}

  setup do
    Code.ensure_loaded!(Scanner)
    :ok
  end

  test "imports, API calls, and source-map annotations share one scan at each input size" do
    for count <- [1, 100, 1_000] do
      source =
        Enum.map_join(1..count, "\n", &~s|import("./module#{&1}.js");|) <>
          ~s|\nnew URL("./image.png", import.meta.url);\n//# sourceMappingURL=app.js.map|

      :erlang.trace_pattern({Scanner, :scan, 2}, true, [:call_count])

      try do
        refs = ScriptReferences.list(source, @opts)
        assert length(refs) == count + 2
        assert {:call_count, 1} = :erlang.trace_info({Scanner, :scan, 2}, :call_count)
      after
        :erlang.trace_pattern({Scanner, :scan, 2}, false, [:call_count])
      end
    end
  end

  test "scan-consuming entry points preserve the exact script goal and byte spans" do
    source =
      ~S|const n=await /g;var await=4;import(".\/hidden.js");const m=g/g;import("./real.js");| <>
        "\n//# sourceMappingURL=app.js.map"

    for goal <- [:script, :module] do
      opts = Map.put(@opts, :javascript_goal, goal)
      scan = Scanner.scan(source, goal)

      assert JsParser.specifier_spans(source, goal, scan) ==
               JsParser.specifier_spans(source, goal)

      assert Calls.spans(source, goal, scan) == Calls.spans(source, goal)
      assert SourceMap.javascript(source, opts, scan) == SourceMap.javascript(source, opts)
      assert ScriptReferences.list(source, opts, scan) == ScriptReferences.list(source, opts)
    end
  end

  test "CSS source-map selection consumes the scanner analysis" do
    source = ".x { background: url(image.png) }\n/*# sourceMappingURL=app.css.map */"
    opts = Map.put(@opts, :content_type, "text/css")
    analysis = CssParser.Scanner.analyze(source)

    assert SourceMap.css(source, opts, analysis) == SourceMap.css(source, opts)
  end

  test "batched script edits preserve all bytes outside the reference spans" do
    source =
      ~S|/* literal import("./skip.js") */ import("./a.js"); import("./a.js");| <>
        "\n//# sourceMappingURL=app.js.map\n"

    target = "fixtures/a.js"
    map = "fixtures/app.js.map"
    assert {:ok, analysis} = Analysis.analyze(source, @opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, @opts)

    assert Enum.map(collection.occurrences, & &1.url) == [
             "https://example.test/scripts/a.js",
             "https://example.test/scripts/a.js",
             "https://example.test/scripts/app.js.map"
           ]

    assert {:ok, bound} =
             Analysis.bind(collection, fn
               %{
                 source_role: {:javascript, :module},
                 value: "./a.js",
                 context: %{javascript_goal: :module}
               } ->
                 %{fixture: :module, path: target}

               %{
                 source_role: {:javascript, :module},
                 value: "https://example.test/scripts/app.js.map",
                 context: %{fetch_kind: :source_map}
               } ->
                 %{fixture: :map, path: map}
             end)

    assert {:ok, rewritten} =
             Analysis.render(analysis, bound, fn ref -> {:local, ref.target.path} end)

    assert rewritten ==
             ~s|/* literal import("./skip.js") */ import("#{target}"); import("#{target}");| <>
               "\n//# sourceMappingURL=#{map}\n"
  end
end
