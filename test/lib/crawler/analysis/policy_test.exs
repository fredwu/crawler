defmodule Crawler.Analysis.PolicyTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis
  alias Crawler.Analysis.Occurrence

  @opts %{
    url: "https://example.test/page",
    content_type: "text/html",
    assets: ["css", "js", "images"]
  }

  defp refs(source, options \\ %{}) do
    opts = Map.merge(@opts, options)
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, refs} = Analysis.occurrences(analysis, opts)
    {analysis, refs}
  end

  test "equal local text neutralizes its base while kept references retain their destinations" do
    source =
      ~s|<base href="https://origin.test/assets/"><script src="next.js" integrity="original"></script><a href="keep.html#part">K</a>|

    opts = Map.merge(@opts, %{url: "https://origin.test/page", respect_robots: false})
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)
    assert {:ok, bound} = Analysis.bind(collection, fn _ -> :target end)

    assert {:ok, output} =
             Analysis.render(analysis, bound, fn ref ->
               if ref.value == "next.js", do: {:local, "next.js"}, else: :keep
             end)

    assert output ==
             ~s|<base><script src="next.js" integrity="original"></script><a href="https://origin.test/assets/keep.html#part">K</a>|

    assert {:ok, ^source} = Analysis.render(analysis, bound, fn _ -> :keep end)

    assert {:ok, disabled} =
             Analysis.render(
               analysis,
               bound,
               fn ref ->
                 if ref.value == "next.js", do: {:local, "next.js"}, else: :keep
               end,
               neutralize_base: false
             )

    assert disabled == source
    assert analysis.regions[analysis.root].source == source
  end

  test "local srcdoc targets clear ancestor bases and preserve outer keep destinations" do
    source =
      ~s|<base href="/outer/"><a href="outer.html">O</a><iframe srcdoc="&lt;base href='/inner/'&gt;&lt;a href='inner.html'&gt;I&lt;/a&gt;"></iframe>|

    opts = Map.put(@opts, :respect_robots, false)
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)
    assert {:ok, bound} = Analysis.bind(collection, fn _ -> :target end)

    assert {:ok, output} =
             Analysis.render(analysis, bound, fn ref ->
               if ref.value == "inner.html", do: {:local, "inner.html"}, else: :keep
             end)

    assert output =~ ~s|<base><a href="https://example.test/outer/outer.html">|
    assert output =~ "&lt;base&gt;"
    refute output =~ "'/inner/'"

    saved =
      Map.merge(opts, %{
        url: "https://saved.test/archive/page.html",
        referrer_url: "https://saved.test/archive/page.html"
      })

    assert {:ok, rewritten} = Analysis.analyze(output, saved)
    assert {:ok, destinations} = Analysis.occurrences(rewritten, saved)

    assert Enum.map(destinations, & &1.url) == [
             "https://example.test/outer/outer.html",
             "https://saved.test/archive/inner.html"
           ]
  end

  test "mixed source-map selections clear one leaf root and preserve emitted online destinations" do
    source =
      ~s|{"version":3,"sourceRoot":"/original/","sources":["a.js","b.js","https://cdn.test/c.js"]}|

    opts = %{
      url: "https://origin.test/map.json",
      content_type: "application/json",
      fetch_kind: :source_map
    }

    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)
    assert {:ok, bound} = Analysis.bind(collection, fn _ -> :target end)

    assert {:ok, output} =
             Analysis.render(analysis, bound, fn ref ->
               if ref.value == "a.js", do: {:local, "a.js"}, else: :keep
             end)

    assert {:ok, decoded} = Crawler.ImportMap.JSON.decode(output)

    assert decoded ==
             {:object,
              [
                {"version", 3},
                {"sourceRoot", ""},
                {"sources",
                 ["a.js", "https://origin.test/original/b.js", "https://cdn.test/c.js"]}
              ]}

    assert analysis.regions[analysis.root].source == source
  end

  test "indexed source-map roots change only in the selected semantic leaf" do
    source =
      ~s|{"version":3,"sourceRoot":"/unused/","sections":[{"map":{"version":3,"sourceRoot":"/nearest/","sections":[{"map":{"version":3,"sourceRoot":"/one/","sources":["a.js","b.js"]}}]}},{"map":{"version":3,"sourceRoot":"/two/","sources":["c.js"]}},{"url":"child.map"}],"other":{"sourceRoot":"/foreign/"}}|

    opts = %{
      url: "https://origin.test/map.json",
      content_type: "application/json",
      fetch_kind: :source_map
    }

    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)
    assert {:ok, bound} = Analysis.bind(collection, fn _ -> :target end)

    assert {:ok, output} =
             Analysis.render(analysis, bound, fn ref ->
               if ref.value == "a.js", do: {:local, "saved/a.js"}, else: :keep
             end)

    refute output =~ ~s|"sourceRoot":"/unused/"|
    refute output =~ ~s|"sourceRoot":"/nearest/"|
    assert output =~ ~s|"sourceRoot":"","sources":["saved/a.js","https://origin.test/one/b.js"]|
    assert output =~ ~s|"sourceRoot":"/two/","sources":["c.js"]|
    assert output =~ ~s|"url":"child.map"|
    assert output =~ ~s|"other":{"sourceRoot":"/foreign/"}|
  end

  test "changed local text removes integrity while online keep and disabled references retain it" do
    source =
      ~s|<base href="/assets/"><script src="local.js" integrity="local"></script><script src="online.js" integrity="online"></script><script src="keep.js" integrity="keep"></script>|

    opts = Map.put(@opts, :respect_robots, false)
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)
    assert {:ok, bound} = Analysis.bind(collection, fn _ -> :target end)

    assert {:ok, output} =
             Analysis.render(analysis, bound, fn ref ->
               case ref.value do
                 "local.js" -> {:local, "saved/local.js"}
                 "online.js" -> {:online, ref.url}
                 _value -> :keep
               end
             end)

    refute output =~ ~s|integrity="local"|
    assert output =~ ~s|integrity="online"|
    assert output =~ ~s|integrity="keep"|
    assert {:ok, disabled} = Analysis.occurrences_result(analysis, %{opts | assets: []})
    assert {:ok, ^source} = Analysis.render(analysis, disabled, fn _ -> :keep end)
  end

  test "ordinary HTML and inline script references stay identical across CSS snapshots" do
    source = """
    <img src="image.png"><video src="movie.mp4"></video><audio src="sound.mp3"></audio>
    <link rel="stylesheet" href="sheet.css"><script src="external.js"></script>
    <a href="next">next</a><script type="module">import "./inline.js";</script>
    <style>.x{}</style>
    """

    opts = Map.put(@opts, :respect_robots, false)
    assert {:ok, analysis} = Analysis.analyze(source, opts)

    [before, after_refresh] =
      for revision <- [:before, :after] do
        current = Map.merge(opts, %{css_tokens: %{}, css_references: %{}, css_revision: revision})
        assert {:ok, occurrences} = Analysis.occurrences(analysis, current)

        for occurrence <- occurrences do
          refute Map.has_key?(occurrence.context, :css_revision)
          refute Map.has_key?(Occurrence.handler_options(occurrence, current), :css_revision)
        end

        {occurrences, Enum.map(occurrences, &Occurrence.handler_options(&1, current))}
      end

    assert before === after_refresh
    {occurrences, _options} = before

    assert Enum.map(occurrences, & &1.value) == [
             "image.png",
             "movie.mp4",
             "sound.mp3",
             "sheet.css",
             "external.js",
             "next",
             "./inline.js"
           ]
  end

  test "CSS tokens and changed synthetic discovery retain their snapshot identity" do
    source = ~s|body{background:url("own.png")}|
    opts = Map.merge(@opts, %{content_type: "text/css", respect_robots: false})
    assert {:ok, analysis} = Analysis.analyze(source, opts)

    [before, after_refresh] =
      for {revision, value} <- [{:before, "old.png"}, {:after, "new.png"}] do
        picture = %{
          token: %{value: value, start: 900, length: byte_size(value), quote: "\"", kind: :url},
          token_sheet: :prior,
          token_base: "https://example.test/tokens.css",
          base_sheet: :reader,
          base_url: "https://example.test/assets/app.css"
        }

        current =
          Map.merge(opts, %{
            css_tokens: %{analysis.root => []},
            css_references: %{analysis.root => [picture]},
            css_revision: revision
          })

        assert {:ok, collection} = Analysis.occurrences_result(analysis, current)
        assert [own, synthetic] = collection.occurrences
        assert own.context.css_revision == revision
        assert synthetic.context.css_revision == revision
        assert Occurrence.handler_options(own, current).css_revision == revision
        assert Occurrence.handler_options(synthetic, current).css_revision == revision
        assert synthetic.url == "https://example.test/assets/" <> value
        assert synthetic.metadata.css_picture == picture
        assert {:ok, ^source} = Analysis.render(analysis, collection, fn _ -> :keep end)
        assert {:ok, bound} = Analysis.bind(collection, fn _ -> :target end)

        assert {:ok, ~s|body{background:url("saved.png")}|} =
                 Analysis.render(analysis, bound, fn _ -> {:local, "saved.png"} end)

        {own, synthetic}
      end

    {before_own, before_synthetic} = before
    {after_own, after_synthetic} = after_refresh
    refute before_own.id == after_own.id
    refute before_synthetic.id == after_synthetic.id
    assert before_own.url == after_own.url
    refute before_synthetic.url == after_synthetic.url
  end

  test "synthetic CSS fragments stay inert across sheet bases without changing facts" do
    opts =
      Map.merge(@opts, %{
        url: "https://example.test/root.css",
        content_type: "text/css",
        respect_robots: false
      })

    assert {:ok, analysis} = Analysis.analyze(".x{}", opts)

    for raw <- ["#mask", "  #mask  ", "\t#mask\n"] do
      picture = %{
        token: %{value: raw, start: 10, length: byte_size(raw), quote: "\"", kind: :url},
        token_sheet: :child,
        token_base: "https://example.test/child.css",
        base_sheet: :root,
        base_url: "https://example.test/root.css"
      }

      current =
        Map.merge(opts, %{
          css_tokens: %{analysis.root => []},
          css_references: %{analysis.root => [picture]},
          css_revision: :settled
        })

      assert {:ok, []} = Analysis.occurrences(analysis, current)
      assert picture.token.value == raw
    end

    picture = %{
      token: %{value: "pic.png", start: 10, length: 7, quote: "\"", kind: :url},
      token_sheet: :child,
      token_base: "https://example.test/child.css",
      base_sheet: :root,
      base_url: "https://example.test/root.css"
    }

    current =
      Map.merge(opts, %{
        css_tokens: %{analysis.root => []},
        css_references: %{analysis.root => [picture]},
        css_revision: :settled
      })

    assert {:ok, [ref]} = Analysis.occurrences(analysis, current)
    assert ref.url == "https://example.test/pic.png"
    assert analysis.regions[analysis.root].source == ".x{}"
  end

  test "XHTML policy attributes share canonical namespace and case rules without changing raw facts" do
    opts = %{
      content_type: "application/xhtml+xml",
      url: "https://example.test/dir/page",
      respect_robots: true
    }

    for name <- ["q:href", "HREF"] do
      source =
        ~s|<html xmlns="http://www.w3.org/1999/xhtml" xmlns:q="urn:foreign"><base #{name}="https://wrong.test/"/><base href="docs/"/><a href="next"/></html>|

      {analysis, [ref]} = refs(source, opts)
      assert ref.url == "https://example.test/dir/docs/next"
      raw = analysis.regions[analysis.root].facts.tags
      [foreign, valid] = Enum.filter(raw, &(&1.name == "base"))
      assert hd(foreign.attributes).value == "https://wrong.test/"
      assert hd(foreign.attributes).span != nil
      assert hd(valid.attributes).name == "href"
      assert {:ok, output} = Analysis.render(analysis, [ref], &Analysis.online_fallback/1)

      assert output ==
               String.replace(source, ~s| href="docs/"|, "")
               |> String.replace(~s|href="next"|, ~s|href="https://example.test/dir/docs/next"|)

      assert analysis.regions[analysis.root].facts.tags == raw
      assert analysis.regions[analysis.root].source == source
    end

    for {name, content} <- [
          {"q:name", "content"},
          {"NAME", "content"},
          {"name", "q:content"},
          {"name", "CONTENT"}
        ] do
      source =
        ~s|<html xmlns="http://www.w3.org/1999/xhtml" xmlns:q="urn:foreign"><meta #{name}="robots" #{content}="nofollow"/><a href="next"/></html>|

      {_analysis, [ref]} = refs(source, opts)
      assert ref.url == "https://example.test/dir/next"
    end

    {_analysis, []} =
      refs(~s|<html><meta name="robots" content="nofollow"/><a href="next"/></html>|, opts)

    {_analysis, []} =
      refs(~s|<BASE HREF="/docs/"><META NAME="ROBOTS" CONTENT="NOFOLLOW"><a href="next">|)

    {_analysis, [html]} = refs(~s|<BASE HREF="/docs/" href="/ignored/"><a HREF="next">|)
    assert html.url == "https://example.test/docs/next"
  end

  test "only the first canonical manifest choice consumes the document slot" do
    opts = %{content_type: "application/xhtml+xml", respect_robots: false}

    for name <- ["q:rel", "REL"] do
      source =
        ~s|<html xmlns="http://www.w3.org/1999/xhtml" xmlns:q="urn:foreign"><link #{name}="manifest" href="foreign"/><link rel="manifest" href="valid"/><link rel="manifest" href="later"/></html>|

      {_analysis, refs} = refs(source, opts)
      assert Enum.map(refs, & &1.value) == ["valid"]
      assert hd(refs).context.fetch_kind == :manifest
    end

    for {attrs, expected} <- [
          {~s|rel="manifest preload" as="script"|, [{"first", nil}, {"valid", :manifest}]},
          {~s|rel="manifest stylesheet"|, [{"first", nil}, {"valid", :manifest}]},
          {~s|rel="manifest stylesheet" disabled=""|, [{"first", :manifest}]},
          {~s|rel="manifest" crawler-speculation-rules="true"|,
           [{"first", :speculation_rules}, {"valid", :manifest}]},
          {~s|rel="manifest" crawler-from-header="true"|, [{"valid", :manifest}]},
          {~s|rel="manifest" q:crawler-from-header="true"|, [{"first", :manifest}]},
          {~s|rel="manifest preload" q:as="script"|, [{"first", :manifest}]}
        ] do
      source =
        ~s|<html xmlns="http://www.w3.org/1999/xhtml" xmlns:q="urn:foreign"><link #{attrs} href="first"/><link rel="manifest" href="valid"/></html>|

      {_analysis, refs} = refs(source, opts)
      assert Enum.map(refs, &{&1.value, &1.context.fetch_kind}) == expected
    end

    {_analysis, refs} =
      refs(
        ~s|<link rel="manifest" href="body"/>|,
        Map.put(opts, :headers, [{"Link", ~s|<header>; rel=manifest|}])
      )

    assert Enum.map(refs, & &1.value) == ["body"]
  end

  test "canonical XML policy does not leak into nested HTML or XLink references" do
    source =
      ~s|<html xmlns="http://www.w3.org/1999/xhtml" xmlns:q="urn:foreign"><base q:href="/wrong/"/><iframe srcdoc="&lt;BASE HREF='/child/'&gt;&lt;a HREF='next'&gt;"/><svg xmlns="http://www.w3.org/2000/svg" xmlns:x="http://www.w3.org/1999/xlink"><image x:href="pic.png" q:href="wrong.png"/></svg></html>|

    {analysis, refs} = refs(source, %{content_type: "application/xhtml+xml"})

    assert Enum.map(refs, & &1.url) == [
             "https://example.test/child/next",
             "https://example.test/pic.png"
           ]

    assert {:ok, output} = Analysis.render(analysis, refs, &Analysis.online_fallback/1)
    assert output =~ ~s|q:href="/wrong/"|
    assert output =~ ~s|q:href="wrong.png"|
    assert output =~ ~s|x:href="https://example.test/pic.png"|
    refute output =~ "HREF='/child/'"
  end

  test "headers are lexical references with their own roles and no body edits" do
    headers = [
      {"Link", ~s|<style.css>; rel=stylesheet, <app.js>; rel=modulepreload|},
      {"Refresh", "0;url=next.html"},
      {"Speculation-Rules", ~s|"rules.json"|}
    ]

    source = ~s|<a href="body.html">body</a>|

    for type <- ["text/html", "application/xhtml+xml"] do
      {analysis, occurrences} = refs(source, %{headers: headers, content_type: type})

      assert Enum.map(occurrences, & &1.value) == [
               "next.html",
               "style.css",
               "app.js",
               "rules.json",
               "body.html"
             ]

      assert Enum.map(occurrences, & &1.context.fetch_kind) == [
               nil,
               nil,
               nil,
               :speculation_rules,
               nil
             ]

      assert Enum.at(occurrences, 2).context.javascript_goal == :module
      assert Enum.map(occurrences, & &1.span) |> Enum.take(4) == [nil, nil, nil, nil]
      assert {:ok, output} = Analysis.render(analysis, occurrences, &Analysis.online_fallback/1)
      assert output == ~s|<a href="https://example.test/body.html">body</a>|
    end
  end

  test "meta and header nofollow share lexical document facts and isolate srcdoc" do
    source =
      ~s|<meta name="robots" content="nofollow"><a href="blocked">x</a><img src="image.png"><iframe srcdoc='<a href="child">c</a>'></iframe>|

    {_analysis, occurrences} = refs(source)
    assert Enum.map(occurrences, & &1.value) == ["image.png", "child"]
    {_analysis, occurrences} = refs(source, %{respect_robots: false})
    assert Enum.map(occurrences, & &1.value) == ["blocked", "image.png", "child"]

    {_analysis, occurrences} =
      refs(~s|<a href="blocked">x</a><img src="image.png">|, %{
        headers: [{"X-Robots-Tag", "nofollow"}]
      })

    assert Enum.map(occurrences, & &1.value) == ["image.png"]
  end

  test "XML camelcase SVG vocabulary is exact and uses image roles" do
    source =
      ~s|<s:svg xmlns:s="http://www.w3.org/2000/svg"><s:linearGradient href="good.svg"/><s:lineargradient href="wrong.svg"/><s:radialGradient href="good2.svg"/><s:feimage href="wrong2.svg"/></s:svg>|

    {_analysis, refs} = refs(source, %{content_type: "image/svg+xml"})

    assert Enum.map(refs, &{&1.value, &1.context.html_tag}) == [
             {"good.svg", "img"},
             {"good2.svg", "img"}
           ]
  end

  test "all duplicate integrity attributes are removed on a changed local reference" do
    source = ~s|<script integrity="first" integrity='second' src="app.js"></script>|
    {analysis, [ref]} = refs(source)

    assert {:ok, output} =
             Analysis.render(analysis, [Occurrence.bind(ref, :target)], fn _ ->
               {:local, "saved.js"}
             end)

    assert output == ~s|<script src="saved.js"></script>|
  end

  test "handler options retain legacy absence defaults and discard heavy source context" do
    {_analysis, [ref]} = refs(~s|<img src="image.png">|)

    options =
      Occurrence.handler_options(ref, %{
        scope: :scope,
        depth: 2,
        document_styles: :heavy,
        css_tokens: %{0 => [:heavy]},
        css_references: %{0 => [:heavy]},
        css_sheet_id: 0,
        document_style_id: 1,
        import_map: :parent_map,
        worker_base: "parent",
        credentials: :omit,
        javascript_goal: :module
      })

    assert options.scope == :scope
    assert options.depth == 2
    assert options.page_open == false
    assert options.html_tag == "img"

    for key <- [
          :document_styles,
          :document_style_id,
          :css_tokens,
          :css_references,
          :css_sheet_id,
          :import_map,
          :worker_base,
          :credentials,
          :javascript_goal
        ] do
      refute Map.has_key?(options, key)
    end
  end

  test "control file page depths are admission metadata and do not change interpretation identity" do
    {_analysis, [ref]} = refs(~s|{"start_url":"./home"}|, %{fetch_kind: :manifest})
    assert Occurrence.handler_options(ref, %{depth: 4}).depth == 3
    assert Occurrence.handler_options(ref, %{depth: 0}).depth == 0
    assert ref.context.html_tag == "a"
    refute Map.has_key?(ref.context, :depth)
  end

  test "managed stylesheet snapshots bypass local graph settlement" do
    source =
      ":root{" <>
        Enum.map_join(1..15, fn i -> "--v#{i}:var(--v#{i - 1}),var(--v#{i - 1});" end) <>
        "--v0:url(image.png)}.a{background:var(--v15)}"

    opts = Map.merge(@opts, %{content_type: "text/css", max_css_work: 40})
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:error, {:limit, {:css_graph, :work}}} = Analysis.occurrences(analysis, opts)

    assert {:ok, []} =
             Analysis.occurrences(
               analysis,
               Map.merge(opts, %{css_tokens: %{0 => []}, css_revision: :settled})
             )
  end

  test "occurrences from another source revision cannot be rendered against this source" do
    {analysis, _refs} = refs(~s|<a href="one">x</a>|)
    {_other, [ref]} = refs(~s|<a href="two">x</a>|)

    assert {:error, :invalid_occurrence} =
             Analysis.render(analysis, [Occurrence.bind(ref, :target)], fn _ -> {:local, "x"} end)
  end

  test "XML bases restore sibling context and are neutralized only during rendering" do
    source =
      ~s|<svg xml:base="/assets/"><g xml:base="inner/"><image href="one.png"/></g><image href="two.png"/></svg>|

    {analysis, refs} = refs(source, %{content_type: "image/svg+xml"})

    assert Enum.map(refs, & &1.url) == [
             "https://example.test/assets/inner/one.png",
             "https://example.test/assets/two.png"
           ]

    assert {:ok, output} = Analysis.render(analysis, refs, &Analysis.online_fallback/1)
    refute output =~ "xml:base"
    assert output =~ ~s|href="https://example.test/assets/inner/one.png"|

    assert {:ok, output} =
             Analysis.render(analysis, refs, &Analysis.online_fallback/1, neutralize_base: false)

    assert output =~ "xml:base"
  end

  test "analysis facts and import-map projection preserve strict plain and located agreement" do
    for text <- [
          ~s|{"imports":{"x":"./one.js"}}|,
          ~s|{"imports":{"x":"./one.js","x":"./two.js"}}|,
          "\uFEFF{}",
          ~s|{"scopes":{"/scope/":{"x":"./x.js"}}}|
        ] do
      assert {:ok, ast} = Crawler.ImportMap.JSON.decode_located(text)

      assert Crawler.ImportMap.from_located(ast, @opts.url) ==
               Crawler.ImportMap.parse(text, @opts.url)
    end
  end
