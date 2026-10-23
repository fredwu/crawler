defmodule Crawler.Analysis.BoundariesTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis
  alias Crawler.Analysis.Occurrence

  @opts %{
    url: "https://example.test/dir/page.html",
    referrer_url: "https://example.test/dir/page.html",
    content_type: "text/html",
    assets: ["js", "css", "images"]
  }

  defp references(source, opts \\ @opts) do
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, occurrences} = Analysis.occurrences(analysis, opts)
    {analysis, occurrences}
  end

  defp render(analysis, refs) do
    bound = Enum.with_index(refs, &Occurrence.bind(&1, {:target, &2}))

    Analysis.render(analysis, bound, fn ref ->
      {:local, "/saved/" <> Path.basename(URI.parse(ref.url).path)}
    end)
  end

  test "document sheets settle together, including definitions after their use" do
    source =
      ~s|<style>.a{background:var(--image)}</style><style>:root{--image:url(later.png)}</style>|

    {analysis, refs} = references(source)
    assert Enum.map(refs, & &1.value) == ["later.png"]
    assert {:ok, output} = render(analysis, refs)

    assert output ==
             ~s|<style>.a{background:var(--image)}</style><style>:root{--image:url(/saved/later.png)}</style>|
  end

  test "CSS fallbacks and srcdoc document groups do not contaminate each other" do
    source =
      ~s|<style>:root{--image:url(parent.png)} .a{background:var(--image,url(parent-fallback.png))}</style><iframe srcdoc='<style>.b{background:var(--image,url(child-fallback.png))}</style>'></iframe>|

    {analysis, refs} = references(source)
    assert Enum.map(refs, & &1.value) == ["parent.png", "child-fallback.png"]
    assert {:ok, output} = render(analysis, refs)
    assert output =~ "/saved/parent.png"
    assert output =~ "/saved/child-fallback.png"
    assert output =~ "url(parent-fallback.png)"
  end

  test "CSS import roles and supplied snapshots are bounded and revisioned" do
    opts = Map.put(@opts, :content_type, "text/css")

    {analysis, refs} =
      references(
        ~s|@import "child.css"; @font-face{src:url(font.woff2)} .a{background:url(image.png)}|,
        opts
      )

    assert Enum.map(refs, & &1.context.credentials) == [:include, :same_origin, :include]
    assert Enum.map(refs, & &1.value) == ["child.css", "font.woff2", "image.png"]

    assert {:error, :missing_css_revision} =
             Analysis.occurrences(analysis, Map.put(opts, :css_tokens, %{0 => []}))

    assert {:error, :invalid_css_snapshot} =
             Analysis.occurrences(
               analysis,
               Map.merge(opts, %{
                 css_revision: 1,
                 css_tokens: %{0 => [%{value: "x", start: -1, length: 1}]}
               })
             )

    assert {:error, :invalid_css_snapshot} =
             Analysis.occurrences(
               analysis,
               Map.merge(opts, %{css_revision: 1, css_tokens: %{0 => :not_a_list}})
             )
  end

  test "data source maps decode and render one child region for percent and base64 encodings" do
    payload =
      ~s|{"version":3,"sourceRoot":"../src","sources":["one.js","two.js"],"sourcesContent":[null,"embedded"]}|

    for encoding <- [:percent, :base64] do
      meta =
        if encoding == :base64, do: "data:application/json;base64", else: "data:application/json"

      url = Crawler.Parser.SourceMap.encode_data(payload, meta, encoding)
      source = "export {};\n//# sourceMappingURL=" <> url
      opts = Map.merge(@opts, %{content_type: "text/javascript", javascript_goal: :module})
      {analysis, refs} = references(source, opts)
      assert Enum.map(refs, & &1.url) == ["https://example.test/src/one.js"]
      assert analysis.stats.scans == %{{:javascript, :module} => 1, source_map: 1}
      assert {:ok, output} = render(analysis, refs)
      [_, data] = String.split(output, "//# sourceMappingURL=", parts: 2)
      assert {:ok, rewritten, ^meta, ^encoding} = Crawler.Parser.SourceMap.decode_data(data)

      assert rewritten ==
               ~s|{"version":3,"sourceRoot":"","sources":["/saved/one.js","two.js"],"sourcesContent":[null,"embedded"]}|
    end
  end

  test "CSS header source maps append CSS syntax and data maps preserve the selected header" do
    payload = ~s|{"version":3,"sources":["original.css"]}|
    data = "data:application/json;base64," <> Base.encode64(payload)
    opts = Map.merge(@opts, %{content_type: "text/css", headers: [{"sourcemap", data}]})
    {analysis, refs} = references(".a {color:red}", opts)
    assert Enum.map(refs, & &1.value) == ["original.css"]
    assert {:ok, output} = render(analysis, refs)
    assert String.starts_with?(output, ".a {color:red}\n/*# sourceMappingURL=data:")
    assert String.ends_with?(output, " */")
    opts = %{opts | headers: [{"sourcemap", "style.css.map"}]}
    {analysis, refs} = references(".a {color:red}", opts)
    assert {:ok, output} = render(analysis, refs)
    assert output == ".a {color:red}\n/*# sourceMappingURL=/saved/style.css.map */"
  end

  test "inline sourceURL changes source-map base without changing module import base" do
    source =
      ~s|<script type="module">import "./module.js";| <>
        "\n//# sourceURL=https://other.test/debug.js\n//# sourceMappingURL=source.map\n</script>"

    {_analysis, refs} = references(source)

    assert Enum.map(refs, & &1.url) == [
             "https://example.test/dir/module.js",
             "https://other.test/source.map"
           ]
  end

  test "XML text entity spelling survives outside changed code spans" do
    source =
      ~s|<script xmlns="http://www.w3.org/1999/xhtml" type="module">const x="keep&#38;this"; import "./a.js?x=1&amp;y=2";</script>|

    opts = Map.put(@opts, :content_type, "application/xhtml+xml")
    {analysis, refs} = references(source, opts)
    assert {:ok, output} = render(analysis, refs)

    assert output ==
             ~s|<script xmlns="http://www.w3.org/1999/xhtml" type="module">const x="keep&#38;this"; import "/saved/a.js";</script>|
  end

  test "foreign XML uppercase type attributes cannot activate script or import-map modes" do
    source =
      ~s|<html xmlns="http://www.w3.org/1999/xhtml"><script TYPE="module">import "./static.js";import("./dynamic.js");</script><script TYPE="importmap">{"imports":{"lib":"./lib.js"}}</script><script type="module">import "lib";</script></html>|

    opts = Map.put(@opts, :content_type, "application/xhtml+xml")
    {_analysis, refs} = references(source, opts)
    assert Enum.map(refs, & &1.value) == ["./dynamic.js"]
  end

  test "unquoted HTML attributes retain their grammar with arbitrary path characters" do
    source = "<a href=old>x</a>"
    {analysis, [ref]} = references(source)

    assert {:ok, output} =
             Analysis.render(analysis, [Occurrence.bind(ref, :target)], fn _ ->
               {:local, "new a='b`c\""}
             end)

    [tag | _] = Crawler.HTMLSpans.tags(output)
    assert Crawler.HTMLSpans.value(tag, "href") == "new a='b`c\""
    assert output =~ "<a href=new&#32;a&#61;&#39;b&#96;c&quot;>"
  end

  test "nested and conflicting edits return explicit errors" do
    {analysis, [ref]} = references(~s|<a href="one">x</a>|)
    ref = Occurrence.bind(ref, :target)

    assert {:error, :conflicting_source_edits} =
             Analysis.render(analysis, [ref, %{ref | target: :other}], fn ref ->
               {:local, Atom.to_string(ref.target)}
             end)

    assert {:error, :invalid_occurrence} =
             Analysis.render(analysis, [%{ref | span: {-1, 1}}], fn _ -> :keep end)

    assert {:ok, source} = Analysis.render(analysis, [ref, ref], fn _ -> :keep end)
    assert source == ~s|<a href="one">x</a>|
  end

  test "no edits preserve the exact source even when base and integrity metadata exist" do
    source =
      ~s|<base href="https://elsewhere.test/"><script integrity='original' src="a.js"></script>|

    {analysis, refs} = references(source)
    assert {:ok, ^source} = Analysis.render(analysis, refs, fn _ -> :keep end)
  end
