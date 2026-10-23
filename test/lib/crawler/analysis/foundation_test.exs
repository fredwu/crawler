defmodule Crawler.Analysis.FoundationTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis
  alias Crawler.Analysis.Occurrence

  @url "https://example.test/dir/page.html"
  @opts %{
    url: @url,
    referrer_url: @url,
    content_type: "text/html",
    assets: ["js", "css", "images"]
  }

  defp analyze(source, opts \\ @opts) do
    {:ok, analysis} = Analysis.analyze(source, opts)
    {:ok, occurrences} = Analysis.occurrences(analysis, opts)
    {analysis, occurrences}
  end

  defp bind(occurrences), do: Enum.with_index(occurrences, &Occurrence.bind(&1, {:target, &2}))

  defp local(
         analysis,
         occurrences,
         mapper \\ fn occurrence -> "/saved/" <> Path.basename(URI.parse(occurrence.url).path) end
       ) do
    Analysis.render(analysis, bind(occurrences), fn occurrence ->
      {:local, mapper.(occurrence)}
    end)
  end

  test "same URL retains distinct element credentials and target handles" do
    source =
      ~s|<img src="same"><script type="module" crossorigin="use-credentials" src="same"></script><script type="module" src="same"></script>|

    {analysis, refs} = analyze(source)
    assert length(refs) == 3
    assert Enum.map(refs, & &1.context.credentials) == [:include, :include, :same_origin]
    assert Enum.map(refs, & &1.context.javascript_goal) == [nil, :module, :module]
    assert Enum.uniq_by(refs, & &1.id) == refs

    assert {:ok, result} =
             local(analysis, refs, fn occurrence ->
               {:target, index} = occurrence.target
               "/saved/variant-#{index}"
             end)

    assert result =~ ~s|<img src="/saved/variant-0">|
    assert result =~ ~s|src="/saved/variant-1"|
    assert result =~ ~s|src="/saved/variant-2"|

    assert {:error, :unbound_local_target} =
             Analysis.render(analysis, refs, fn _ -> {:local, "x"} end)
  end

  test "HTML and XML self closing scripts follow their own source modes" do
    source = ~s|<script src="a.js"/><style/><a href="next.xhtml"/>|
    {_html, html} = analyze(source)
    assert Enum.map(html, & &1.value) == ["a.js"]
    opts = Map.put(@opts, :content_type, "application/xhtml+xml")
    {xml, refs} = analyze(source, opts)
    assert Enum.map(refs, & &1.value) == ["a.js", "next.xhtml"]
    assert {:ok, output} = local(xml, refs)
    assert output == ~s|<script src="/saved/a.js"/><style/><a href="/saved/next.xhtml"/>|
  end

  test "XML namespaces are exact and prefixed href uses its namespace URI" do
    source =
      ~s|<s:svg xmlns:s="http://www.w3.org/2000/svg" xmlns:q="http://www.w3.org/1999/xlink" xmlns:xlink="urn:wrong"><s:image q:href="good.png"/><s:image xlink:href="bad.png"/><s:Image href="bad2.png"/><s:feImage href="filter.png"/><s:image HREF="bad3.png"/></s:svg>|

    opts = Map.put(@opts, :content_type, "image/svg+xml")
    {_analysis, refs} = analyze(source, opts)
    assert Enum.map(refs, & &1.value) == ["good.png", "filter.png"]
  end

  test "UTF16-decoded prefixed SVG has UTF8 source spans" do
    text =
      ~s|<?xml version="1.0" encoding="UTF-16"?><s:svg xmlns:s="http://www.w3.org/2000/svg"><s:image href="café.png"/></s:svg>|

    bytes = <<255, 254>> <> :unicode.characters_to_binary(text, :utf8, {:utf16, :little})
    opts = Map.put(@opts, :content_type, "image/svg+xml")
    decoded = Crawler.Charset.decode(bytes, opts)
    assert String.valid?(decoded)
    {analysis, refs} = analyze(decoded, opts)
    assert [ref] = refs
    assert ref.value == "café.png"
    assert {:ok, output} = local(analysis, refs, fn _ -> "/saved/cafe.png" end)
    assert output =~ ~s|<s:image href="/saved/cafe.png"/>|
    assert output =~ "encoding=\"utf-8\""
  end

  test "XML code references crossing CDATA segments keep delimiters" do
    source =
      ~s|<script xmlns="http://www.w3.org/1999/xhtml" type="module">import "./fi<![CDATA[le]]>.js";</script>|

    opts = Map.put(@opts, :content_type, "application/xhtml+xml")
    {analysis, refs} = analyze(source, opts)
    assert [ref] = refs
    assert ref.value == "./file.js"
    assert {:ok, output} = local(analysis, refs, fn _ -> "./local.js?a=1&b=2" end)

    assert output ==
             ~s|<script xmlns="http://www.w3.org/1999/xhtml" type="module">import "./local.js?a=1&amp;b=2<![CDATA[]]>";</script>|

    assert {:ok, %{tags: [tag, _close]}} = Crawler.XMLSpans.analyze(output)
    assert tag.content == ~s|import "./local.js?a=1&b=2";|
  end

  test "XML CDATA replacements cannot terminate the containing section" do
    source =
      ~s|<script xmlns="http://www.w3.org/1999/xhtml" type="module"><![CDATA[import "./file.js";]]></script>|

    opts = Map.put(@opts, :content_type, "application/xhtml+xml")
    {analysis, refs} = analyze(source, opts)
    assert {:ok, output} = local(analysis, refs, fn _ -> "/saved/a]]>b.js" end)
    assert {:ok, %{tags: [tag, _close]}} = Crawler.XMLSpans.analyze(output)
    assert tag.content =~ ~S|/saved/a]]>b.js|
    assert output =~ "]]]]><![CDATA[>"
  end

  test "nested srcdoc is rendered once and escaped through each outer attribute" do
    nested = ~s|<a data-x='unchanged' href='child.html'>child</a>|
    inner = "<iframe srcdoc=\"" <> escape(nested) <> "\"></iframe><a href='sibling.html'>s</a>"

    source =
      "<p>before &copy;</p><iframe srcdoc=\"" <> escape(inner) <> "\"></iframe><p>after</p>"

    {analysis, refs} = analyze(source)
    assert Enum.map(refs, & &1.value) == ["child.html", "sibling.html"]

    assert {:ok, result, stats} =
             Analysis.render_with_stats(analysis, bind(refs), fn ref ->
               {:local, "/saved/" <> ref.value}
             end)

    assert stats.batches == 3
    assert String.starts_with?(result, "<p>before &copy;</p>")
    assert String.ends_with?(result, "<p>after</p>")
    [outer] = Enum.filter(Crawler.HTMLSpans.tags(result), &(&1.name == "iframe"))
    inner_result = Crawler.HTMLSpans.value(outer, "srcdoc")
    [iframe, anchor] = Enum.reject(Crawler.HTMLSpans.tags(inner_result), & &1.closing?)
    child_result = Crawler.HTMLSpans.value(iframe, "srcdoc")
    assert child_result == ~s|<a data-x='unchanged' href='/saved/child.html'>child</a>|
    assert Crawler.HTMLSpans.value(anchor, "href") == "/saved/sibling.html"
  end

  test "unrelated entity spelling, spacing, and quote bytes survive edits" do
    source =
      "<!--héllo-->\n<A  data-x='&#38;' href='one?a=1&amp;b=2#frag' title=keep> &copy; </A>\n"

    {analysis, refs} = analyze(source)
    assert [ref] = refs
    assert ref.value == "one?a=1&b=2#frag"
    assert {:ok, output} = local(analysis, refs, fn _ -> "two?x=1&y=2" end)

    assert output ==
             "<!--héllo-->\n<A  data-x='&#38;' href='two?x&#61;1&amp;y&#61;2#frag' title=keep> &copy; </A>\n"
  end

  test "srcset descriptors, refresh grammar, CSS strings and quote styles survive" do
    source =
      ~s|<img srcset="one.png 1x, two.png 2x"><meta http-equiv="refresh" content="0; url='next.html'"><div style="background: url(&quot;pic.png&quot;); color:red"></div>|

    {analysis, refs} = analyze(source)
    assert Enum.map(refs, & &1.value) == ["one.png", "two.png", "next.html", "pic.png"]
    assert {:ok, output} = local(analysis, refs)
    assert output =~ ~s|srcset="/saved/one.png 1x, /saved/two.png 2x"|
    assert output =~ ~s|content="0; url='/saved/next.html'"|
    assert output =~ ~s|style="background: url(&quot;/saved/pic.png&quot;); color:red"|
  end

  test "the first HTML base applies globally while import maps remain sequential" do
    source =
      ~s|<script type="module">import "bare";</script><a href="before"></a><base href="/assets/"><script type="importmap">{"imports":{"bare":"./mapped.js"},"scopes":{"/assets/scoped/":{"bare":"./scoped.js"}}}</script><script type="module">import "bare";</script><a href="after"></a><base href="/ignored/"><script type="module">import "bare";</script>|

    {analysis, refs} = analyze(source)

    assert Enum.map(refs, & &1.url) == [
             "https://example.test/assets/before",
             "https://example.test/assets/mapped.js",
             "https://example.test/assets/after",
             "https://example.test/assets/mapped.js"
           ]

    assert {:ok, output} = Analysis.render(analysis, refs, &Analysis.online_fallback/1)
    assert output =~ "<base>"
    refute output =~ "<base href="
    assert output =~ ~s|import "https://example.test/assets/mapped.js"|
  end

  test "one immutable JS scan serves different import map scopes without reparsing" do
    opts = Map.merge(@opts, %{content_type: "text/javascript", javascript_goal: :module})
    {:ok, analysis} = Analysis.analyze(~s|import "lib"; import("./dynamic.js");|, opts)

    map =
      Crawler.ImportMap.parse(
        ~s|{"imports":{"lib":"./default.js"},"scopes":{"https://example.test/scoped/":{"lib":"./scoped.js"}}}|,
        @url
      )

    assert {:ok, refs1} =
             Analysis.occurrences(
               analysis,
               Map.merge(opts, %{referrer_url: "https://example.test/plain/a.js", import_map: map})
             )

    assert {:ok, refs2} =
             Analysis.occurrences(
               analysis,
               Map.merge(opts, %{
                 referrer_url: "https://example.test/scoped/a.js",
                 import_map: map
               })
             )

    assert hd(refs1).url == "https://example.test/dir/default.js"
    assert hd(refs2).url == "https://example.test/dir/scoped.js"
    assert analysis.stats.scans == %{{:javascript, :module} => 1}

    assert {:error, :incompatible_script_goal} =
             Analysis.occurrences(analysis, Map.put(opts, :javascript_goal, :script))
  end

  test "classic scripts suppress static imports and preserve worker API contexts" do
    opts =
      Map.merge(@opts, %{
        content_type: "text/javascript",
        javascript_goal: :script,
        worker_base: "https://example.test/worker.js"
      })

    {_analysis, refs} =
      analyze(
        ~s|import "./static.js"; import("./dynamic.js"); importScripts("./worker-child.js"); new Worker("./nested.js", {type:"module", credentials:"include"});|,
        opts
      )

    refute Enum.any?(refs, &(&1.value == "./static.js"))
    assert Enum.find(refs, &(&1.value == "./dynamic.js")).context.javascript_goal == :module
    assert Enum.find(refs, &(&1.value == "./worker-child.js")).context.javascript_goal == :script
    worker = Enum.find(refs, &(&1.value == "./nested.js"))
    assert worker.context.javascript_goal == :module
    assert worker.context.credentials == :include
    assert worker.context.worker_base == "https://example.test/nested.js"
  end

  test "only the first manifest is emitted and speculation roles retain credentials" do
    source =
      ~s|<link rel="manifest" href="one.webmanifest"><link rel="manifest" href="two.webmanifest"><script type="speculationrules">{"prefetch":[{"urls":["pre.html"]}],"prerender":[{"urls":["render.html"]}]}</script>|

    {_analysis, refs} = analyze(source)
    assert Enum.map(refs, & &1.value) == ["one.webmanifest", "pre.html", "render.html"]
    assert hd(refs).context.fetch_kind == :manifest
    assert Enum.at(refs, 1).context.credentials == :same_site
    assert Enum.at(refs, 1).context.page_open == false
    assert Enum.at(refs, 2).context.page_open == true
  end

  test "strict located JSON feeds manifest, speculation and source-map roles once" do
    for kind <- [:manifest, :speculation_rules, :source_map] do
      opts = Map.put(@opts, :fetch_kind, kind)
      assert {:error, :invalid_json} = Analysis.analyze(~S|{"url":"bad\q"}|, opts)
    end

    opts = Map.put(@opts, :fetch_kind, :manifest)

    {analysis, refs} =
      analyze(
        ~s| {"start_url":"./start","icons":[{"src":"icon.png"}],"shortcuts":[{"url":"./shortcut"}]} |,
        opts
      )

    assert Enum.map(refs, & &1.context.html_tag) == ["a", "img", "a"]
    assert analysis.stats.scans == %{json: 1}
    assert {:ok, output} = local(analysis, refs)
    assert output =~ ~s|"start_url":"/saved/start"|
  end

  test "source-map comment spans and source roots use the same occurrences for rendering" do
    opts = Map.merge(@opts, %{content_type: "text/javascript", javascript_goal: :module})
    {analysis, refs} = analyze("/*unchanged*/\nexport {};\n//# sourceMappingURL=map.json\n", opts)
    assert [ref] = refs
    assert ref.context.fetch_kind == :source_map
    assert {:ok, output} = local(analysis, refs)
    assert output == "/*unchanged*/\nexport {};\n//# sourceMappingURL=/saved/map.json\n"
    opts = Map.put(@opts, :fetch_kind, :source_map)

    {analysis, refs} =
      analyze(
        ~s|{"version":3,"sourceRoot":"../src","sources":["one.js","two.js"],"sourcesContent":[null,"embedded"]}|,
        opts
      )

    assert Enum.map(refs, & &1.url) == ["https://example.test/src/one.js"]
    assert {:ok, output} = local(analysis, refs)
    assert output =~ ~s|"sourceRoot":""|
    assert output =~ ~s|"sources":["/saved/one.js","two.js"]|
  end

  test "integrity is removed only when the bound target selects changed local bytes" do
    source =
      ~s|<script integrity="sha256-keep" src="online.js"></script><link rel="stylesheet" integrity='sha256-drop' href="local.css">|

    {analysis, refs} = analyze(source)

    assert {:ok, output} =
             Analysis.render(analysis, bind(refs), fn ref ->
               if ref.value == "local.css",
                 do: {:local, "/saved/local.css"},
                 else: {:online, ref.url}
             end)

    assert output =~ ~s|integrity="sha256-keep"|
    refute output =~ "sha256-drop"
    assert output =~ ~s|src="https://example.test/dir/online.js"|
  end

  test "online fallback removes userinfo and retains fragments" do
    source = ~s|<a href="https://user:secret@elsewhere.test/path#part">x</a>|
    {analysis, refs} = analyze(source)
    assert {:ok, output} = Analysis.render(analysis, refs, &Analysis.online_fallback/1)
    assert output == ~s|<a href="https://elsewhere.test/path#part">x</a>|
  end

  test "CSS exposes graph facts and accepts bounded revisioned settled tokens without state" do
    source =
      ":root{--image:url(pic.png)} .a{background:var(--image)} @font-face{src:url(font.woff2)}"

    opts = Map.put(@opts, :content_type, "text/css")
    {:ok, analysis} = Analysis.analyze(source, opts)
    %{0 => facts} = Analysis.css_facts(analysis)
    assert length(facts.bindings) == 1
    sheet = Crawler.Parser.CssParser.Variables.sheet(facts, :local, @url, 0)
    result = Crawler.Parser.CssParser.Variables.analyze([sheet], true, graph_revision: 42)
    assert result.status == :ok
    tokens = Crawler.Parser.CssParser.Variables.picture_spans(result.pictures, :local)

    assert {:ok, refs} =
             Analysis.occurrences(
               analysis,
               Map.merge(opts, %{css_revision: 42, css_tokens: %{0 => tokens}})
             )

    assert Enum.map(refs, & &1.value) == ["font.woff2", "pic.png"]
    assert Enum.find(refs, &(&1.value == "font.woff2")).context.credentials == :same_origin
    assert Enum.all?(refs, &(&1.context.css_revision == 42))
    assert {:ok, output} = local(analysis, refs)
    assert output =~ "url(/saved/pic.png)"
  end

  test "semantic context keys exclude traversal history and include graph revision" do
    assert Analysis.context_key(%{javascript_goal: :module, css_revision: 1, depth: 1, path: [:a]}) ==
             Analysis.context_key(%{
               javascript_goal: :module,
               css_revision: 1,
               depth: 100,
               path: [:b]
             })

    refute Analysis.context_key(%{css_revision: 1}) == Analysis.context_key(%{css_revision: 2})
  end

  test "lexical scan and render batch counts scale by regions, not unique URLs" do
    for count <- [1, 50, 500] do
      source = Enum.map_join(1..count, fn n -> ~s|import "./module-#{n}.js";\n| end)
      opts = Map.merge(@opts, %{content_type: "text/javascript", javascript_goal: :module})
      {analysis, refs} = analyze(source, opts)
      assert length(refs) == count
      assert analysis.stats.scans == %{{:javascript, :module} => 1}

      assert {:ok, output, stats} =
               Analysis.render_with_stats(analysis, bind(refs), fn ref ->
                 {:local, "/saved/" <> Path.basename(ref.value)}
               end)

      assert stats.batches == 1
      assert stats.edits == count
      assert output =~ "module-#{count}.js"
    end
  end

  test "managed source, region, occurrence, edit and output budgets are explicit" do
    assert {:error, :invalid_limits} = Analysis.analyze("", max_bytes: -1)
    assert {:error, {:limit, :source_bytes}} = Analysis.analyze("12345", max_bytes: 4)

    assert {:error, {:limit, :source_regions}} =
             Analysis.analyze(~s|<a href="a">a</a>|, max_regions: 1)

    {:ok, analysis} =
      Analysis.analyze(~s|<a href="a"></a><a href="b"></a>|, Map.put(@opts, :max_occurrences, 1))

    assert {:error, {:limit, :occurrences}} = Analysis.occurrences(analysis, @opts)
    {analysis, refs} = analyze(~s|<a href="a"></a>|, Map.put(@opts, :max_output_bytes, 20))

    assert {:error, {:limit, :rendered_bytes}} =
             local(analysis, refs, fn _ -> String.duplicate("a", 100) end)

    assert {:error, :invalid_online_target} =
             Analysis.render(analysis, refs, fn _ -> {:online, "javascript:alert(1)"} end)
  end

  test "malformed XML and external entities produce explicit failure without resolution" do
    opts = Map.put(@opts, :content_type, "image/svg+xml")
    assert {:error, :invalid_xml} = Analysis.analyze("<svg><image></svg>", opts)

    assert {:error, :invalid_xml} =
             Analysis.analyze(
               ~s|<!DOCTYPE svg SYSTEM "https://external.test/x"><svg>&external;</svg>|,
               opts
             )
  end

  test "discovery callback receives the original occurrence contexts" do
    {_analysis, [ref]} = analyze(~s|<script type="module" src="x.js"></script>|)

    assert Occurrence.handler_element(ref) ==
             {"link", "x.js", "src", "https://example.test/dir/x.js"}

    assert Occurrence.handler_options(ref, %{scope: :scope}).javascript_goal == :module
  end

  defp escape(source),
    do:
      source
      |> String.replace("&", "&amp;")
      |> String.replace("\"", "&quot;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
end