end

defmodule Crawler.Analysis.CSSGroupsTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis
  alias Crawler.Analysis.Occurrence

  @opts %{
    url: "https://example.test/dir/page",
    referrer_url: "https://example.test/dir/page",
    content_type: "text/html",
    assets: ["css"]
  }

  defp analyze(source, opts \\ @opts) do
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    analysis
  end

  test "group sheets retain scanned imports, source order, and the first HTML base for all sheets" do
    source =
      ~s|<style>@import "early.css";</style><template><base href="/inert/"></template><base href="styles/"><style>@import url(late.css);</style><base href="/ignored/">|

    opts = Map.put(@opts, :style_group, {:opaque, :document})
    analysis = analyze(source, opts)
    assert {:ok, [group]} = Analysis.css_groups(analysis, opts)
    assert group.style_group == {:opaque, :document}
    assert group.source_revision == analysis.revision
    assert Enum.map(group.sheets, & &1.order) == [0, 2]

    assert Enum.map(group.sheets, & &1.base) ==
             List.duplicate("https://example.test/dir/styles/", 2)

    assert Enum.map(group.sheets, &hd(&1.imports).value) == ["early.css", "late.css"]

    for sheet <- group.sheets do
      assert sheet.imports ==
               Enum.filter(analysis.regions[sheet.id].facts.resources, &(&1.kind == :import))

      assert Enum.all?(
               sheet.bindings ++ sheet.uses ++ sheet.registrations,
               &(&1.sheet_id == sheet.id)
             )
    end

    assert {:ok, refs} = Analysis.occurrences(analysis, opts)
    assert Enum.map(refs, & &1.source_base) == Enum.map(group.sheets, & &1.base)

    assert Enum.map(refs, & &1.url) == [
             "https://example.test/dir/styles/early.css",
             "https://example.test/dir/styles/late.css"
           ]
  end

  test "XML bases apply per lexical scope and restore sibling sheet bases" do
    source =
      ~s|<svg xml:base="/root/"><style>@import "one.css";</style><g xml:base="inner/"><style>@import "two.css";</style></g><style>@import "three.css";</style></svg>|

    opts = Map.put(@opts, :content_type, "image/svg+xml")
    analysis = analyze(source, opts)
    assert {:ok, [group]} = Analysis.css_groups(analysis, opts)

    assert Enum.map(group.sheets, & &1.base) == [
             "https://example.test/root/",
             "https://example.test/root/inner/",
             "https://example.test/root/"
           ]

    assert {:ok, refs} = Analysis.occurrences(analysis, opts)
    assert Enum.map(refs, & &1.source_base) == Enum.map(group.sheets, & &1.base)
  end

  test "nested srcdoc groups preserve opaque isolation and their own HTML base" do
    child =
      ~s|<style>@import "before.css";</style><base href="/child/"><iframe srcdoc="&lt;style&gt;@import 'grand.css';&lt;/style&gt;"></iframe>|

    encoded = child |> String.replace("&", "&amp;") |> String.replace("'", "&#39;")

    source =
      ~s|<style>@import "outer.css";</style><base href="/outer/"><iframe srcdoc='#{encoded}'></iframe>|

    analysis = analyze(source)
    assert {:ok, [outer, inner, grand]} = Analysis.css_groups(analysis, @opts)
    assert outer.style_group == @opts.url

    assert inner.style_group ==
             {:srcdoc, @opts.url, "https://example.test/outer/", :crypto.hash(:sha256, child)}

    refute grand.style_group == inner.style_group

    assert Enum.map([outer, inner, grand], &hd(&1.sheets).base) == [
             "https://example.test/outer/",
             "https://example.test/child/",
             "https://example.test/child/"
           ]

    assert Enum.all?([outer, inner, grand], &(&1.source_revision == analysis.revision))
    assert {:ok, refs} = Analysis.occurrences(analysis, @opts)

    assert Enum.map(refs, & &1.source_base) ==
             Enum.map([outer, inner, grand], &hd(&1.sheets).base)
  end

  test "root CSS yields one source-relative group and non-CSS sources yield none" do
    opts = Map.merge(@opts, %{content_type: "text/css", style_group: {:opaque, :styles}})
    analysis = analyze(~s|@import "child.css"; .a{background:url(image.png)}|, opts)

    assert {:ok, [%{style_group: {:opaque, :styles}, sheets: [sheet]}]} =
             Analysis.css_groups(analysis, opts)

    assert sheet.id == analysis.root
    assert sheet.order == 0
    assert Enum.map(sheet.imports, & &1.value) == ["child.css"]
    assert {:ok, []} = Analysis.css_groups(analyze("<p>no styles</p>"), @opts)
    json_opts = Map.put(@opts, :fetch_kind, :manifest)
    assert {:ok, []} = Analysis.css_groups(analyze("{}", json_opts), json_opts)
  end

  test "disabled document CSS has no groups or occurrences across HTML, XML, and srcdoc" do
    html =
      ~s|<style>@import "outer.css";</style><div style="background:url(inline.png)"></div><iframe srcdoc='<style>@import "child.css";</style>'></iframe>|

    xml =
      ~s|<svg xmlns="http://www.w3.org/2000/svg"><style>@import "outer.css";</style><rect fill="url(paint.svg#x)"/></svg>|

    for {source, type} <- [{html, "text/html"}, {xml, "image/svg+xml"}] do
      opts = Map.merge(@opts, %{content_type: type, assets: []})
      analysis = analyze(source, opts)
      assert {:ok, []} = Analysis.css_groups(analysis, opts)
      assert {:ok, []} = Analysis.occurrences(analysis, opts)
    end
  end

  test "ineligible CSS attribute facts cannot enter document groups or variable settlement" do
    source =
      ~s|<div fill="--image:url(ignored.png)"></div><style>.x{background:var(--image)}</style>|

    analysis = analyze(source)
    assert map_size(Analysis.css_facts(analysis)) == 2
    assert {:ok, [%{sheets: [sheet]}]} = Analysis.css_groups(analysis, @opts)
    assert sheet.order == 1
    assert sheet.bindings == []
    assert {:ok, []} = Analysis.occurrences(analysis, @opts)
  end

  test "root stylesheet groups and occurrences remain enabled without document CSS assets" do
    opts = Map.merge(@opts, %{content_type: "text/css", assets: []})
    analysis = analyze(~s|@import "child.css";|, opts)
    assert {:ok, [%{sheets: [sheet]}]} = Analysis.css_groups(analysis, opts)
    assert sheet.id == analysis.root
    assert {:ok, [ref]} = Analysis.occurrences(analysis, opts)
    assert ref.region == sheet.id
    assert ref.url == "https://example.test/dir/child.css"
  end

  test "group projection shares the remaining aggregate lexical fact budget" do
    source =
      ~s|<style>@import "child.css"; :root{--image:url(image.png)}.a{background:var(--image)}</style>|

    initial = analyze(source)
    opts = Map.put(@opts, :max_facts, initial.budget.counts.facts)
    analysis = analyze(source, opts)
    assert {:error, {:limit, :lexical_facts}} = Analysis.css_groups(analysis, opts)
  end

  test "discovery-only foreign CSS tokens do not use the trigger's source bounds" do
    opts = Map.put(@opts, :content_type, "text/css")
    source = "/* trigger */"
    analysis = analyze(source, opts)
    foreign = %{value: "./foreign.png", start: 900, length: 42, quote: "", kind: :url}

    picture = %{
      token: foreign,
      token_sheet: :previous_sheet,
      token_base: "https://example.test/source.css",
      base_sheet: :use_sheet,
      base_url: "https://example.test/assets/use.css"
    }

    managed =
      Map.merge(opts, %{
        css_revision: :settled,
        css_tokens: %{analysis.root => []},
        css_references: %{analysis.root => [picture]}
      })

    assert {:ok, [ref]} = Analysis.occurrences(analysis, managed)
    assert ref.span == nil
    assert ref.metadata.css_picture == picture
    assert ref.url == "https://example.test/assets/foreign.png"

    assert {:ok, ^source} =
             Analysis.render(analysis, [Occurrence.bind(ref, :target)], fn _ ->
               {:local, "/saved/foreign.png"}
             end)

    assert {:error, :invalid_css_snapshot} =
             Analysis.occurrences(analysis, %{managed | css_tokens: %{analysis.root => [foreign]}})

    invalid = %{
      picture
      | token: %{foreign | value: String.duplicate("x", analysis.limits.max_bytes + 1)}
    }

    assert {:error, :invalid_css_snapshot} =
             Analysis.occurrences(analysis, %{
               managed
               | css_references: %{analysis.root => [invalid]}
             })
  end