end

defmodule Crawler.Analysis.InstrumentationTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis
  alias Crawler.Analysis.Occurrence
  alias Crawler.Parser.JsParser.Scanner

  test "real scan and rewrite calls stay constant while references increase" do
    for count <- [1, 100, 1_000] do
      source = Enum.map_join(1..count, "\n", &~s|import("./module#{&1}.js");|)
      opts = %{content_type: "text/javascript", url: "https://example.test/app.js"}
      :erlang.trace_pattern({Scanner, :scan_result, 3}, true, [:call_count])
      :erlang.trace_pattern({Crawler.HTMLSpans, :rewrite, 2}, true, [:call_count])

      try do
        assert {:ok, analysis} = Analysis.analyze(source, opts)
        assert {:ok, refs} = Analysis.occurrences(analysis, opts)
        bound = Enum.with_index(refs, &Occurrence.bind(&1, {:target, &2}))

        assert {:ok, _output} =
                 Analysis.render(analysis, bound, fn ref -> {:local, "saved/" <> ref.value} end)

        assert {:call_count, 1} = :erlang.trace_info({Scanner, :scan_result, 3}, :call_count)

        assert {:call_count, 1} =
                 :erlang.trace_info({Crawler.HTMLSpans, :rewrite, 2}, :call_count)
      after
        :erlang.trace_pattern({Scanner, :scan_result, 3}, false, [:call_count])
        :erlang.trace_pattern({Crawler.HTMLSpans, :rewrite, 2}, false, [:call_count])
      end
    end
  end

  test "located JSON is read once across repeated source-map interpretation and render" do
    payload = ~s|{"version":3,"sources":["original.js"]}|
    source = "//# sourceMappingURL=data:application/json;base64," <> Base.encode64(payload)
    opts = %{content_type: "text/javascript", url: "https://example.test/app.js"}

    :erlang.trace_pattern({Crawler.ImportMap.JSON, :decode_located_result, 2}, true, [:call_count])

    try do
      assert {:ok, analysis} = Analysis.analyze(source, opts)

      for _ <- 1..5 do
        assert {:ok, refs} = Analysis.occurrences(analysis, opts)
        bound = Enum.map(refs, &Occurrence.bind(&1, :target))
        assert {:ok, _output} = Analysis.render(analysis, bound, fn _ -> {:local, "saved.js"} end)
      end

      assert {:call_count, 1} =
               :erlang.trace_info(
                 {Crawler.ImportMap.JSON, :decode_located_result, 2},
                 :call_count
               )
    after
      :erlang.trace_pattern({Crawler.ImportMap.JSON, :decode_located_result, 2}, false, [
        :call_count
      ])
    end
  end
