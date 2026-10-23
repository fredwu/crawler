defmodule Crawler.Sitemap.DocumentAnalysisTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Deadline
  alias Crawler.Sitemap.Document

  @base "https://example.test/maps/root.xml"
  @limits %{
    max_body: 10_485_760,
    max_control_entries: 50_000,
    max_control_token_bytes: 65_536,
    max_xml_depth: 256,
    max_xml_tokens: 100_000,
    max_xml_attributes: 1_024,
    max_analysis_bytes: 20_000_000
  }

  defp opts(overrides \\ %{}),
    do: Map.merge(@limits, Map.merge(%{url: @base}, overrides))

  defp analyze(body, overrides \\ %{}) do
    opts = opts(overrides)

    assert {:ok, analysis} =
             Analysis.analyze(body, %{
               content_type: "application/xml",
               max_bytes: opts.max_body,
               max_total_bytes: opts.max_analysis_bytes
             })

    analysis
  end

  defp collection(analysis) do
    assert {:ok, budget} = Budget.charge(analysis.budget, 1_024, occurrences: 1)

    %{
      occurrences: [%{url: "https://kept.test/page"}],
      source_revision: analysis.revision,
      budget: budget,
      caller_metadata: :preserved
    }
  end

  defp semantic(document), do: Map.take(document, [:kind, :entries, :span_source])

  test "the same semantic reducer preserves canonical catalogue and feed entries" do
    bodies = [
      ~s(<urlset xmlns:i="urn:image" xmlns:x="http://www.w3.org/1999/xhtml"><url><loc>/a?a=1&amp;b=2</loc><i:image><i:loc>cover.jpg</i:loc></i:image><x:link rel="alternate" href="/translated"/></url></urlset>),
      ~s(<sitemapindex xml:base="/maps/"><sitemap><loc>one.xml</loc></sitemap><sitemap><loc>two.xml</loc></sitemap></sitemapindex>),
      ~s(<a:feed xmlns:a="http://www.w3.org/2005/Atom" xml:base="/blog/"><a:entry xml:base="news/"><a:link xml:base="../posts/" href="one?a=1&amp;b=2"/></a:entry></a:feed>),
      ~s(<feed xml:base="/blog/"><entry xml:base="javascript:bad"><link href="one"/></entry><entry xml:base="https://bad.test:broken/"><link href="two"/></entry><entry><link href="three"/></entry></feed>),
      ~s(<rss xmlns:m="urn:media"><channel><link>https://example.test/channel</link><item><link>/post</link><enclosure url="https://cdn.test/a.mp3"/><m:content url="https://cdn.test/a.mp4"><m:thumbnail url="https://cdn.test/a.jpg"/></m:content></item></channel></rss>),
      ~s(<rss><channel><item><guid>https://example.test/a</guid></item><item><guid isPermaLink="false">https://example.test/skip</guid></item><item><guid>/relative</guid><link>/post</link></item></channel></rss>),
      ~s(<r:rdf xmlns:r="urn:rdf" xmlns:s="urn:rss"><s:item><s:link>/rdf-post</s:link></s:item></r:rdf>),
      ~s(<urlset><url><loc> https://example.test/a<![CDATA[&amp;]]><!-- discard -->b&amp;c<?note ignored?>d </loc></url></urlset>),
      ~s(<feed><entry><content src="/full"><p>A &lt; B</p><link href="/hidden"/></content><link href="/after"/></entry></feed>),
      ~s(<rss><channel><item><description><a href="/hidden">x</a><loc><b/></loc></description><link>/kept</link></item></channel></rss>),
      ~s(<feed><entry><link href="/post"><b/></link><link rel="self" href="/self"/><link rel="enclosure" href="/asset"/></entry></feed>),
      ~s(<!DOCTYPE urlset SYSTEM "http://127.0.0.1:9/no.dtd"><urlset><url><loc>/safe</loc></url></urlset>),
      "<urlset/>"
    ]

    for body <- bodies do
      analysis = analyze(body)
      collection = collection(analysis)
      assert {:ok, old} = Document.parse(body, @base, opts())
      assert {:ok, actual, advanced} = Document.from_analysis(analysis, collection, opts())
      assert semantic(actual) == semantic(old), inspect(body)
      assert advanced.occurrences == collection.occurrences
      assert advanced.source_revision == collection.source_revision
      assert advanced.caller_metadata == :preserved
      assert actual.stats.working_bytes == 0
      assert actual.stats.prior_analysis_bytes == collection.budget.retained
      assert advanced.budget.retained == collection.budget.retained + actual.stats.output_bytes
      assert actual.stats.analysis_bytes == advanced.budget.retained
      assert advanced.budget.scratch == 0
      assert advanced.budget.counts == collection.budget.counts
      assert advanced.budget.peak >= collection.budget.peak
      assert actual.stats.peak_analysis_bytes == advanced.budget.peak
      assert {:ok, refunded} = Budget.refund(advanced.budget, actual.stats.output_bytes)
      assert refunded.retained == collection.budget.retained
    end
  end

  test "XML scalar facts do not depend on the later page or control role" do
    body = "<urlset><url><loc>/post</loc></url></urlset>"
    analysis_opts = %{content_type: "application/xml", max_total_bytes: 20_000_000}
    assert {:ok, page} = Analysis.analyze(body, Map.put(analysis_opts, :fetch_kind, :page))
    assert {:ok, control} = Analysis.analyze(body, Map.put(analysis_opts, :fetch_kind, :sitemap))
    assert page.lexical_key == control.lexical_key
    assert page.regions[page.root].facts == control.regions[control.root].facts
    assert page.regions[page.root].facts.document_summary.tokens > 0
    loc = Enum.find(page.regions[page.root].facts.tags, &(&1.name == "loc" and not &1.closing?))
    assert loc.content == "/post"
    assert loc.content_scalar?
  end

  test "semantic extraction invokes neither a lexical reader nor a new allowance" do
    body = ~s(<feed xml:base="/blog/"><entry><link href="post"/></entry></feed>)
    analysis = analyze(body)
    collection = collection(analysis)

    functions = [
      {Budget, :new, 1},
      {Crawler.XMLSpans, :analyze_result, 3},
      {Crawler.XMLSpans, :tags_result, 3},
      {Document, :parse, 3}
    ]

    Enum.each(functions, &:erlang.trace_pattern(&1, true, [:call_count]))

    try do
      assert {:ok, %{entries: [%{url: "https://example.test/blog/post"}]}, _} =
               Document.from_analysis(analysis, collection, opts())

      for function <- functions,
          do: assert({:call_count, 0} == :erlang.trace_info(function, :call_count))

      assert analysis.stats.scans.xml == 1
    after
      Enum.each(functions, &:erlang.trace_pattern(&1, false, [:call_count]))
    end
  end

  test "existing credit cannot be reset by the semantic continuation" do
    body = ~s(<feed><entry><link href="post"/></entry></feed>)
    analysis = analyze(body)
    collection = collection(analysis)

    assert {:ok, budget} =
             Budget.charge(
               collection.budget,
               Budget.available(collection.budget) - 5_000
             )

    assert {:ok, _} = Document.parse(body, @base, opts())

    assert {:error, {:limit, :max_analysis_bytes}} =
             Document.from_analysis(analysis, %{collection | budget: budget}, opts())

    assert Budget.available(budget) == 5_000
  end

  test "shared semantic peak has an exact accepted boundary" do
    body = ~s(<feed xml:base="/blog/"><entry><link href="post"/></entry></feed>)
    analysis = analyze(body)
    assert {:ok, document, _} = Document.from_analysis(analysis, collection(analysis), opts())
    peak = document.stats.peak_analysis_bytes
    assert peak > analysis.budget.peak
    exact = analyze(body, %{max_analysis_bytes: peak})

    assert {:ok, same, _} =
             Document.from_analysis(exact, collection(exact), opts(%{max_analysis_bytes: peak}))

    assert semantic(same) == semantic(document)
    below = analyze(body, %{max_analysis_bytes: peak - 1})

    assert {:error, {:limit, :max_analysis_bytes}} =
             Document.from_analysis(
               below,
               collection(below),
               opts(%{max_analysis_bytes: peak - 1})
             )
  end

  test "the same-pass summary enforces native XML limits without scanning gaps" do
    fixtures = [
      {"<x>text<!-- note --><![CDATA[value]]></x>", %{max_xml_tokens: 2}, :max_xml_tokens},
      {"<x><!--" <> String.duplicate("x", 100) <> "--></x>", %{max_control_token_bytes: 32},
       :max_control_token_bytes},
      {"<rss><description>" <> String.duplicate("<b/>", 30) <> "</description></rss>",
       %{max_control_token_bytes: 64}, :max_control_token_bytes},
      {"<a><b><c/></b></a>", %{max_xml_depth: 2}, :max_xml_depth},
      {"<x a='1' b='2' c='3'/>", %{max_xml_attributes: 2}, :max_xml_attributes},
      {~s(<?xml-stylesheet a="1" b="2"?><x/>), %{max_xml_attributes: 1}, :max_xml_attributes}
    ]

    for {body, overrides, key} <- fixtures do
      analysis = analyze(body)

      assert {:error, {:limit, ^key}} =
               Document.from_analysis(analysis, collection(analysis), opts(overrides))
    end

    analysis = analyze("<x/>")

    assert {:error, {:limit, :max_body}} =
             Document.from_analysis(analysis, collection(analysis), opts(%{max_body: 3}))
  end

  test "entry candidate limits include rejected URLs in the facts reducer" do
    body = ~s(<feed><entry><link href="javascript:a"/><link href="javascript:b"/></entry></feed>)
    analysis = analyze(body)

    assert {:error, {:limit, :max_control_entries}} =
             Document.from_analysis(
               analysis,
               collection(analysis),
               opts(%{max_control_entries: 1})
             )
  end

  test "continuation revision, capacity and mode are checked before semantic work" do
    analysis = analyze("<x/>")
    collection = collection(analysis)

    assert {:error, :invalid_budget_continuation} =
             Document.from_analysis(analysis, %{collection | source_revision: <<0>>}, opts())

    assert {:ok, held} = Budget.reserve(collection.budget, 1)

    assert {:error, :invalid_budget_continuation} =
             Document.from_analysis(analysis, %{collection | budget: held}, opts())

    assert {:error, :invalid_budget_continuation} =
             Document.from_analysis(
               analysis,
               %{collection | budget: %{collection.budget | retained: 0}},
               opts()
             )

    assert {:error, :incompatible_analysis_limits} =
             Document.from_analysis(analysis, collection, opts(%{max_analysis_bytes: 30_000_000}))

    assert {:error, :unsupported_analysis_mode} =
             Document.from_analysis(%{analysis | mode: :html}, collection, opts())
  end

  test "already recorded allocation peaks and expired deadlines survive the handoff" do
    analysis = analyze("<x/>")
    collection = collection(analysis)
    assert {:ok, budget} = Budget.reserve(collection.budget, 1_000_000)
    assert {:ok, budget} = Budget.release(budget, 1_000_000)

    assert {:ok, document, continued} =
             Document.from_analysis(analysis, %{collection | budget: budget}, opts())

    assert document.stats.working_bytes == 0
    assert continued.budget.peak == budget.peak

    for kind <- [:attempt, :run] do
      assert {:error, {:deadline, ^kind}} =
               Document.from_analysis(
                 analysis,
                 collection,
                 opts(%{deadline: Deadline.after_ms(0, kind)})
               )
    end
  end

  test "nested bases keep incremental frame accounting and native depth boundaries" do
    body =
      ~s(<feed xml:base="/blog/">) <>
        String.duplicate(~s(<n xml:base="./">), 253) <>
        ~s(<entry><link href="one"/></entry>) <>
        String.duplicate("</n>", 253) <> "</feed>"

    analysis = analyze(body)
    assert {:ok, document, _} = Document.from_analysis(analysis, collection(analysis), opts())
    assert document.stats.base_resolutions == 254
    assert document.stats.frames_created == 256
    assert document.stats.max_depth == 256
    assert document.stats.working_bytes == 0

    assert {:error, {:limit, :max_xml_depth}} =
             Document.from_analysis(analysis, collection(analysis), opts(%{max_xml_depth: 255}))
  end

  test "returned URL fields own exactly their charged backing bytes" do
    field = "https://example.test/" <> String.duplicate("a", 96)
    body = ~s(<urlset><url><loc>#{field}</loc></url></urlset>) <> String.duplicate(" ", 30_000)
    analysis = analyze(body)

    assert {:ok, %{entries: [entry]}, _} =
             Document.from_analysis(analysis, collection(analysis), opts())

    for binary <- [entry.url, entry.raw, entry.effective_base | Map.values(entry.source)],
        is_binary(binary),
        do: assert(:binary.referenced_byte_size(binary) == byte_size(binary))
  end

  test "mixed URL scalar markup has an explicit outcome while prose stays suppressed" do
    body = "<urlset><url><loc>https://example.test/a<b>x</b>tail</loc></url></urlset>"
    analysis = analyze(body)

    assert {:error, :unsupported_control_scalar_markup} =
             Document.from_analysis(analysis, collection(analysis), opts())
  end
end