end

defmodule Crawler.Analysis.FacadeContractTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis
  alias Crawler.Analysis.Occurrence

  @opts %{
    url: "http://example.com/dir/page",
    referrer_url: "http://example.com/dir/page",
    content_type: "text/html",
    assets: ["css", "images"]
  }

  test "first active relative HTML base applies before its source position exactly once" do
    source =
      ~s|<a href="early">early</a><template><base href="/wrong/"></template><base target="x"><base href="docs/"><base href="/ignored/"><a href="late">late</a>|

    assert {:ok, analysis} = Analysis.analyze(source, @opts)
    assert {:ok, refs} = Analysis.occurrences(analysis, @opts)

    assert Enum.map(refs, & &1.url) == [
             "http://example.com/dir/docs/early",
             "http://example.com/dir/docs/late"
           ]

    assert Enum.all?(
             refs,
             &(Occurrence.handler_options(&1, @opts).referrer_url ==
                 "http://example.com/dir/docs/")
           )
  end

  test "NBSP and repeated directory separators preserve the existing callback base contract" do
    for {base, expected_base, expected_url} <- [
          {"docs/\u00A0", "http://example.com/dir/docs/\u00A0", "http://example.com/dir/docs/x"},
          {"docs//", "http://example.com/dir/docs//", "http://example.com/dir/docs//x"}
        ] do
      source = "<a href='x'>x</a><base href='" <> base <> "'>"
      assert {:ok, analysis} = Analysis.analyze(source, @opts)
      assert {:ok, [ref]} = Analysis.occurrences(analysis, @opts)
      assert ref.url == expected_url
      assert Occurrence.handler_options(ref, @opts).referrer_url == expected_base
    end
  end

  test "inline CSS keeps its source tag in callback reference_tag" do
    source =
      ~s|<style>.a{background:url(style.png)}</style><div style="background:url(attr.png)"></div><svg><rect fill="url(paint.png)"/></svg>|

    assert {:ok, analysis} = Analysis.analyze(source, @opts)
    assert {:ok, refs} = Analysis.occurrences(analysis, @opts)

    assert Enum.map(refs, &{&1.value, &1.context.html_tag, &1.context.reference_tag}) == [
             {"style.png", "link", "style"},
             {"attr.png", "link", "div"},
             {"paint.png", "link", "rect"}
           ]
  end

  test "srcdoc callbacks keep their own base and drop parent response state" do
    source =
      ~s|<base href="/outer/"><iframe srcdoc='<a href="child">c</a><base href="/child/">'></iframe>|

    opts = Map.merge(@opts, %{headers: [{"x-robots-tag", "nofollow"}], robots_nofollow: true})
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, [ref]} = Analysis.occurrences(analysis, opts)
    callback = Occurrence.handler_options(ref, opts)
    assert callback.referrer_url == "http://example.com/child/"
    assert callback.content_type == "text/html"
    refute Map.has_key?(callback, :headers)
    refute Map.has_key?(callback, :robots_nofollow)
  end

  test "XML stylesheet PI MIME eligibility differs from style-element type eligibility" do
    source =
      ~s|<?xml-stylesheet type="text/css" href="theme.css"?><?xml-stylesheet type="text/css; charset=utf-8" href="param.css"?><?xml-stylesheet href="missing.css"?><?xml-stylesheet type="text/xsl" href="no.xsl"?><svg/>|

    opts = Map.merge(@opts, %{content_type: "image/svg+xml", style_group: {:document, @opts.url}})
    assert {:ok, analysis} = Analysis.analyze(source, opts)

    [before, after_refresh] =
      for revision <- [:before, :after] do
        current = Map.merge(opts, %{css_tokens: %{}, css_revision: revision})
        assert {:ok, refs} = Analysis.occurrences(analysis, current)
        assert Enum.map(refs, & &1.value) == ["theme.css", "param.css"]
        assert Enum.all?(refs, &(&1.context.reference_tag == "link"))

        for ref <- refs do
          assert ref.context.style_group == opts.style_group
          refute Map.has_key?(ref.context, :css_revision)
          callback = Occurrence.handler_options(ref, %{current | style_group: :wrong_parent})
          assert callback.style_group == opts.style_group
          refute Map.has_key?(callback, :css_revision)
        end

        refs
      end

    assert before === after_refresh
  end
