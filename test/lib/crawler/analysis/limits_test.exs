defmodule Crawler.Analysis.LimitsTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis

  test "empty, invalid UTF8 and incompatible lexical source metadata return explicit outcomes" do
    assert {:ok, analysis} = Analysis.analyze("", content_type: "text/html")
    assert {:ok, []} = Analysis.occurrences(analysis)
    assert {:ok, ""} = Analysis.render(analysis, [], fn _ -> :keep end)
    assert {:error, :invalid_utf8} = Analysis.analyze(<<255>>)
    assert {:error, :invalid_headers} = Analysis.analyze("", headers: :invalid)

    assert {:error, :incompatible_source_options} =
             Analysis.occurrences(analysis, content_type: "image/svg+xml")

    assert {:error, :incompatible_source_options} =
             Analysis.occurrences(analysis, headers: [{"link", "changed"}])

    assert {:ok, []} = Analysis.occurrences(analysis, content_type: "text/html;charset=utf-8")
  end

  test "zero source bytes accepts empty input while all other supplied budgets remain positive" do
    limits = %{
      max_bytes: 0,
      max_total_bytes: 20_000_000,
      max_output_bytes: 20_000_000,
      max_regions: 2,
      max_depth: 3,
      max_facts: 4,
      max_occurrences: 5,
      max_edits: 6
    }

    assert {:ok, normalized} = Crawler.Analysis.Limits.new(limits)
    assert Map.take(normalized, Map.keys(limits)) == limits

    assert Map.take(normalized, [:max_xml_depth, :max_xml_tokens, :max_xml_attributes]) ==
             Map.take(Crawler.Limits.defaults(), [
               :max_xml_depth,
               :max_xml_tokens,
               :max_xml_attributes
             ])

    assert {:ok, analysis} = Analysis.analyze("", limits)
    assert analysis.limits == normalized
    assert {:ok, []} = Analysis.occurrences(analysis)
    assert {:ok, ""} = Analysis.render(analysis, [], fn _ -> :keep end)
    assert {:error, {:limit, :source_bytes}} = Analysis.analyze("x", limits)

    assert {:ok, _analysis} =
             Analysis.analyze("", Map.merge(limits, %{headers: [{"content-type", "text/html"}]}))

    assert {:ok, _analysis} =
             Analysis.analyze("", Map.put(limits, :content_type, "image/svg+xml"))

    for value <- [-1, 0.0] do
      assert {:error, :invalid_limits} = Crawler.Analysis.Limits.new(%{limits | max_bytes: value})
    end

    for key <- Map.keys(limits) -- [:max_bytes] do
      assert {:error, :invalid_limits} = Crawler.Analysis.Limits.new(Map.put(limits, key, 0))
    end
  end

  test "region depth, aggregate bytes and XML element depth are distinct finite limits" do
    assert {:error, {:limit, :source_depth}} =
             Analysis.analyze(~s|<iframe srcdoc="&lt;a href='x'&gt;"></iframe>|, max_depth: 1)

    assert {:error, {:limit, :analysis_bytes}} =
             Analysis.analyze(~s|<a href="long">x</a>|, max_total_bytes: 20)

    xml = String.duplicate("<g>", 257) <> String.duplicate("</g>", 257)
    assert {:error, {:limit, :xml_depth}} = Analysis.analyze(xml, content_type: "image/svg+xml")

    assert {:error, {:limit, :header_bytes}} =
             Analysis.analyze("",
               headers: [{"link", String.duplicate("a", 6)}],
               max_total_bytes: 5
             )
  end

  test "configured XML element limits exceed reader defaults independently of source regions" do
    normalized = Crawler.Limits.validate!(%{max_xml_depth: 300, max_xml_attributes: 2000})

    opts =
      normalized
      |> Map.merge(Crawler.Limits.analysis(normalized))
      |> Map.put(:content_type, "application/xml")

    for {source, key, lower, reason} <- [
          {String.duplicate("<g>", 257) <> String.duplicate("</g>", 257), :max_xml_depth, 256,
           :xml_depth},
          {"<g " <> Enum.map_join(1..1025, " ", &~s|a#{&1}="x"|) <> "/>", :max_xml_attributes,
           1024, :xml_attributes}
        ] do
      assert {:ok, analysis} = Analysis.analyze(source, opts)
      assert analysis.stats.regions == 1
      assert analysis.limits.max_depth == 16
      assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)

      assert {:ok, document, continued} =
               Crawler.Sitemap.Document.from_analysis(analysis, collection, opts)

      assert {:ok, native} = Crawler.Sitemap.Document.parse(source, "", opts)
      assert document.stats.max_depth == native.stats.max_depth
      assert document.stats.max_attributes == native.stats.max_attributes
      assert continued.budget.retained >= collection.budget.retained
      assert {:error, {:limit, ^reason}} = Analysis.analyze(source, Map.put(opts, key, lower))
    end

    for key <- [:max_xml_depth, :max_xml_tokens, :max_xml_attributes], value <- [0, -1, 1.0] do
      assert {:error, :invalid_limits} = Analysis.analyze("<g/>", Map.put(opts, key, value))
    end
  end

  test "XML tokens and allocation facts enforce independent counters before document projection" do
    source = "<urlset><url><loc>https://example.test/page</loc></url></urlset>"

    normalized = Crawler.Limits.validate!(%{})

    opts =
      normalized
      |> Map.merge(Crawler.Limits.analysis(normalized))
      |> Map.put(:content_type, "application/xml")

    assert {:error, {:limit, :xml_tokens}} =
             Analysis.analyze(source, Map.put(opts, :max_xml_tokens, 2))

    assert {:error, {:limit, :lexical_facts}} =
             Analysis.analyze(source, Map.put(opts, :max_facts, 2))

    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)

    assert {:error, {:limit, :max_xml_tokens}} =
             Crawler.Sitemap.Document.from_analysis(
               analysis,
               collection,
               Map.put(opts, :max_xml_tokens, 2)
             )

    assert {:ok, document, _collection} =
             Crawler.Sitemap.Document.from_analysis(analysis, collection, opts)

    assert length(document.entries) == 1
  end

  test "identical source locations under different resolution bases have distinct occurrence identities" do
    assert {:ok, analysis} = Analysis.analyze(~s|<a href="next">x</a>|, content_type: "text/html")
    assert {:ok, [one]} = Analysis.occurrences(analysis, %{url: "https://example.test/a/page"})
    assert {:ok, [two]} = Analysis.occurrences(analysis, %{url: "https://example.test/b/page"})
    refute one.id == two.id
    assert one.source_base == "https://example.test/a/page"
    assert two.source_base == "https://example.test/b/page"
    assert one.namespace == :html
    assert one.document_base == "https://example.test/a/page"
  end

  test "source-map response headers are part of lexical revision identity" do
    assert {:ok, one} =
             Analysis.analyze("export{};",
               content_type: "text/javascript",
               headers: [{"sourcemap", "one.map"}]
             )

    assert {:ok, two} =
             Analysis.analyze("export{};",
               content_type: "text/javascript",
               headers: [{"sourcemap", "two.map"}]
             )

    refute one.revision == two.revision
  end