end

defmodule Crawler.Analysis.FragmentProjectionTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis

  @opts %{
    url: "https://example.test/dir/page",
    content_type: "text/html",
    assets: [],
    respect_robots: false
  }

  test "fragments strip literal URL breaks and trailing C0 while retaining percent escapes" do
    for {fragment, expected} <- [
          {"x\ny", "xy"},
          {"x\ry", "xy"},
          {"x\ty", "xy"},
          {"xy\x01\x1F ", "xy"},
          {"x%0Ay%0D%09%00%2F", "x%0Ay%0D%09%00%2F"},
          {"x%ZZ", "x%25ZZ"},
          {"x\x01y", "x%01y"},
          {"é%2f", "%c3%a9%2f"},
          {"a#b", "a%23b"},
          {"", ""}
        ] do
      source = ~s|<a href="next##{fragment}" title="keep">go</a>|
      assert {:ok, analysis} = Analysis.analyze(source, @opts)
      assert {:ok, collection} = Analysis.occurrences_result(analysis, @opts)
      [ref] = collection.occurrences
      assert ref.value == "next#" <> fragment
      assert ref.fragment == expected
      assert analysis.regions[analysis.root].source == source
      assert {:ok, bound} = Analysis.bind(collection, fn _ -> :target end)
      local = ~s|<a href="saved##{expected}" title="keep">go</a>|
      online = ~s|<a href="https://example.test/dir/next##{expected}" title="keep">go</a>|
      assert {:ok, ^local} = Analysis.render(analysis, bound, fn _ -> {:local, "saved"} end)
      assert {:ok, ^online} = Analysis.render(analysis, collection, &Analysis.online_fallback/1)
    end
  end

  test "CSS and JavaScript use the same canonical semantic fragment" do
    for {type, source, expected} <- [
          {"text/css", ~s|body{background:url("./next#x%ZZ")}|,
           ~s|body{background:url("saved#x%25ZZ")}|},
          {"application/javascript", ~s|import("./next#x%ZZ");|, ~s|import("saved#x%25ZZ");|}
        ] do
      opts = Map.merge(@opts, %{content_type: type, assets: ["css", "js", "images"]})
      assert {:ok, analysis} = Analysis.analyze(source, opts)
      assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)
      assert [ref] = collection.occurrences
      assert ref.value == "./next#x%ZZ"
      assert ref.fragment == "x%25ZZ"
      assert {:ok, bound} = Analysis.bind(collection, fn _ -> :target end)
      assert {:ok, ^expected} = Analysis.render(analysis, bound, fn _ -> {:local, "saved"} end)
      assert analysis.regions[analysis.root].source == source
    end
  end

  test "entity-decoded unsafe fragments are encoded before source escaping" do
    source = ~s|<a href="next#&quot; onclick=&quot;alert(1)" title="keep">go</a>|
    assert {:ok, analysis} = Analysis.analyze(source, @opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, @opts)
    [ref] = collection.occurrences
    assert ref.value == ~s|next#" onclick="alert(1)|
    assert ref.fragment == "%22%20onclick=%22alert%281%29"
    assert {:ok, bound} = Analysis.bind(collection, fn _ -> :target end)
    assert {:ok, output} = Analysis.render(analysis, bound, fn _ -> {:local, "saved"} end)
    assert output == ~s|<a href="saved#%22%20onclick&#61;%22alert%281%29" title="keep">go</a>|

    assert [{"a", [{"href", "saved#%22%20onclick=%22alert%281%29"}, {"title", "keep"}], ["go"]}] =
             Floki.parse_fragment!(output)

    assert analysis.regions[analysis.root].source == source
  end
end