end

defmodule Crawler.Analysis.SyntheticPictureAndXHTMLBaseTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Analysis.Limits
  alias Crawler.Analysis.Occurrence

  @opts %{
    url: "https://example.test/dir/page",
    referrer_url: "https://example.test/dir/page",
    content_type: "application/xhtml+xml",
    assets: ["css", "images"],
    respect_robots: false
  }

  test "synthetic CSS pictures project resolved callback values while source tokens keep raw values" do
    source = ~s|body{background:url("own.png")}|
    opts = Map.put(@opts, :content_type, "text/css")
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    token = %{value: "fallback.png", start: 900, length: 12, quote: "\"", kind: :url}

    picture = %{
      token: token,
      token_sheet: :prior,
      token_base: "https://example.test/tokens/tokens.css",
      base_sheet: :reader,
      base_url: "https://example.test/css/app.css"
    }

    opts =
      Map.merge(opts, %{
        css_tokens: %{analysis.root => []},
        css_references: %{analysis.root => [picture]},
        css_revision: :settled
      })

    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)
    assert [own, synthetic] = collection.occurrences

    assert Occurrence.handler_element(own) ==
             {"link", "own.png", "href", "https://example.test/dir/own.png"}

    assert Occurrence.handler_element(synthetic) ==
             {"href", "https://example.test/css/fallback.png"}

    assert own.span != nil
    assert synthetic.span == nil
    assert synthetic.value == "fallback.png"
    assert synthetic.url == "https://example.test/css/fallback.png"
    assert synthetic.metadata.css_picture == picture
    tagged_source = %{own | metadata: %{css_picture: picture}}
    assert Occurrence.handler_element(tagged_source) == Occurrence.handler_element(own)
    untagged = %{synthetic | metadata: %{}}
    assert Occurrence.handler_element(untagged) == {"link", "fallback.png", "href", synthetic.url}
    assert {:ok, ^source} = Analysis.render(analysis, collection, fn _ -> :keep end)
    assert {:ok, bound} = Analysis.bind(collection, fn _ -> :target end)

    assert {:ok, ~s|body{background:url("saved.png")}|} =
             Analysis.render(analysis, bound, fn _ -> {:local, "saved.png"} end)
  end

  test "first active XHTML base applies to links before and after it exactly once" do
    source =
      ~s|<html xmlns="http://www.w3.org/1999/xhtml"><a href="early"/><template><base href="/inert/"/></template><base target="x"/><base href="docs/"/><base href="/ignored/"/><a href="late"/></html>|

    assert {:ok, analysis} = Analysis.analyze(source, @opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, @opts)

    assert Enum.map(collection.occurrences, & &1.url) == [
             "https://example.test/dir/docs/early",
             "https://example.test/dir/docs/late"
           ]

    assert Enum.all?(
             collection.occurrences,
             &(Occurrence.handler_options(&1, @opts).referrer_url ==
                 "https://example.test/dir/docs/")
           )

    assert {:ok, output} = Analysis.render(analysis, collection, &Analysis.online_fallback/1)
    assert output =~ ~s|href="https://example.test/dir/docs/early"|
    assert {:ok, bound} = Analysis.bind(collection, fn _ -> :target end)

    assert {:ok, local} =
             Analysis.render(analysis, bound, fn ref -> {:local, "/saved/" <> ref.value} end,
               content_type: "image/svg+xml"
             )

    assert local =~ ~s|href="/saved/early"|
    assert local =~ ~s|<template><base href="/inert/"/></template>|
    refute local =~ ~s|href="docs/"|
    refute local =~ ~s|href="/ignored/"|

    expected =
      source
      |> String.replace(~s|href="early"|, ~s|href="/saved/early"|)
      |> String.replace(~s|href="late"|, ~s|href="/saved/late"|)
      |> String.replace(~s| href="docs/"|, "")
      |> String.replace(~s| href="/ignored/"|, "")

    assert local == expected
    assert analysis.regions[analysis.root].source == source

    fallback_source =
      ~s|<html><head><base href="https://example.test/xhtml/dir/"/></head><a href="intro"/></html>|

    assert {:ok, fallback_analysis} = Analysis.analyze(fallback_source, @opts)

    assert {:ok, %{occurrences: [intro]} = fallback_collection} =
             Analysis.occurrences_result(fallback_analysis, @opts)

    assert intro.url == "https://example.test/xhtml/dir/intro"

    assert {:ok, fallback_output} =
             Analysis.render(fallback_analysis, fallback_collection, &Analysis.online_fallback/1)

    refute fallback_output =~ ~s|base href=|
  end

  test "XHTML document base seeds scoped XML bases and stylesheet groups" do
    source =
      ~s|<html xmlns="http://www.w3.org/1999/xhtml" xml:base="scope/"><a href="root"/><base href="docs/"/><section xml:base="nested/"><a href="inner"/><style>.x{background:url(pic.png)}</style></section><a href="tail"/><section xml:base="/abs/"><a href="absolute"/></section></html>|

    assert {:ok, analysis} = Analysis.analyze(source, @opts)
    assert {:ok, groups} = Analysis.css_groups_result(analysis, @opts)
    [sheet] = hd(groups.groups).sheets
    assert sheet.base == "https://example.test/dir/docs/scope/nested/"

    opts =
      Map.merge(@opts, %{
        css_tokens: %{sheet.id => []},
        css_references: %{},
        css_revision: :settled
      })

    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts, groups)

    assert Enum.map(collection.occurrences, & &1.url) == [
             "https://example.test/dir/docs/scope/root",
             "https://example.test/dir/docs/scope/nested/inner",
             "https://example.test/dir/docs/scope/nested/pic.png",
             "https://example.test/dir/docs/scope/tail",
             "https://example.test/abs/absolute"
           ]

    assert collection.budget.limit == analysis.budget.limit
    assert collection.budget.caps == analysis.budget.caps
    assert collection.budget.retained > groups.budget.retained
    assert collection.budget.scratch == 0
  end

  test "SVG and generic XML do not select foreign XHTML base islands" do
    for type <- ["image/svg+xml", "application/xml"] do
      source =
        ~s|<s:svg xmlns:s="http://www.w3.org/2000/svg" xml:base="/scope/"><s:base href="/wrong-svg/"/><h:base xmlns:h="http://www.w3.org/1999/xhtml" href="/wrong-html/"/><s:image href="pic.png"/></s:svg>|

      opts = Map.put(@opts, :content_type, type)
      assert {:ok, analysis} = Analysis.analyze(source, opts)
      assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)
      assert Enum.map(collection.occurrences, & &1.url) == ["https://example.test/scope/pic.png"]

      assert {:ok, output} =
               Analysis.render(analysis, collection, &Analysis.online_fallback/1,
                 content_type: "application/xhtml+xml"
               )

      assert output =~ ~s|<h:base xmlns:h="http://www.w3.org/1999/xhtml" href="/wrong-html/"/>|
      assert output =~ ~s|<s:base href="/wrong-svg/"/>|
      refute output =~ "xml:base"
      assert analysis.regions[analysis.root].source == source
    end

    source =
      ~s|<html xmlns="http://www.w3.org/1999/xhtml"><svg xmlns="http://www.w3.org/2000/svg"><base href="/wrong/"/></svg><Base href="/wrong-case/"/><a href="next"/></html>|

    assert {:ok, analysis} = Analysis.analyze(source, @opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, @opts)
    assert Enum.map(collection.occurrences, & &1.url) == ["https://example.test/dir/next"]

    source =
      ~s|<html xml:base="scope/"><base href="javascript:ignored"/><base href="/later/"/><a href="next"/></html>|

    assert {:ok, analysis} = Analysis.analyze(source, @opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, @opts)
    assert Enum.map(collection.occurrences, & &1.url) == ["https://example.test/dir/scope/next"]
  end

  test "XHTML base selection shares one budget and performs one lexical scan" do
    source =
      ~s|<html xmlns="http://www.w3.org/1999/xhtml"><a href="early"/><base href="docs/"/><g xml:base="nested/"><a href="late"/></g></html>|

    assert {:ok, limits} = Limits.new(@opts)
    assert {:ok, seed} = Budget.charge(Budget.new(limits), 4096)

    calls = [
      {Crawler.XMLSpans, :analyze_result, 3},
      {Crawler.HTMLSpans, :tags_result, 3},
      {Crawler.XMLSpans, :resolve_bases_result, 3},
      {Budget, :new, 1}
    ]

    for call <- calls, do: :erlang.trace_pattern(call, true, [:call_count])

    try do
      assert {:ok, analysis} = Analysis.analyze(source, @opts, seed)
      assert {:ok, collection} = Analysis.occurrences_result(analysis, @opts)

      assert Enum.map(collection.occurrences, & &1.url) == [
               "https://example.test/dir/docs/early",
               "https://example.test/dir/docs/nested/late"
             ]

      assert {:ok, _output, stats} =
               Analysis.render_with_stats(analysis, collection, &Analysis.online_fallback/1)

      assert stats.budget.limit == seed.limit
      assert stats.budget.caps == seed.caps
      assert stats.budget.retained >= analysis.budget.retained
      assert analysis.budget.retained >= seed.retained
      assert stats.budget.scratch == 0

      assert {:call_count, 1} =
               :erlang.trace_info({Crawler.XMLSpans, :analyze_result, 3}, :call_count)

      assert {:call_count, 0} =
               :erlang.trace_info({Crawler.HTMLSpans, :tags_result, 3}, :call_count)

      assert {:call_count, 1} =
               :erlang.trace_info({Crawler.XMLSpans, :resolve_bases_result, 3}, :call_count)

      assert {:call_count, 1} = :erlang.trace_info({Budget, :new, 1}, :call_count)
      assert {:ok, full} = Budget.charge(analysis.budget, Budget.available(analysis.budget))
      continuation = %{source_revision: analysis.revision, budget: full}

      assert {:error, {:limit, :analysis_bytes}} =
               Analysis.occurrences_result(analysis, @opts, continuation)
    after
      for call <- calls, do: :erlang.trace_pattern(call, false, [:call_count])
    end
  end