end

defmodule Crawler.Analysis.LexicalReuseTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis

  test "document style facts and import-map JSON are not rescanned during interpretation or render" do
    source =
      ~s|<style>:root{--image:url(image.png)}</style><style>.a{background:var(--image)}</style><script type="importmap">{"imports":{"lib":"./lib.js"}}</script><script type="module">import "lib";</script>|

    opts = %{content_type: "text/html", url: "https://example.test/page", assets: ["css", "js"]}

    calls = [
      {Crawler.Parser.CssParser.Scanner, :analyze_result, 3},
      {Crawler.ImportMap.JSON, :decode_located_result, 2}
    ]

    for call <- calls, do: :erlang.trace_pattern(call, true, [:call_count])

    try do
      assert {:ok, analysis} = Analysis.analyze(source, opts)

      for _ <- 1..5 do
        assert {:ok, refs} = Analysis.occurrences(analysis, opts)
        assert {:ok, _output} = Analysis.render(analysis, refs, &Analysis.online_fallback/1)
      end

      assert {:call_count, 2} = :erlang.trace_info(hd(calls), :call_count)
      assert {:call_count, 1} = :erlang.trace_info(List.last(calls), :call_count)
    after
      for call <- calls, do: :erlang.trace_pattern(call, false, [:call_count])
    end
  end

  test "invalid data source maps are not parsed again during repeated interpretation" do
    source = ~S|//# sourceMappingURL=data:application/json,{"version":3,"sources":["bad\q"]}|
    opts = %{content_type: "text/javascript", url: "https://example.test/app.js"}
    call = {Crawler.ImportMap.JSON, :decode_located_result, 2}
    :erlang.trace_pattern(call, true, [:call_count])

    try do
      assert {:ok, analysis} = Analysis.analyze(source, opts)
      for _ <- 1..5, do: assert({:ok, []} = Analysis.occurrences(analysis, opts))
      assert {:call_count, 1} = :erlang.trace_info(call, :call_count)
    after
      :erlang.trace_pattern(call, false, [:call_count])
    end
  end
end

defmodule Crawler.Analysis.CSSGroupProjectionTraceTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis

  test "group projection invokes no scanner, graph, or state owner" do
    source =
      ~s|<style>@import "one.css"; :root{--x:url(image.png)}</style><base href="/styles/"><iframe srcdoc='<style>@import "child.css";</style>'></iframe>|

    opts = %{url: "https://example.test/page", content_type: "text/html", assets: ["css"]}
    assert {:ok, analysis} = Analysis.analyze(source, opts)

    calls = [
      {Crawler.HTMLSpans, :tags, 2},
      {Crawler.XMLSpans, :analyze, 2},
      {Crawler.Parser.CssParser.Scanner, :analyze_result, 3},
      {Crawler.Parser.CssParser.Variables, :analyze, 3},
      {Crawler.Parser.CssParser.VariableGraph, :run, 3},
      {Crawler.Parser.CssParser.DocumentStyles, :from_sheets, 2},
      {Crawler.Parser.CssSheets, :remember, 3},
      {Crawler.Parser.CssSheets, :take_urls, 3}
    ]

    for {module, _fun, _arity} <- calls, do: Code.ensure_loaded!(module)
    for call <- calls, do: :erlang.trace_pattern(call, true, [:call_count])

    try do
      for _ <- 1..5 do
        assert {:ok, [outer, child]} = Analysis.css_groups(analysis, opts)
        assert hd(outer.sheets).base == "https://example.test/styles/"
        assert hd(child.sheets).imports != []
        disabled = Map.put(opts, :assets, [])
        assert {:ok, []} = Analysis.css_groups(analysis, disabled)
        assert {:ok, []} = Analysis.occurrences(analysis, disabled)
      end

      for call <- calls, do: assert({:call_count, 0} = :erlang.trace_info(call, :call_count))
    after
      for call <- calls, do: :erlang.trace_pattern(call, false, [:call_count])
    end
  end
end