end

defmodule Crawler.Analysis.CSSAttributeQuoteTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis

  @opts %{
    url: "https://example.test/dir/page",
    content_type: "text/html",
    assets: ["css", "images"],
    respect_robots: false
  }

  @quotes [
    {"\"", "\"", "\""},
    {"'", "'", "'"},
    {"&quot;", "&quot;", "&quot;"},
    {"&apos;", "&apos;", "&apos;"},
    {"&#0034;", "&#34;", "&#34;"},
    {"&#0039;", "&#39;", "&#39;"},
    {"&#X0022;", "&#x22;", "&#x22;"},
    {"&#X0027;", "&#x27;", "&#x27;"}
  ]

  test "quoted CSS attribute payloads preserve literal and canonical entity delimiters" do
    for {opening, closing, normalized} <- @quotes do
      outer = if opening == "\"", do: "'", else: "\""

      source =
        "<div data-note='keep &amp; a.png' style=" <>
          outer <>
          "background: URL( " <>
          opening <>
          "a.png" <>
          closing <>
          " ); background-image:image-set(" <>
          opening <> "a.png" <> closing <> " 1x); color:red" <> outer <> "></div>"

      assert {:ok, analysis} = Analysis.analyze(source, @opts)
      assert {:ok, collection} = Analysis.occurrences_result(analysis, @opts)

      assert {:ok, output, stats} =
               Analysis.render_with_stats(analysis, collection, &Analysis.online_fallback/1)

      expected =
        "<div data-note='keep &amp; a.png' style=" <>
          outer <>
          "background: URL( " <>
          normalized <>
          "https://example.test/dir/a.png" <>
          normalized <>
          " ); background-image:image-set(" <>
          normalized <>
          "https://example.test/dir/a.png" <>
          normalized <> " 1x); color:red" <> outer <> "></div>"

      assert output == expected
      assert stats.batches == 1
      assert stats.budget.scratch == 0
      assert stats.budget.caps == analysis.budget.caps
      assert analysis.regions[analysis.root].source == source
    end
  end

  test "data neighbours retain every byte while only the selected image changes" do
    for {opening, closing, normalized} <- Enum.drop(@quotes, 2) do
      double? = opening in ["&quot;", "&#0034;", "&#X0022;"]
      outer = if double?, do: "\"", else: "'"
      payload_quote = if double?, do: "'", else: "\""

      data =
        "data:text/css,body{background:url(" <> payload_quote <> "a.png" <> payload_quote <> ")}"

      source =
        "<div style=" <>
          outer <>
          "background:image-set(" <>
          opening <>
          data <>
          closing <> " 1x," <> opening <> "a.png" <> closing <> " 2x)" <> outer <> "></div>"

      assert {:ok, analysis} = Analysis.analyze(source, @opts)
      assert {:ok, collection} = Analysis.occurrences_result(analysis, @opts)
      assert Enum.map(collection.occurrences, & &1.value) == ["a.png"]
      assert {:ok, output} = Analysis.render(analysis, collection, &Analysis.online_fallback/1)

      expected =
        "<div style=" <>
          outer <>
          "background:image-set(" <>
          opening <>
          data <>
          closing <>
          " 1x," <>
          normalized <>
          "https://example.test/dir/a.png" <> normalized <> " 2x)" <> outer <> "></div>"

      assert output == expected
    end
  end

  test "source mapping remains safe across entity payloads, XML attributes and output collisions" do
    source =
      ~s|<div style='background:url("caf&#233;.png"),url("https://example.test/second")' data-style='url("caf&#233;.png")'></div>|

    assert {:ok, analysis} = Analysis.analyze(source, @opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, @opts)
    assert {:ok, bound} = Analysis.bind(collection, & &1.value)

    assert {:ok, output} =
             Analysis.render(analysis, bound, fn
               %{target: "café.png"} -> {:local, "https://example.test/second"}
               _ref -> {:local, "saved.png"}
             end)

    assert output ==
             ~s|<div style='background:url("https://example.test/second"),url("saved.png")' data-style='url("caf&#233;.png")'></div>|

    svg =
      ~s|<s:svg xmlns:s="http://www.w3.org/2000/svg"><s:rect fill="url(&apos;a.png&apos;)" /></s:svg>|

    opts = Map.put(@opts, :content_type, "image/svg+xml")
    assert {:ok, analysis} = Analysis.analyze(svg, opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)
    assert {:ok, output} = Analysis.render(analysis, collection, &Analysis.online_fallback/1)

    assert output ==
             ~s|<s:svg xmlns:s="http://www.w3.org/2000/svg"><s:rect fill="url(&apos;https://example.test/dir/a.png&apos;)" /></s:svg>|
  end

  test "injected CSS quotes remain inside the original attribute and quote edits obey limits" do
    source = ~s|<div style='background:url("a.png")' title="keep"></div>|
    assert {:ok, analysis} = Analysis.analyze(source, @opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, @opts)
    assert {:ok, bound} = Analysis.bind(collection, fn _ -> :target end)

    assert {:ok, output} =
             Analysis.render(analysis, bound, fn _ -> {:local, ~s|x"');color:red;/*|} end)

    [{"div", attrs, []}] = Floki.parse_fragment!(output)
    assert Enum.map(attrs, &elem(&1, 0)) == ["style", "title"]
    assert {"title", "keep"} in attrs
    assert {"style", style} = List.keyfind(attrs, "style", 0)

    assert [%{value: value}] =
             Crawler.Parser.CssParser.Scanner.analyze(style, mode: :declarations).resources

    assert value == ~s|x"');color:red;/*|
    [ref] = bound.occurrences
    invalid = %{bound | occurrences: [%{ref | span: {0, 1}}]}

    assert {:error, :invalid_css_quote_span} =
             Analysis.render(analysis, invalid, fn _ -> {:local, "safe.png"} end)

    opts = Map.put(@opts, :max_edits, 1)
    source = ~s|<div style="background:url(&#0039;a.png&#39;)"></div>|
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)

    assert {:error, {:limit, :edits}} =
             Analysis.render(analysis, collection, &Analysis.online_fallback/1)

    source = ~s|<div style="background:url(&apos;a.png&apos;)"></div>|
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)
    assert {:ok, output} = Analysis.render(analysis, collection, &Analysis.online_fallback/1)

    assert output ==
             ~s|<div style="background:url(&apos;https://example.test/dir/a.png&apos;)"></div>|
  end