defmodule Crawler.Analysis.SharedBudgetTest do
  use ExUnit.Case, async: false
  alias Crawler.Analysis
  alias Crawler.Analysis.Budget

  @opts %{
    url: "https://example.test/page",
    content_type: "text/html",
    assets: [],
    respect_robots: false
  }

  test "semantic import-map recovery preserves cumulative work and inherited authority" do
    invalid = ~s|<script type="importmap">{"imports":{"x":"./x.js"},"scopes":null}</script>|
    opts = Map.merge(@opts, %{assets: ["js"], max_facts: 27})
    assert {:ok, analysis} = Analysis.analyze(invalid <> invalid, opts)
    assert analysis.budget.counts.facts == 26
    assert {:error, {:limit, :lexical_facts}} = Analysis.occurrences_result(analysis, opts)

    assert {:error, {:limit, :source_regions}} =
             Analysis.analyze(invalid <> invalid, Map.put(opts, :max_regions, 2))

    opts = Map.merge(opts, %{max_facts: 100, max_regions: 20})
    {:ok, limits} = Crawler.Analysis.Limits.new(opts)
    opts = Map.merge(opts, limits)
    {:ok, seed} = Budget.charge(Budget.new(limits), 4096, facts: 2, regions: 1)
    assert {:ok, analysis} = Analysis.analyze(invalid <> invalid, opts, seed)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)
    assert collection.occurrences == []
    assert collection.budget.counts.facts == analysis.budget.counts.facts + 2
    assert collection.budget.counts.regions == analysis.budget.counts.regions
    assert collection.budget.retained >= analysis.budget.retained
    assert collection.budget.scratch == seed.scratch
    assert collection.budget.peak >= analysis.budget.peak
    assert analysis.regions[analysis.root].source == invalid <> invalid
    assert {:ok, cached} = Analysis.cached_result(analysis, opts, seed)
    assert {:ok, replayed} = Analysis.occurrences_result(cached, opts)
    assert replayed.budget.counts == collection.budget.counts

    assert {:ok, consumed} =
             Budget.count(
               seed,
               :facts,
               opts.max_facts - seed.counts.facts - analysis.allocation.counts.facts - 1
             )

    assert {:ok, cached} = Analysis.cached_result(analysis, opts, consumed)
    assert {:error, {:limit, :lexical_facts}} = Analysis.occurrences_result(cached, opts)
  end

  test "valid import maps survive semantic failures between them" do
    invalid = ~s|<script type="importmap">{"imports":{"x":"./ignored.js"},"scopes":null}</script>|

    source =
      ~s|<script type="importmap">{"imports":{"x":"./valid.js"}}</script>| <>
        invalid <>
        ~s|<script type="module">import "x";</script>|

    opts = Map.merge(@opts, %{assets: ["js"]})
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)
    assert Enum.any?(collection.occurrences, &(&1.url == "https://example.test/valid.js"))
    refute Enum.any?(collection.occurrences, &(&1.url == "https://example.test/ignored.js"))
    assert collection.budget.counts.facts > analysis.budget.counts.facts
  end

  test "root body backing is distinct while allocated lexical footprint is inherited" do
    source = String.duplicate("plain text ", 1_000)
    assert {:ok, analysis} = Analysis.analyze(source, max_total_bytes: 8_192)
    assert analysis.stats.bytes > analysis.budget.limit
    assert analysis.budget.retained < byte_size(source)
    assert {:ok, refs} = Analysis.occurrences_result(analysis, @opts)
    assert refs.budget.retained >= analysis.budget.retained
    assert refs.budget.scratch == 0
    assert {:ok, ^source} = Analysis.render(analysis, refs, fn _ -> :keep end)
  end

  test "explicit decoder seed carries converted root backing without resetting authority" do
    opts = Map.put(@opts, :max_total_bytes, 16_384)
    assert {:ok, limits} = Crawler.Analysis.Limits.new(opts)
    fresh = Budget.new(limits)
    assert {:ok, seed} = Budget.charge(fresh, 4_096, facts: 2)
    assert {:ok, plain} = Analysis.analyze("plain text", opts)
    assert {:ok, decoded} = Analysis.analyze("plain text", opts, seed)
    assert decoded.budget.retained == plain.budget.retained + seed.retained
    assert decoded.budget.counts.facts == plain.budget.counts.facts + 2
    assert decoded.revision == plain.revision
    assert {:ok, collection} = Analysis.occurrences_result(decoded, opts)
    assert collection.budget.retained >= decoded.budget.retained

    assert {:ok, "plain text", stats} =
             Analysis.render_with_stats(decoded, collection, fn _ -> :keep end)

    assert stats.budget.retained >= seed.retained
    assert {:ok, full} = Budget.charge(fresh, fresh.limit)
    assert {:error, {:limit, :analysis_bytes}} = Analysis.analyze("", opts, full)

    for invalid <- [
          Budget.unlimited(),
          %{seed | scratch: 1},
          %{seed | retained: -1},
          %{seed | peak: 0},
          %{seed | counts: %{seed.counts | facts: -1}},
          %{seed | counts: %{seed.counts | facts: limits.max_facts + 1}},
          %{seed | caps: %{seed.caps | facts: 1}},
          nil
        ] do
      assert {:error, :invalid_budget_continuation} = Analysis.analyze("", opts, invalid)
    end
  end

  test "ignored malformed script JSON retains every attempted fact and source region" do
    for type <- ["importmap", "speculationrules"] do
      source = String.duplicate(~s|<script type="#{type}">[0,0,0,0,]</script>|, 2)

      assert {:error, {:limit, :lexical_facts}} =
               Analysis.analyze(source, Map.put(@opts, :max_facts, 10))

      assert {:error, {:limit, :source_regions}} =
               Analysis.analyze(source, Map.put(@opts, :max_regions, 2))

      assert {:ok, analysis} = Analysis.analyze(source, @opts)
      assert analysis.budget.counts.facts == 16
      assert analysis.budget.counts.regions == 3
      assert analysis.stats.regions == 1
      assert map_size(analysis.regions) == 1
      assert analysis.regions[analysis.root].children == []
      assert {:ok, []} = Analysis.occurrences(analysis, @opts)
    end
  end

  test "failed JSON lifetimes release only child storage while parent scratch and peak survive" do
    opts = @opts
    assert {:ok, limits} = Crawler.Analysis.Limits.new(opts)
    assert {:ok, seed} = Budget.charge(Budget.new(limits), 4096, facts: 2, regions: 1)
    assert {:ok, seed} = Budget.reserve(seed, 700)
    small = ~s|<script type="importmap">["x",]</script>|
    large = ~s|<script type="importmap">["| <> String.duplicate("x", 10_000) <> ~s|",]</script>|

    assert {:ok, _root, small_regions, _stats, small_budget} =
             Crawler.Analysis.Lexical.run(small, opts, limits, seed)

    assert {:ok, _root, large_regions, _stats, large_budget} =
             Crawler.Analysis.Lexical.run(large, opts, limits, seed)

    assert map_size(small_regions) == 1
    assert map_size(large_regions) == 1
    assert large_budget.retained == small_budget.retained
    assert large_budget.scratch == seed.scratch
    assert small_budget.scratch == seed.scratch
    assert large_budget.peak > small_budget.peak
    assert large_budget.counts == small_budget.counts
    assert large_budget.counts.regions == seed.counts.regions + 2
    assert large_budget.counts.facts > seed.counts.facts
    assert large_budget.caps == seed.caps
  end

  test "valid and invalid JSON interleave without rescans or renewed budgets" do
    source =
      ~s|<script type="importmap">[0,0,0,0,]</script><script type="importmap">{"imports":{"lib":"./lib.js"}}</script><script type="speculationrules">[0,0,0,0,]</script><script type="module">import "lib";</script>|

    opts = Map.put(@opts, :assets, ["js"])
    calls = [{Crawler.ImportMap.JSON, :decode_located_result, 2}, {Budget, :new, 1}]
    for call <- calls, do: :erlang.trace_pattern(call, true, [:call_count])

    try do
      assert {:ok, analysis} = Analysis.analyze(source, opts)
      assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)
      assert Enum.map(collection.occurrences, & &1.url) == ["https://example.test/lib.js"]
      assert {:ok, output} = Analysis.render(analysis, collection, &Analysis.online_fallback/1)
      assert output =~ ~s|[0,0,0,0,]|
      assert analysis.budget.counts.regions == analysis.stats.regions + 2

      assert {:call_count, 3} =
               :erlang.trace_info(
                 {Crawler.ImportMap.JSON, :decode_located_result, 2},
                 :call_count
               )

      assert {:call_count, 1} = :erlang.trace_info({Budget, :new, 1}, :call_count)
    after
      for call <- calls, do: :erlang.trace_pattern(call, false, [:call_count])
    end
  end

  test "ignored data maps preserve region attempts and cumulative facts in CSS and JavaScript" do
    data = Crawler.Parser.SourceMap.encode_data("[0,0,0,0,]", "data:application/json", :percent)

    for {type, source} <- [
          {"text/javascript",
           "//# sourceMappingURL=" <> data <> "\n//# sourceMappingURL=" <> data},
          {"text/css",
           "/*# sourceMappingURL=" <> data <> " */\n/*# sourceMappingURL=" <> data <> " */"}
        ] do
      opts = Map.put(@opts, :content_type, type)
      assert {:ok, analysis} = Analysis.analyze(source, opts)
      assert analysis.budget.counts.regions == 3
      assert analysis.stats.regions == 1
      assert analysis.budget.scratch == 0
      assert map_size(analysis.regions) == 1

      assert {:error, {:limit, :source_regions}} =
               Analysis.analyze(source, Map.put(opts, :max_regions, 2))

      assert {:error, {:limit, :lexical_facts}} =
               Analysis.analyze(
                 source,
                 Map.put(opts, :max_facts, analysis.budget.counts.facts - 1)
               )
    end
  end

  test "valid data-map regions keep their identities between discarded attempts" do
    bad = Crawler.Parser.SourceMap.encode_data("[0,0,0,0,]", "data:application/json", :percent)

    good =
      Crawler.Parser.SourceMap.encode_data(
        ~s|{"version":3,"sources":["original.js"]}|,
        "data:application/json",
        :percent
      )

    opts = Map.put(@opts, :content_type, "text/javascript")

    for {maps, urls} <- [
          {[bad, good, bad], []},
          {[bad, bad, good], ["https://example.test/original.js"]}
        ] do
      source = Enum.map_join(maps, "\n", &("//# sourceMappingURL=" <> &1))
      assert {:ok, analysis} = Analysis.analyze(source, opts)
      assert analysis.budget.counts.regions == 4
      assert analysis.stats.regions == 2
      assert Enum.sort(Map.keys(analysis.regions)) == [0, 1]
      assert analysis.regions[analysis.root].children == [1]
      assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)
      assert Enum.map(collection.occurrences, & &1.url) == urls
      assert {:ok, output} = Analysis.render(analysis, collection, &Analysis.online_fallback/1)
      assert output =~ bad
      if urls == [], do: assert(output == source)
      assert collection.budget.scratch == 0
    end
  end

  test "standalone malformed data maps recover the latest ledger from the pre-decode floor" do
    note = %{
      url: Crawler.Parser.SourceMap.encode_data("[0,0,0,0,]", "data:application/json", :percent),
      base: @opts.url
    }

    assert {:ok, limits} = Crawler.Analysis.Limits.new(%{max_facts: 14})
    assert {:ok, seed} = Budget.charge(Budget.new(limits), 4096, facts: 2)
    assert {:ok, seed} = Budget.reserve(seed, 700)
    assert {:ok, [], first} = Crawler.Parser.SourceMap.data_source_refs_result(note, @opts, seed)
    assert first.retained == seed.retained
    assert first.scratch == seed.scratch
    assert first.counts.facts == 8
    assert first.peak > seed.peak

    assert {:ok, :parent_value, second} =
             Crawler.Parser.SourceMap.reduce_data_source_refs(
               note,
               @opts,
               first,
               :parent_value,
               fn _, _, _ -> flunk("invalid JSON emitted a source reference") end
             )

    assert second.retained == seed.retained
    assert second.scratch == seed.scratch
    assert second.counts.facts == 14
    assert second.peak >= first.peak

    assert {:error, {:limit, :lexical_facts}} =
             Crawler.Parser.SourceMap.data_source_refs_result(note, @opts, second)

    assert {:ok, roomy} =
             Budget.charge(Budget.new(Map.put(limits, :max_facts, 1000)), 4096, facts: 2)

    assert {:ok, roomy} = Budget.reserve(roomy, 700)

    assert {:ok, [], recovered} =
             Crawler.Parser.SourceMap.data_source_refs_result(note, @opts, roomy)

    valid = %{
      note
      | url:
          Crawler.Parser.SourceMap.encode_data(
            ~s|{"version":3,"sources":["original.js"]}|,
            "data:application/json",
            :percent
          )
    }

    assert {:ok, [ref], continued} =
             Crawler.Parser.SourceMap.data_source_refs_result(valid, @opts, recovered)

    assert ref.url == "https://example.test/original.js"
    assert continued.counts.facts > recovered.counts.facts
    assert continued.retained > recovered.retained
    assert continued.scratch == roomy.scratch
    assert continued.peak >= recovered.peak

    invalid = %{
      note
      | url:
          Crawler.Parser.SourceMap.encode_data(
            String.duplicate("[", 129),
            "data:application/json",
            :percent
          )
    }

    assert {:error, {:limit, {:json, :max_depth}}} =
             Crawler.Parser.SourceMap.data_source_refs_result(
               invalid,
               @opts,
               Budget.new(Map.put(limits, :max_facts, 1000))
             )
  end

  test "cache replay includes discarded child work and preserves consumed seed credit" do
    opts = Map.merge(@opts, %{max_facts: 20, max_regions: 8})
    assert {:ok, limits} = Crawler.Analysis.Limits.new(opts)
    opts = Map.merge(opts, limits)
    assert {:ok, seed} = Budget.charge(Budget.new(limits), 4096, facts: 2, regions: 1)
    source = String.duplicate(~s|<script type="importmap">[0,0,0,0,]</script>|, 2)
    assert {:ok, analysis} = Analysis.analyze(source, opts, seed)
    assert analysis.allocation.counts.facts == 16
    assert analysis.allocation.counts.regions == 3
    assert analysis.budget.retained >= seed.retained
    assert {:ok, adopted} = Analysis.cached_result(analysis, opts, seed)
    assert adopted.budget.counts == analysis.budget.counts
    assert adopted.budget.peak >= seed.peak
    assert {:ok, fuller} = Budget.count(seed, :facts, 3)
    assert {:error, {:limit, :lexical_facts}} = Analysis.cached_result(analysis, opts, fuller)
    assert {:ok, fuller} = Budget.count(seed, :regions, 5)
    assert {:error, {:limit, :source_regions}} = Analysis.cached_result(analysis, opts, fuller)
  end

  test "CSS projection, snapshot adoption, occurrences, binding and render retain one allowance" do
    opts = %{@opts | assets: ["css"]}
    source = ~s|<style>@import "one.css";</style>|
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, projection} = Analysis.css_groups_result(analysis, opts)
    [sheet] = hd(projection.groups).sheets
    managed = Map.merge(opts, %{css_tokens: %{sheet.id => []}, css_revision: :settled})
    assert {:ok, collection} = Analysis.occurrences_result(analysis, managed, projection)
    assert collection.budget.retained > projection.budget.retained
    assert collection.budget.counts.occurrences == 1
    assert collection.budget.scratch == 0
    assert {:ok, bound} = Analysis.bind(collection, fn _ -> {:target, 1} end)
    assert bound.source_revision == analysis.revision
    assert bound.budget.retained > collection.budget.retained
    assert bound.budget.counts == collection.budget.counts

    assert {:ok, output, stats} =
             Analysis.render_with_stats(analysis, bound, fn _ -> {:local, "saved.css"} end)

    assert output =~ "saved.css"
    assert stats.budget.retained >= bound.budget.retained
    assert stats.budget.scratch == 0
    assert stats.budget.peak <= bound.budget.limit
  end

  test "continuations reject reset, changed caps, foreign revision and unlimited authority" do
    assert {:ok, analysis} = Analysis.analyze(~s|<a href="x">|, @opts)
    assert {:ok, projection} = Analysis.css_groups_result(analysis, @opts)

    for invalid <- [
          %{projection | source_revision: <<0>>},
          %{projection | budget: Budget.unlimited()},
          %{projection | budget: %{projection.budget | retained: 0}},
          %{
            projection
            | budget: %{projection.budget | caps: %{projection.budget.caps | facts: 1_000_000}}
          },
          %{projection | budget: %{projection.budget | counts: []}}
        ] do
      assert {:error, :invalid_budget_continuation} =
               Analysis.occurrences_result(analysis, @opts, invalid)
    end

    assert {:ok, collection} =
             Analysis.occurrences_result(
               analysis,
               Map.put(@opts, :analysis_budget, Budget.unlimited())
             )

    assert collection.budget.limit == analysis.budget.limit
  end

  test "derived URLs and metadata can exhaust bytes after lexical input fits" do
    source = ~s|{"icons":[| <> Enum.map_join(1..200, ",", fn _ -> ~s|{"src":"x"}| end) <> "]}"

    opts = %{
      url: "https://example.test/dir/site.webmanifest",
      content_type: "application/json",
      fetch_kind: :manifest,
      assets: ["images"]
    }

    assert {:ok, initial} = Analysis.analyze(source, opts)
    opts = Map.put(opts, :max_total_bytes, initial.budget.peak + 100_000)
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:error, {:limit, :analysis_bytes}} = Analysis.occurrences_result(analysis, opts)

    assert {:error, {:limit, :analysis_bytes}} =
             Analysis.occurrences_result(
               analysis,
               Map.put(opts, :analysis_budget, Budget.unlimited())
             )
  end

  test "attributes, srcset and JSON facts all consume the aggregate caller quota" do
    html = "<div " <> Enum.map_join(1..20, " ", &"data-#{&1}='x'") <> "></div>"
    srcset = "<img srcset='" <> Enum.map_join(1..20, ", ", &"x #{&1}x") <> "'>"
    json = "[" <> Enum.map_join(1..20, ",", &Integer.to_string/1) <> "]"
    assert {:error, {:limit, :lexical_facts}} = Analysis.analyze(html, max_facts: 2)
    assert {:error, {:limit, :lexical_facts}} = Analysis.analyze(srcset, max_facts: 8)

    assert {:error, {:limit, :lexical_facts}} =
             Analysis.analyze(json, fetch_kind: :manifest, max_facts: 2)
  end

  test "ineligible manifest images do not consume potential occurrence slots" do
    opts = %{
      url: "https://example.test/site.webmanifest",
      content_type: "application/json",
      fetch_kind: :manifest,
      assets: [],
      max_occurrences: 1
    }

    assert {:ok, analysis} =
             Analysis.analyze(~s|{"start_url":"home","icons":[{"src":"ignored.png"}]}|, opts)

    assert {:ok, %{occurrences: [ref]}} = Analysis.occurrences_result(analysis, opts)
    assert ref.url == "https://example.test/home"
  end

  test "role projections reject an exhausted occurrence slot before any URL resolver call" do
    b =
      Budget.new(%{
        max_total_bytes: 1_000_000,
        max_facts: 1_000,
        max_regions: 100,
        max_occurrences: 1,
        max_edits: 100
      })

    assert {:ok, b} = Budget.count(b, :occurrences)
    {:ok, manifest} = Crawler.ImportMap.JSON.decode_located(~s|{"start_url":"x"}|)
    {:ok, rules} = Crawler.ImportMap.JSON.decode_located(~s|{"prefetch":[{"urls":["x"]}]}|)
    {:ok, map} = Crawler.ImportMap.JSON.decode_located(~s|{"version":3,"sources":["x"]}|)
    resolver = {Crawler.URL, :resolve_result, 3}
    :erlang.trace_pattern(resolver, true, [:call_count])

    try do
      emit = fn _entry, acc, budget -> {:ok, acc, budget} end

      assert {:error, {:limit, :occurrences}} =
               Crawler.Parser.WebManifest.reduce_located(manifest, @opts.url, b, [], emit)

      assert {:error, {:limit, :occurrences}} =
               Crawler.Parser.SpeculationRules.reduce_located(rules, @opts, b, [], emit)

      assert {:error, {:limit, :occurrences}} =
               Crawler.Parser.SourceMap.reduce_located(map, @opts, b, [], emit)

      assert {:call_count, 0} = :erlang.trace_info(resolver, :call_count)
    after
      :erlang.trace_pattern(resolver, false, [:call_count])
    end
  end
end

defmodule BudgetKernelTest do
  use ExUnit.Case, async: true
  alias Crawler.Analysis.Budget

  defp budget do
    Budget.new(%{
      max_total_bytes: 100,
      max_facts: 2,
      max_regions: 1,
      max_occurrences: 2,
      max_edits: 2
    })
  end

  test "retained and scratch share one allowance and settle without double allocation" do
    assert {:ok, b} = Budget.charge(budget(), 30, facts: 1)
    assert {:ok, b} = Budget.reserve(b, 70)
    assert b.peak == 100
    assert {:error, {:limit, :analysis_bytes}} = Budget.charge(b, 1)
    assert {:ok, b} = Budget.settle(b, 70, 40)
    assert b.retained == 70 and b.scratch == 0 and b.peak == 100
    assert {:ok, b} = Budget.refund(b, 40)
    assert b.retained == 30 and b.counts.facts == 1
  end

  test "nested reservations release independently and cannot settle more than reserved" do
    assert {:ok, b} = Budget.reserve(budget(), 20)
    assert {:ok, b} = Budget.reserve(b, 30)
    assert {:ok, b} = Budget.settle(b, 30, 10)
    assert {:ok, b} = Budget.release(b, 20)
    assert b.retained == 10 and b.scratch == 0
    assert {:error, :invalid_budget_charge} = Budget.settle(b, 1, 1)
    assert {:error, :invalid_budget_charge} = Budget.refund(b, 11)
  end

  test "counter errors precede byte errors and failed charges leave original immutable" do
    b = budget()
    assert {:error, {:limit, :lexical_facts}} = Budget.charge(b, 101, facts: 3)
    assert b.retained == 0 and b.counts.facts == 0

    for {key, cap, error} <- [
          {:regions, 1, :source_regions},
          {:occurrences, 2, :occurrences},
          {:edits, 2, :edits}
        ] do
      assert {:ok, counted} = Budget.count(b, key, cap)
      assert {:error, {:limit, ^error}} = Budget.count(counted, key)
    end
  end

  test "unlimited wrappers use the same operations and reject accounting underflow" do
    assert {:ok, b} = Budget.charge(Budget.unlimited(), 1_000_000, facts: 1_000_000)
    assert Budget.available(b) == :infinity
    assert {:error, :invalid_budget_charge} = Budget.charge(b, -1)
    assert {:error, :invalid_budget_charge} = Budget.count(b, :unknown)
    assert Budget.cost(:attribute) > Budget.cost(:list_cell)
  end
end

defmodule Crawler.Analysis.CachedAllocationTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Analysis.Limits

  @base %{
    url: "https://example.test/dir/page",
    content_type: "text/html",
    assets: ["css", "js", "images"],
    respect_robots: false
  }

  defp options(changes \\ %{}) do
    assert {:ok, limits} = Limits.new(%{})
    Map.merge(Map.merge(@base, limits), changes)
  end

  defp key(opts) do
    assert {:ok, limits} = Limits.new(opts)
    assert {:ok, key, budget} = Analysis.lexical_key_result(opts, Budget.new(limits))
    assert budget.limit == limits.max_total_bytes
    assert budget.scratch == 0
    key
  end

  test "canonical keys separate source modes and exact JS goals but share JSON roles" do
    opts = options()

    assert key(opts) ==
             key(
               Map.merge(opts, %{
                 content_type: "Text/Html; charset=utf-8",
                 url: "https://other.test/",
                 css_revision: :later,
                 style_group: :other
               })
             )

    refute key(opts) == key(%{opts | content_type: "application/xhtml+xml"})

    refute key(%{opts | content_type: "application/xhtml+xml"}) ==
             key(%{opts | content_type: "image/svg+xml"})

    refute key(%{opts | content_type: "image/svg+xml"}) ==
             key(%{opts | content_type: "application/xml"})

    assert {{:css, :stylesheet}, "text/css", []} = key(%{opts | content_type: "text/css"})
    js = Map.put(opts, :content_type, "application/javascript")
    assert key(js) == key(%{js | content_type: "text/javascript; charset=utf-8"})
    assert key(js) == key(Map.put(js, :javascript_goal, :module))
    refute key(js) == key(Map.put(js, :javascript_goal, :script))
    json = Map.put(opts, :content_type, "application/json")

    [first | rest] =
      for role <- [:manifest, :speculation_rules, :source_map],
          do: key(Map.put(json, :fetch_kind, role))

    assert Enum.all?(rest, &(&1 == first))
    refute key(opts) == key(Map.put(opts, :headers, [{"link", "<x>; rel=stylesheet"}]))

    assert {:error, :invalid_script_goal} =
             Analysis.lexical_key_result(
               Map.put(js, :javascript_goal, :invalid),
               Budget.new(opts)
             )

    assert {:error, :invalid_headers} =
             Analysis.lexical_key_result(Map.put(opts, :headers, :invalid), Budget.new(opts))
  end

  test "cached facts adopt only lexical allocation into the funded decoded-root seed" do
    opts = options()
    source = String.duplicate("plain text ", 100)

    assert {:ok, seed} =
             Budget.charge(Budget.new(opts), byte_size(source) + Budget.cost(:binary), facts: 2)

    assert {:ok, cached} = Analysis.analyze(source, opts, seed)
    assert cached.allocation.retained == cached.budget.retained - seed.retained
    assert {:ok, current} = Budget.charge(seed, 1024, facts: 3)
    assert {:ok, _key, key_budget} = Analysis.lexical_key_result(opts, current)
    assert {:ok, rebound} = Analysis.cached_result(cached, opts, current)
    assert rebound.regions == cached.regions
    assert rebound.revision == cached.revision

    assert rebound.budget.retained ==
             key_budget.retained + cached.allocation.retained + Budget.cost(:context)

    for {key, count} <- cached.allocation.counts do
      assert rebound.budget.counts[key] == current.counts[key] + count
    end

    assert rebound.budget.limit == current.limit
    assert rebound.budget.caps == current.caps
    assert rebound.budget.scratch == 0
    assert {:ok, projection} = Analysis.css_groups_result(rebound, opts)
    assert {:ok, collection} = Analysis.occurrences_result(rebound, opts, projection)

    assert {:ok, ^source, stats} =
             Analysis.render_with_stats(rebound, collection, fn _ -> :keep end)

    assert stats.budget.retained >= rebound.budget.retained
    assert stats.budget.retained >= seed.retained
    assert stats.budget.caps == seed.caps
  end

  test "every stricter normalized numeric limit fails explicitly without rescanning" do
    opts = options()
    assert {:ok, cached} = Analysis.analyze("plain", opts)

    calls = [
      {Crawler.HTMLSpans, :tags_result, 3},
      {Crawler.XMLSpans, :analyze_result, 3},
      {Crawler.Parser.JsParser.Scanner, :scan_result, 3},
      {Crawler.Parser.CssParser.Scanner, :analyze_result, 3},
      {Crawler.ImportMap.JSON, :decode_located_result, 2}
    ]

    for call <- calls, do: :erlang.trace_pattern(call, true, [:call_count])

    try do
      for {key, value} <- cached.limits do
        stronger = Map.put(opts, key, value - 1)

        assert {:error, {:limit, {:cached_analysis, ^key}}} =
                 Analysis.cached_result(cached, stronger, Budget.new(stronger))
      end

      for call <- calls, do: assert({:call_count, 0} = :erlang.trace_info(call, :call_count))
    after
      for call <- calls, do: :erlang.trace_pattern(call, false, [:call_count])
    end
  end

  test "XML cache proof keeps all reader limits without changing identity or rescanning" do
    opts =
      options(%{
        content_type: "application/xml",
        max_xml_depth: 300,
        max_xml_attributes: 2000,
        max_xml_tokens: 2000
      })

    source = "<urlset><url><loc>https://example.test/page</loc></url></urlset>"
    fresh = Budget.new(opts)
    assert {:ok, seed} = Budget.charge(fresh, 4096, facts: 2)
    assert {:ok, seed} = Budget.reserve(seed, 8192)
    assert {:ok, seed} = Budget.release(seed, 8192)
    assert {:ok, plain} = Analysis.analyze(source, opts)
    assert {:ok, cached} = Analysis.analyze(source, opts, seed)
    assert cached.budget.retained == plain.budget.retained + seed.retained
    assert cached.budget.counts.facts == plain.budget.counts.facts + seed.counts.facts
    assert cached.allocation.seed == seed
    assert cached.budget.caps == seed.caps

    calls = [
      {Crawler.XMLSpans, :analyze_result, 3},
      {Budget, :new, 1},
      {Crawler.URL, :resolve_result, 3}
    ]

    for call <- calls, do: :erlang.trace_pattern(call, true, [:call_count])

    try do
      assert {:ok, rebound} = Analysis.cached_result(cached, opts, seed)
      assert rebound.regions == cached.regions
      assert rebound.budget.counts == cached.budget.counts
      assert rebound.budget.retained > seed.retained + cached.allocation.retained
      assert rebound.budget.peak >= seed.peak
      assert rebound.budget.scratch == 0
      assert {:call_count, 2} = :erlang.trace_info({Budget, :new, 1}, :call_count)

      assert {:call_count, 0} =
               :erlang.trace_info({Crawler.XMLSpans, :analyze_result, 3}, :call_count)

      assert {:call_count, 0} = :erlang.trace_info({Crawler.URL, :resolve_result, 3}, :call_count)

      for key <- [:max_xml_depth, :max_xml_attributes, :max_xml_tokens] do
        stricter = Map.update!(opts, key, &(&1 - 1))

        assert {:error, {:limit, {:cached_analysis, ^key}}} =
                 Analysis.cached_result(cached, stricter, seed)

        assert {:error, :invalid_limits} =
                 Analysis.cached_result(cached, Map.delete(opts, key), seed)
      end
    after
      for call <- calls, do: :erlang.trace_pattern(call, false, [:call_count])
    end

    for key <- [:max_xml_depth, :max_xml_attributes, :max_xml_tokens] do
      invalid = %{cached | limits: Map.delete(cached.limits, key)}
      assert {:error, :invalid_cached_analysis} = Analysis.cached_result(invalid, opts, seed)
    end

    raised = Map.update!(opts, :max_xml_depth, &(&1 + 1))
    assert {:ok, same} = Analysis.analyze(source, raised, seed)
    assert same.revision == cached.revision
    assert same.lexical_key == cached.lexical_key
    assert {:ok, adopted} = Analysis.cached_result(cached, raised, seed)
    assert adopted.revision == cached.revision

    assert {:error, {:limit, {:cached_analysis, :max_xml_depth}}} =
             Analysis.cached_result(same, opts, seed)
  end

  test "larger current limits replace cached caps without resetting current allocations" do
    opts = options()
    assert {:ok, cached} = Analysis.analyze("plain", opts)
    larger = Map.merge(opts, Map.new(cached.limits, fn {key, value} -> {key, value + 1000} end))
    assert {:ok, seed} = Budget.charge(Budget.new(larger), 2048, facts: 5)
    assert {:ok, rebound} = Analysis.cached_result(cached, larger, seed)
    assert rebound.limits == Map.take(larger, Map.keys(cached.limits))
    assert rebound.budget.limit == larger.max_total_bytes
    assert rebound.budget.caps == seed.caps
    assert rebound.budget.counts.facts == seed.counts.facts + cached.allocation.counts.facts
    assert rebound.budget.retained > seed.retained + cached.allocation.retained
    assert cached.budget.limit == opts.max_total_bytes
  end

  test "cache adoption rejects reset lineage, incompatible modes and invalid capsules" do
    opts = options()
    assert {:ok, seed} = Budget.charge(Budget.new(opts), 4096, facts: 2)
    assert {:ok, seed} = Budget.reserve(seed, 8192)
    assert {:ok, seed} = Budget.release(seed, 8192)
    assert {:ok, cached} = Analysis.analyze("plain", opts, seed)

    for invalid <- [
          Budget.new(opts),
          Budget.unlimited(),
          %{seed | scratch: 1},
          %{seed | peak: seed.retained},
          %{seed | counts: %{seed.counts | facts: 1}},
          %{seed | caps: %{seed.caps | facts: 1}}
        ] do
      assert {:error, :invalid_budget_continuation} =
               Analysis.cached_result(cached, opts, invalid)
    end

    assert {:error, :incompatible_source_options} =
             Analysis.cached_result(cached, %{opts | content_type: "application/xhtml+xml"}, seed)

    assert {:error, :incompatible_source_options} =
             Analysis.cached_result(
               cached,
               Map.put(opts, :headers, [{"link", "different"}]),
               seed
             )

    assert {:error, :invalid_limits} =
             Analysis.cached_result(cached, Map.drop(opts, [:max_facts]), seed)

    assert {:error, :invalid_cached_analysis} =
             Analysis.cached_result(%{cached | allocation: nil}, opts, seed)

    invalid = %{
      cached
      | allocation: %{cached.allocation | retained: cached.allocation.retained - 1}
    }

    assert {:error, :invalid_cached_analysis} = Analysis.cached_result(invalid, opts, seed)
    assert {:ok, full} = Budget.charge(seed, Budget.available(seed))
    assert {:error, {:limit, :analysis_bytes}} = Analysis.cached_result(cached, opts, full)
  end

  test "cached allocation preserves narrower cumulative counter failures" do
    opts = options(%{max_facts: 20, max_regions: 20})
    assert {:ok, cached} = Analysis.analyze(~s|<a href="next">go</a>|, opts)

    for {counter, cap, reason} <- [
          {:facts, opts.max_facts, :lexical_facts},
          {:regions, opts.max_regions, :source_regions}
        ] do
      assert {:ok, seed} = Budget.count(Budget.new(opts), counter, cap)
      assert {:error, {:limit, ^reason}} = Analysis.cached_result(cached, opts, seed)
    end
  end

  test "JSON role orders and JavaScript cache hits use existing facts with zero scans" do
    calls = [
      {Crawler.ImportMap.JSON, :decode_located_result, 2},
      {Crawler.Parser.JsParser.Scanner, :scan_result, 3}
    ]

    source =
      ~s|{"version":3,"icons":[{"src":"icon.png"}],"prefetch":[{"urls":["next"]}],"sources":["source.ts"]}|

    for roles <- [
          [:manifest, :speculation_rules, :source_map],
          [:source_map, :speculation_rules, :manifest]
        ] do
      opts = options(%{content_type: "application/json", fetch_kind: hd(roles)})
      seed = Budget.new(opts)
      assert {:ok, cached} = Analysis.analyze(source, opts, seed)
      for call <- calls, do: :erlang.trace_pattern(call, true, [:call_count])

      try do
        for role <- roles do
          current = %{opts | fetch_kind: role}
          assert {:ok, rebound} = Analysis.cached_result(cached, current, seed)
          assert rebound.regions == cached.regions
          assert rebound.revision == cached.revision
          assert {:ok, collection} = Analysis.occurrences_result(rebound, current)

          expected = %{
            manifest: ["https://example.test/dir/icon.png"],
            speculation_rules: ["https://example.test/dir/next"],
            source_map: ["https://example.test/dir/source.ts"]
          }

          assert Enum.map(collection.occurrences, & &1.url) == expected[role]
        end

        for call <- calls, do: assert({:call_count, 0} = :erlang.trace_info(call, :call_count))
      after
        for call <- calls, do: :erlang.trace_pattern(call, false, [:call_count])
      end
    end

    opts = options(%{content_type: "application/javascript", javascript_goal: :script})
    assert {:ok, cached} = Analysis.analyze(~s|import("./next.js");|, opts)
    seed = Budget.new(opts)
    for call <- calls, do: :erlang.trace_pattern(call, true, [:call_count])

    try do
      assert {:ok, rebound} = Analysis.cached_result(cached, opts, seed)
      assert {:ok, %{occurrences: [_ref]}} = Analysis.occurrences_result(rebound, opts)

      assert {:error, :incompatible_source_options} =
               Analysis.cached_result(cached, %{opts | javascript_goal: :module}, seed)

      for call <- calls, do: assert({:call_count, 0} = :erlang.trace_info(call, :call_count))
    after
      for call <- calls, do: :erlang.trace_pattern(call, false, [:call_count])
    end
  end
end