end

defmodule Crawler.Analysis.RenderDocumentScopeTraceTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis
  alias Crawler.Analysis.Render

  @opts %{url: "https://example.test/page", content_type: "text/html", respect_robots: false}

  test "base-free documents are inspected once regardless of local selection count" do
    for count <- [32, 256] do
      source = anchors("root", count)
      assert {:ok, analysis} = Analysis.analyze(source, @opts)
      assert {:ok, collection} = Analysis.occurrences_result(analysis, @opts)
      assert length(collection.occurrences) == count
      assert {:ok, bound} = Analysis.bind(collection, fn _ -> :target end)

      inspect_bases(1, fn ->
        assert {:ok, ^source} = Analysis.render(analysis, bound, &{:local, &1.value})
      end)
    end
  end

  test "base presence and absence are cached separately for each nearest srcdoc document" do
    outer = anchors("outer", 64)
    first = anchors("first", 32)
    second = "<base href='/child/'>" <> anchors("second", 32)
    first_frame = ~s|<iframe srcdoc="#{escape(first)}"></iframe>|
    source = outer <> first_frame <> ~s|<iframe srcdoc="#{escape(second)}"></iframe>|
    assert {:ok, analysis} = Analysis.analyze(source, @opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, @opts)
    assert length(collection.occurrences) == 128
    assert {:ok, bound} = Analysis.bind(collection, fn _ -> :target end)

    inspect_bases(3, fn ->
      assert {:ok, output} = Analysis.render(analysis, bound, &{:local, &1.value})
      assert String.starts_with?(output, outer <> first_frame)
      assert output =~ "&lt;base&gt;"
      refute output =~ "'/child/'"
    end)
  end

  defp anchors(prefix, count) do
    Enum.map_join(1..count, fn index -> ~s|<a href='#{prefix}-#{index}.html'>N</a>| end)
  end

  defp escape(source), do: source |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")

  defp inspect_bases(expected, fun) do
    Code.ensure_loaded!(Render)
    call = {Render, :document_base?, 2}
    assert :erlang.trace_pattern(call, true, [:local, :call_count]) == 1

    try do
      fun.()
      assert {:call_count, ^expected} = :erlang.trace_info(call, :call_count)
    after
      :erlang.trace_pattern(call, false, [:local, :call_count])
    end
  end
end

defmodule Crawler.Analysis.SrcdocBaseDependencyTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Analysis.Render
  alias Crawler.URL

  @opts %{url: "https://origin.test/page", content_type: "text/html", respect_robots: false}
  @saved "https://saved.test/archive/page.html"
  @base ~s|<base href="https://origin.test/assets/">|
  @local ~s|<a href="next.html">N</a>|

  test "outer local selection preserves the exact reported inherited child destination" do
    source =
      ~s|<base href="https://origin.test/assets/"><a href="next.html">N</a><iframe srcdoc="&lt;a href='keep.html'&gt;K&lt;/a&gt;"></iframe>|

    {analysis, bound, opts} = prepare(source)
    assert [_, %{url: "https://origin.test/assets/keep.html"}] = bound.occurrences
    assert {:ok, output} = Analysis.render(analysis, bound, &outer_local/1)

    assert Enum.map(saved_refs(output, opts), & &1.url) == [
             "https://saved.test/archive/next.html",
             "https://origin.test/assets/keep.html"
           ]

    assert analysis.regions[analysis.root].source == source

    assert {:ok, ^source} =
             Analysis.render(analysis, bound, &outer_local/1, neutralize_base: false)
  end

  test "two nested inherited children preserve destinations transitively" do
    child = ~s|<a href="child.html">C</a>| <> frame(~s|<a href="grand.html">G</a>|)
    source = @base <> @local <> frame(child)
    {analysis, bound, opts} = prepare(source)
    assert {:ok, output} = Analysis.render(analysis, bound, &outer_local/1)

    assert Enum.map(saved_refs(output, opts), & &1.url) == [
             "https://saved.test/archive/next.html",
             "https://origin.test/assets/child.html",
             "https://origin.test/assets/grand.html"
           ]
  end

  test "first canonical child base governs relative root protocol fragment empty and invalid cases" do
    for raw <- [
          "nested/",
          "../up/",
          "/root/",
          "//cdn.test/path/",
          "#part",
          "",
          "javascript:ignored",
          "https://invalid.test:bad/"
        ] do
      child = ~s|<base href="#{raw}"><base href="https://ignored.test/"><a href="keep.html">K</a>|
      source = ~s|<base href="http://other.test/assets/">| <> @local <> frame(child)
      {analysis, bound, opts} = prepare(source)
      [_, kept] = bound.occurrences
      assert {:ok, output} = Analysis.render(analysis, bound, &outer_local/1)
      [local, rewritten] = saved_refs(output, opts)
      assert local.url == "https://saved.test/archive/next.html"
      assert rewritten.url == kept.url, "child base #{inspect(raw)} changed its kept destination"
      [after_child] = frame_sources(output)
      assert after_child =~ ~s|<base href="#{raw}"><base href="https://ignored.test/">|
    end
  end

  test "an absolute canonical child base isolates its complete subtree byte for byte" do
    for raw <- [
          "https://independent.test/assets/",
          " HTTP://independent.test/assets/ ",
          "https://user:secret@independent.test/assets/"
        ] do
      child =
        ~s|<base href="#{raw}"><a href="keep.html">K</a>| <> frame(~s|<a href="grand.html">G</a>|)

      source = @base <> @local <> frame(child)
      {analysis, bound, opts} = prepare(source)
      assert {:ok, output} = Analysis.render(analysis, bound, &outer_local/1)
      assert output == String.replace(source, @base, "<base>", global: false)
      [_, kept, grand] = bound.occurrences
      [_, rewritten, nested] = saved_refs(output, opts)
      assert rewritten.url == kept.url
      assert nested.url == grand.url
    end
  end

  test "inner local selections clear exposed ancestor bases while independent siblings stay exact" do
    sibling = frame(~s|<base href="https://independent.test/"><a href="sibling.html">S</a>|)

    for child_base <- ["", ~s|<base href="relative/">|, ~s|<base href="https://child.test/">|] do
      source =
        @base <>
          ~s|<a href="outer-keep.html">O</a>| <>
          frame(child_base <> ~s|<a href="local.html">L</a><a href="child-keep.html">K</a>|) <>
          sibling

      {analysis, bound, opts} = prepare(source)

      assert {:ok, output} =
               Analysis.render(analysis, bound, fn ref ->
                 if ref.value == "local.html", do: {:local, "local.html"}, else: :keep
               end)

      assert output =~ sibling
      [outer, _local, child, independent] = bound.occurrences

      assert Enum.map(saved_refs(output, opts), & &1.url) == [
               outer.url,
               "https://saved.test/archive/local.html",
               child.url,
               independent.url
             ]
    end
  end

  test "mixed local online keep and fragment targets retain safe destinations and source escaping" do
    child =
      ~s|<a data-note="keep &amp; bytes" href="keep.html?x=1&amp;y=2#part">K</a><a href="online.html">O</a>|

    source = ~s|<base href="http://user:secret@other.test/assets/">| <> @local <> frame(child)
    {analysis, bound, opts} = prepare(source)
    [_, kept, online] = bound.occurrences
    assert {:ok, safe_kept} = Render.safe_online(kept.url)
    assert {:ok, safe_online} = Render.safe_online(online.url)

    assert {:ok, output} =
             Analysis.render(analysis, bound, fn ref ->
               case ref.value do
                 "next.html" -> {:local, "next.html"}
                 "online.html" -> {:online, ref.url}
                 _value -> :keep
               end
             end)

    [local, rewritten, online] = saved_refs(output, opts)
    assert local.url == "https://saved.test/archive/next.html"
    assert rewritten.url == safe_kept
    assert rewritten.fragment == "part"
    assert online.url == safe_online
    refute output =~ "secret"
    [after_child] = frame_sources(output)
    assert after_child =~ ~s|data-note="keep &amp; bytes"|
    assert after_child =~ ~s|href="http://other.test/assets/keep.html?x&#61;1&amp;y&#61;2#part"|
  end

  test "changed online selections do not propagate local intent into ancestor documents" do
    child = ~s|<base href="child/"><a href="online.html">O</a><a href="keep.html">K</a>|
    source = @base <> ~s|<a href="outer.html">A</a>| <> frame(child)
    {analysis, bound, opts} = prepare(source)

    assert {:ok, output} =
             Analysis.render(analysis, bound, fn ref ->
               if ref.value == "online.html", do: {:online, ref.url}, else: :keep
             end)

    assert String.starts_with?(output, @base <> ~s|<a href="outer.html">A</a>|)
    assert Enum.map(saved_refs(output, opts), & &1.url) == Enum.map(bound.occurrences, & &1.url)
  end

  test "XHTML canonical bases and XML scoped ancestors feed srcdoc dependencies" do
    opts = %{content_type: "application/xhtml+xml"}

    for foreign <- [~s|q:href="https://wrong.test/"|, ~s|HREF="https://wrong.test/"|] do
      source =
        ~s|<html xmlns="http://www.w3.org/1999/xhtml" xmlns:q="urn:foreign"><base #{foreign}/><base href="/assets/"/><a href="next.html"/>| <>
          frame(~s|<BASE HREF='relative/'><a href='keep.html'>K</a>|, true) <> "</html>"

      {analysis, bound, current} = prepare(source, opts)
      assert {:ok, output} = Analysis.render(analysis, bound, &outer_local/1)
      assert output =~ foreign
      [_, kept] = bound.occurrences
      [_, rewritten] = saved_refs(output, current)
      assert rewritten.url == kept.url
    end

    source =
      ~s|<html xmlns="http://www.w3.org/1999/xhtml" xml:base="/root/"><a href="next.html"/><section xml:base="nested/">| <>
        frame(~s|<a href='keep.html'>K</a>|, true) <> "</section></html>"

    {analysis, bound, current} = prepare(source, opts)
    assert [_, %{url: "https://origin.test/root/nested/keep.html"}] = bound.occurrences
    assert {:ok, output} = Analysis.render(analysis, bound, &outer_local/1)

    assert Enum.map(saved_refs(output, current), & &1.url) == [
             "https://saved.test/archive/next.html",
             "https://origin.test/root/nested/keep.html"
           ]
  end

  test "document and dependency inspections are bounded independently of occurrence count" do
    for count <- [32, 256] do
      inherited =
        anchors("inherited", count) <> frame(~s|<base href="grand/"><a href="grand.html">G</a>|)

      relative = ~s|<base href="child/">| <> anchors("relative", count)
      independent = ~s|<base href="https://independent.test/">| <> anchors("independent", count)
      source = @base <> @local <> frame(inherited) <> frame(relative) <> frame(independent)
      {analysis, bound, _opts} = prepare(source)

      calls = [
        {{Render, :document_graph, 5}, map_size(analysis.regions)},
        {{Render, :document_base?, 2}, 1},
        {{Render, :document_dependency, 5}, 5},
        {{Render, :inherited_document, 2}, 4},
        {{URL, :resolve_result, 3}, 3},
        {{Budget, :new, 1}, 0}
      ]

      for {call, _expected} <- calls, do: :erlang.trace_pattern(call, true, [:local, :call_count])

      try do
        assert {:ok, _output} = Analysis.render(analysis, bound, &outer_local/1)

        for {call, expected} <- calls do
          assert {:call_count, ^expected} = :erlang.trace_info(call, :call_count)
        end
      after
        for {call, _expected} <- calls,
            do: :erlang.trace_pattern(call, false, [:local, :call_count])
      end
    end
  end

  test "base dependency compensation obeys existing edit and output limits" do
    source = @base <> @local <> frame(~s|<a href="keep.html">K</a>|)
    {analysis, bound, _opts} = prepare(source, %{max_edits: 1})
    assert {:error, {:limit, :edits}} = Analysis.render(analysis, bound, &outer_local/1)
    {analysis, bound, _opts} = prepare(source)
    assert {:ok, output} = Analysis.render(analysis, bound, &outer_local/1)
    {analysis, bound, _opts} = prepare(source, %{max_output_bytes: byte_size(output)})
    assert {:ok, ^output} = Analysis.render(analysis, bound, &outer_local/1)
    {analysis, bound, _opts} = prepare(source, %{max_output_bytes: byte_size(output) - 1})
    assert {:error, {:limit, :rendered_bytes}} = Analysis.render(analysis, bound, &outer_local/1)
  end

  test "a consumed continuing budget stops before graph or dependency inspection" do
    source = @base <> @local <> frame(~s|<base href="child/"><a href="keep.html">K</a>|)
    {analysis, bound, _opts} = prepare(source)
    assert {:ok, full} = Budget.charge(bound.budget, Budget.available(bound.budget))
    blocked = %{bound | budget: full}

    calls = [
      {Render, :document_graph, 5},
      {Render, :inherited_document, 2},
      {URL, :resolve_result, 3},
      {Budget, :new, 1}
    ]

    for call <- calls, do: :erlang.trace_pattern(call, true, [:local, :call_count])

    try do
      assert {:error, {:limit, :analysis_bytes}} =
               Analysis.render(analysis, blocked, &outer_local/1)

      for call <- calls, do: assert({:call_count, 0} == :erlang.trace_info(call, :call_count))
    after
      for call <- calls, do: :erlang.trace_pattern(call, false, [:local, :call_count])
    end
  end

  defp prepare(source, changes \\ %{}) do
    opts = Map.merge(@opts, changes)
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, refs} = Analysis.occurrences_result(analysis, opts)
    assert {:ok, bound} = Analysis.bind(refs, fn _ -> :target end)
    {analysis, bound, opts}
  end

  defp saved_refs(output, opts) do
    opts = Map.merge(opts, %{url: @saved, referrer_url: @saved})
    assert {:ok, analysis} = Analysis.analyze(output, opts)
    assert {:ok, refs} = Analysis.occurrences(analysis, opts)
    refs
  end

  defp outer_local(%{value: "next.html"}), do: {:local, "next.html"}
  defp outer_local(_ref), do: :keep

  defp frame(source, xml? \\ false) do
    ending = if xml?, do: "/>", else: "></iframe>"
    ~s|<iframe srcdoc="#{escape(source)}"#{ending}|
  end

  defp escape(source) do
    source
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp frame_sources(source) do
    source
    |> Floki.parse_fragment!()
    |> Floki.find("iframe")
    |> Enum.map(fn {_tag, attrs, _children} -> attrs |> List.keyfind("srcdoc", 0) |> elem(1) end)
  end

  defp anchors(prefix, count),
    do: Enum.map_join(1..count, fn index -> ~s|<a href="#{prefix}-#{index}.html">N</a>| end)
end
