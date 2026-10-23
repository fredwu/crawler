defmodule Crawler.XMLBudgetTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis.Budget
  alias Crawler.XMLSpans

  @html "http://www.w3.org/1999/xhtml"

  defp budget(bytes \\ 1_000_000, facts \\ 10_000) do
    Budget.new(%{
      max_total_bytes: bytes,
      max_facts: facts,
      max_regions: 10,
      max_occurrences: 100,
      max_edits: 100
    })
  end

  test "native and shared outcomes use one namespace and entity implementation" do
    source =
      ~s|<?xml-stylesheet type="text/css" href="a&amp;b"?><s:svg xmlns:s="http://www.w3.org/2000/svg"><s:feImage href="café.png"/><s:script><![CDATA[a&b]]>c&amp;d</s:script></s:svg>|

    assert {:ok, expected} = XMLSpans.analyze(source)
    assert {:ok, ^expected, ledger} = XMLSpans.analyze_result(source, [], budget())
    assert ledger.scratch == 0
    assert ledger.retained > 0
    assert ledger.peak > ledger.retained
    assert {:ok, tags, _ledger} = XMLSpans.tags_result(source, [], budget())
    assert tags == expected.tags
  end

  test "facts aggregate tags attributes and decoded segments" do
    source = ~s|<svg a="x" b="y"/>|
    assert {:ok, _analysis, ledger} = XMLSpans.analyze_result(source, [], budget(1_000_000, 5))
    assert ledger.counts.facts == 5

    assert XMLSpans.analyze_result(source, [], budget(1_000_000, 4)) ==
             {:error, {:limit, :lexical_facts}}
  end

  test "an exhausted fact quota stops before later entity conversion" do
    source = ~s|<svg a="&amp;" b="&amp;" c="&amp;"/>|

    {result, calls} =
      traced({XMLSpans, :entity, 1}, fn ->
        XMLSpans.analyze_result(source, [], budget(1_000_000, 3))
      end)

    assert result == {:error, {:limit, :lexical_facts}}
    assert length(calls) == 1

    {result, calls} =
      traced({XMLSpans, :entity, 1}, fn ->
        XMLSpans.analyze_result(source, [], budget(1_000_000, 2))
      end)

    assert result == {:error, {:limit, :lexical_facts}}
    assert calls == []
  end

  test "discarded text releases bytes but does not refund cumulative facts" do
    assert {:ok, %{tags: []}, first} = XMLSpans.analyze_result("a&amp;b", [], budget())
    assert first.retained == 0
    assert first.scratch == 0
    assert first.counts.facts == 3
    assert first.peak > 0
    capped = %{first | caps: %{first.caps | facts: 3}}
    assert XMLSpans.analyze_result("x", [], capped) == {:error, {:limit, :lexical_facts}}
  end

  test "normalization segments and CDATA share the same aggregate quota" do
    source = "<script xmlns=\"#{@html}\">a\r\nb<![CDATA[c\rd]]></script>"

    assert {:ok, %{tags: [script, _close]}, ledger} =
             XMLSpans.analyze_result(source, [], budget())

    assert script.content == "a\nbc\nd"

    assert Enum.map(script.content_segments, & &1.kind) ==
             [:xml_text, :xml_text, :xml_text, :xml_cdata, :xml_cdata, :xml_cdata]

    assert ledger.counts.facts == 10
    assert ledger.scratch == 0

    assert XMLSpans.analyze_result(source, [], budget(1_000_000, 9)) ==
             {:error, {:limit, :lexical_facts}}
  end

  test "instructions and their attributes cannot bypass the shared fact cap" do
    source = ~s|<?xml-stylesheet type="text/css" href="a&amp;b"?><svg/>|
    assert {:ok, _analysis, ledger} = XMLSpans.analyze_result(source, [], budget())
    assert ledger.counts.facts == 8

    assert XMLSpans.analyze_result(source, [], budget(1_000_000, 7)) ==
             {:error, {:limit, :lexical_facts}}
  end

  test "shared byte failures keep their reason through attributes and instructions" do
    for source <- [
          ~s|<svg href="x"/>|,
          ~s|<?xml-stylesheet href="x"?><svg/>|,
          "<script xmlns=\"#{@html}\">a&amp;b</script>"
        ] do
      assert XMLSpans.analyze_result(source, [], budget(1_000)) ==
               {:error, {:limit, :analysis_bytes}}
    end
  end

  test "native limits remain independent and preserve zero byte behavior" do
    assert {:ok, %{tags: [], instructions: []}, ledger} =
             XMLSpans.analyze_result("", [max_bytes: 0], budget(0, 0))

    assert ledger == budget(0, 0)

    assert XMLSpans.analyze_result("<svg/>", [max_bytes: 0], budget()) ==
             {:error, {:limit, :xml_bytes}}

    assert XMLSpans.analyze_result("<svg><g/></svg>", [max_depth: 1], budget()) ==
             {:error, {:limit, :xml_depth}}

    assert XMLSpans.analyze_result("<svg><g/></svg>", [max_tokens: 1], budget()) ==
             {:error, {:limit, :xml_tokens}}

    assert XMLSpans.analyze_result(~s|<svg a="1" b="2"/>|, [max_attributes: 1], budget()) ==
             {:error, {:limit, :xml_attributes}}

    assert XMLSpans.analyze_result("", [max_depth: 0], budget()) == {:error, :invalid_limits}
  end

  test "standalone decoding retains spans and cumulative work while releasing scratch" do
    value = "a\r\nb\tc&#10;d&amp;"
    assert {:ok, expected, expected_segments} = XMLSpans.decode_with_spans(value, 11, :attribute)

    assert {:ok, ^expected, ^expected_segments, ledger} =
             XMLSpans.decode_with_spans_result(value, 11, :attribute, budget())

    assert expected == "a b c\nd&"
    assert ledger.scratch == 0
    assert ledger.counts.facts == length(expected_segments)
    assert {:ok, decoded, plain} = XMLSpans.decode_result(value, budget())
    assert decoded == "a\nb\tc\nd&"
    assert plain.retained == Budget.cost(:binary) + byte_size(decoded)
    assert plain.counts.facts > 0
  end

  test "literal decoding reserves its binary and overlapping flattening before copying" do
    source = String.duplicate("x", 1_024)

    assert {:ok, ^source, [_segment], ledger} =
             XMLSpans.decode_with_spans_result(source, 0, :text, budget())

    assert ledger.retained ==
             Budget.cost(:binary) + 1_024 + Budget.cost(:segment) + Budget.cost(:list_cell)

    assert ledger.peak >= ledger.retained + 1_024

    assert XMLSpans.decode_with_spans_result(source, 0, :text, budget(ledger.peak - 1)) ==
             {:error, {:limit, :analysis_bytes}}
  end

  test "newline heavy input stops as the shared segment allowance is exhausted" do
    input = String.duplicate("\r\n", 128)

    assert XMLSpans.decode_with_spans_result(input, 0, :text, budget(1_000_000, 2)) ==
             {:error, {:limit, :lexical_facts}}

    assert XMLSpans.decode_with_spans_result(input, 0, :text, budget(1_024)) ==
             {:error, {:limit, :analysis_bytes}}
  end

  test "nested namespace frames release scratch and preserve sibling scope" do
    source =
      ~s|<svg xmlns="http://www.w3.org/2000/svg"><g xmlns="urn:other"><image/></g><image/></svg>|

    assert {:ok, %{tags: tags}, ledger} = XMLSpans.analyze_result(source, [], budget())

    assert Enum.map(Enum.filter(tags, &(&1.name == "image")), & &1.namespace_uri) ==
             ["urn:other", "http://www.w3.org/2000/svg"]

    assert ledger.scratch == 0

    assert XMLSpans.analyze_result(source, [], budget(ledger.peak - 1)) ==
             {:error, {:limit, :analysis_bytes}}
  end

  test "base processing preserves relative nonHTTP fragment and case semantics" do
    assert {:ok, %{tags: tags}, ledger} =
             XMLSpans.analyze_result(
               ~s|<svg xml:base="../Dir/#Frag"><g xml:base="Next/"/><g xml:base="bad base"/></svg>|,
               [],
               budget()
             )

    for base <- [
          "HTTP://Example.test/Root/File.svg#Old",
          "urn:example:root",
          "relative/root.svg",
          nil
        ] do
      expected = XMLSpans.resolve_bases(tags, base)
      assert {:ok, ^expected, resolved} = XMLSpans.resolve_bases_result(tags, base, ledger)
      assert resolved.counts == ledger.counts
      assert resolved.scratch == 0
    end

    assert {:ok, resolved, _ledger} =
             XMLSpans.resolve_bases_result(tags, "https://EXAMPLE.test/root.svg", ledger)

    assert hd(resolved).effective_base == "https://EXAMPLE.test/Dir/#Frag"
    assert Enum.at(resolved, 2).effective_base == hd(resolved).effective_base
  end

  test "base composition uses residual bytes and stops before the next URI merge" do
    assert {:ok, %{tags: tags}} = XMLSpans.analyze(~s|<svg xml:base="a/"/><svg xml:base="b/"/>|)

    {result, calls} =
      traced({URI, :merge, 2}, fn ->
        XMLSpans.resolve_bases_result(
          tags,
          "https://example.test/" <> String.duplicate("x", 128),
          budget(2_000)
        )
      end)

    assert result == {:error, {:limit, :analysis_bytes}}
    assert calls == []
  end

  test "DTD entities remain opaque and failures remain distinct from budget exhaustion" do
    declaration =
      ~s|<!DOCTYPE svg SYSTEM "https://external.test/x" [<!ENTITY x SYSTEM "file:///secret">]>|

    assert {:ok, %{tags: [_svg]}, _ledger} =
             XMLSpans.analyze_result(declaration <> "<svg/>", [], budget())

    assert XMLSpans.analyze_result(declaration <> "<svg>&x;</svg>", [], budget()) ==
             {:error, :invalid_xml}

    for value <- ["&nbsp;", "&#0;", "&#xD800;", "&#x110000;"] do
      assert XMLSpans.decode_result(value, budget()) == {:error, :invalid_xml}
    end
  end

  test "UTF16 decoded source keeps UTF8 byte spans" do
    original = ~s|<s:svg xmlns:s="http://www.w3.org/2000/svg"><s:image href="café.png"/></s:svg>|

    for endian <- [:little, :big] do
      utf16 = :unicode.characters_to_binary(original, :utf8, {:utf16, endian})
      decoded = :unicode.characters_to_binary(utf16, {:utf16, endian}, :utf8)

      assert {:ok, %{tags: [_svg, image, _close]}, ledger} =
               XMLSpans.analyze_result(decoded, [], budget())

      attr = hd(image.attributes)
      {at, size} = attr.value_span
      assert binary_part(decoded, at, size) == "café.png"
      assert attr.segments == [{0, byte_size("café.png"), at, size}]
      assert ledger.scratch == 0
    end
  end

  test "all entry points keep caller retained bytes scratch and counters" do
    {:ok, upstream} = Budget.charge(budget(), 1_000, facts: 2)
    {:ok, upstream} = Budget.reserve(upstream, 777)
    assert {:ok, %{tags: tags}, scanned} = XMLSpans.analyze_result("<svg/>", [], upstream)
    assert scanned.scratch == 777
    assert scanned.retained > upstream.retained
    assert scanned.counts.facts == 3

    assert {:ok, _tags, resolved} =
             XMLSpans.resolve_bases_result(tags, "https://example.test/", scanned)

    assert resolved.scratch == 777
    assert resolved.retained > scanned.retained
    assert resolved.counts == scanned.counts
    assert {:ok, "&", decoded} = XMLSpans.decode_result("&amp;", resolved)
    assert decoded.scratch == 777
    assert decoded.counts.facts == 4
  end

  test "tags projection refunds instruction storage while keeping its cumulative facts" do
    source = ~s|<?xml-stylesheet href="a&amp;b"?><svg/>|
    assert {:ok, analysis, all} = XMLSpans.analyze_result(source, [], budget())
    assert {:ok, tags, projected} = XMLSpans.tags_result(source, [], budget())
    assert tags == analysis.tags
    assert projected.counts == all.counts
    assert projected.retained < all.retained
    assert projected.scratch == 0
    assert projected.peak == all.peak
  end

  test "name validation cannot start before its variable scratch is reserved" do
    source = "<" <> String.duplicate("n", 2_048) <> "/>"

    {result, calls} =
      traced({Regex, :match?, 2}, fn ->
        XMLSpans.analyze_result(source, [], budget(5_000))
      end)

    assert result == {:error, {:limit, :analysis_bytes}}
    assert calls == []
  end

  test "equal composed bases retain authority for each new binary backing" do
    assert {:ok, %{tags: tags}, ledger} =
             XMLSpans.analyze_result(
               ~s|<svg xml:base="./"/><svg xml:base="./"/>|,
               [],
               budget()
             )

    base = "https://example.test/a/"
    assert {:ok, resolved, after_bases} = XMLSpans.resolve_bases_result(tags, base, ledger)
    assert Enum.map(resolved, & &1.effective_base) == [base, base]

    assert after_bases.retained - ledger.retained ==
             2 *
               (Budget.cost(:tag) + Budget.cost(:list_cell) + Budget.cost(:binary) +
                  byte_size(base))

    assert after_bases.scratch == 0
  end

  test "generic processing instructions end at the first literal delimiter inside quotes" do
    for quote <- ["\"", "'"] do
      source = "<?probe " <> quote <> "?><svg/>"

      assert {:ok, %{tags: [%{name: "svg"}], instructions: []}, ledger} =
               XMLSpans.analyze_result(source, [], budget())

      assert ledger.scratch == 0
    end
  end

  test "stylesheet pseudo attributes cannot read beyond the PI boundary" do
    source = ~s|<?xml-stylesheet title="a?>b" href="theme.css"?><svg/>|
    assert XMLSpans.analyze(source) == {:error, :invalid_xml}
    assert XMLSpans.analyze_result(source, [], budget()) == {:error, :invalid_xml}
  end

  test "an escaped greater-than character stays inside a stylesheet title" do
    source = ~s|<?xml-stylesheet title="a?&gt;b" href="theme.css"?><svg/>|

    assert {:ok, %{instructions: [%{attributes: [title, href]}]}, ledger} =
             XMLSpans.analyze_result(source, [], budget())

    assert title.decoded == "a?>b"
    assert href.decoded == "theme.css"
    assert ledger.scratch == 0
  end

  test "document text capture folds local names and preserves canonical qualified case" do
    source =
      ~s|<r xmlns:p="urn:feed"><p:LoC>a</p:LoC><LiNk>b</LiNk><GUID>c</GUID><THUMBNAIL_LOC>d</THUMBNAIL_LOC><CONTENT_LOC/></r>|

    assert {:ok, native} = XMLSpans.analyze(source)
    refute Map.has_key?(native, :document_summary)
    refute Enum.any?(native.tags, &Map.has_key?(&1, :content_scalar?))

    assert {:ok, analysis, ledger} =
             XMLSpans.analyze_result(source, [document_text: true], budget())

    captured = Enum.filter(analysis.tags, &Map.has_key?(&1, :content_scalar?))

    assert Enum.map(captured, & &1.qualified_name) == [
             "p:LoC",
             "LiNk",
             "GUID",
             "THUMBNAIL_LOC",
             "CONTENT_LOC"
           ]

    assert Enum.map(captured, & &1.name) == [
             "LoC",
             "LiNk",
             "GUID",
             "THUMBNAIL_LOC",
             "CONTENT_LOC"
           ]

    assert Enum.map(captured, & &1.content) == ["a", "b", "c", "d", ""]
    assert Enum.all?(captured, & &1.content_scalar?)
    assert List.last(captured).content_span == nil
    assert ledger.scratch == 0
  end

  test "document scalars join canonical text and literal CDATA while retaining source spans" do
    inner = " café&amp;<![CDATA[&amp;\r\nx]]><!--excluded--><?probe ignored?>&#33; "
    source = "<loc>" <> inner <> "</loc>"

    assert {:ok, %{tags: [tag, close]}, ledger} =
             XMLSpans.analyze_result(source, [document_text: true], budget())

    assert tag.content == " café&&amp;\nx! "
    assert tag.content_scalar?
    assert tag.content_span == {5, byte_size(inner)}
    refute Map.has_key?(close, :content_scalar?)
    assert Enum.any?(tag.content_segments, &(&1.kind == :xml_cdata))

    for segment <- tag.content_segments do
      {at, size} = segment.decoded_span
      {source_at, source_size} = segment.span
      assert size > 0
      assert byte_size(binary_part(tag.content, at, size)) == size
      assert source_at >= 5 and source_at + source_size <= 5 + byte_size(inner)
    end

    assert ledger.scratch == 0
  end

  test "nested scalar markup is explicit and attribute discoveries remain available" do
    source = ~s|<link HREF="attr.xml">before<b/><loc>nested</loc>after</link>|

    assert {:ok, %{tags: [link, _, loc | _]}, ledger} =
             XMLSpans.analyze_result(source, [document_text: true], budget())

    refute link.content_scalar?
    assert link.content == "beforeafter"
    assert hd(link.attributes).decoded == "attr.xml"
    assert loc.content_scalar?
    assert loc.content == "nested"
    assert ledger.scratch == 0

    assert XMLSpans.analyze_result("<loc><b></loc>", [document_text: true], budget()) ==
             {:error, :invalid_xml}
  end

  test "the summary counts every canonical token and attributes without retaining prose" do
    pi = ~s|<?xml-stylesheet href="x" type="text/css"?>|
    dtd = "<!DOCTYPE r [<!ENTITY ignored 'opaque'>]>"
    prose = "a<!--hidden--><![CDATA[b]]><b q='z'/>c"
    source = pi <> dtd <> "<r a='v'><TITLE>" <> prose <> "</TITLE><?probe x?></r>"

    assert {:ok, %{tags: tags, document_summary: summary}, ledger} =
             XMLSpans.analyze_result(source, [document_text: true], budget())

    assert summary == %{
             tokens: 12,
             max_token_bytes: max(byte_size(pi), byte_size(dtd)),
             max_scalar_bytes: byte_size(prose),
             max_depth: 3,
             max_attributes: 2,
             attributes: 4
           }

    title = Enum.find(tags, &(&1.name == "TITLE" and not &1.closing?))
    assert title.content == ""
    assert title.content_span == nil
    refute Map.has_key?(title, :content_scalar?)
    assert ledger.scratch == 0
  end

  test "content prose summary uses the first folded unprefixed URL attribute" do
    inner = "a<!--padding--><b/>c"

    for {attrs, prose?} <- [
          {"", true},
          {~s| URL="  "|, true},
          {~s| url="asset"|, false},
          {~s| x:url="asset"|, true},
          {~s| URL="asset" url=""|, false},
          {~s| URL="" url="asset"|, true}
        ] do
      source = ~s|<content xmlns:x="u"#{attrs}>#{inner}</content>|

      assert {:ok, %{document_summary: summary}, _} =
               XMLSpans.analyze_result(source, [document_text: true], budget())

      assert summary.max_scalar_bytes ==
               if(prose?,
                 do: byte_size(inner),
                 else: max(1, if(String.contains?(attrs, "asset"), do: 5, else: 0))
               )
    end
  end

  test "document summary is prepaid even for an empty root and native zero byte behavior stays" do
    assert {:ok, %{document_summary: summary}, ledger} =
             XMLSpans.analyze_result("", [document_text: true, max_bytes: 0], budget())

    assert summary == %{
             tokens: 0,
             max_token_bytes: 0,
             max_scalar_bytes: 0,
             max_depth: 0,
             max_attributes: 0,
             attributes: 0
           }

    assert ledger.retained == Budget.cost(:frame)
    assert ledger.scratch == 0

    assert XMLSpans.analyze_result("", [document_text: true], budget(0)) ==
             {:error, {:limit, :analysis_bytes}}

    assert {:ok, [], projected} = XMLSpans.tags_result("", [document_text: true], budget(0))
    assert projected.retained == 0
  end

  test "captured text continues the caller ledger and reserves the observed overlap before copying" do
    assert {:ok, initial} = Budget.charge(budget(), 123, facts: 7)
    assert {:ok, initial} = Budget.reserve(initial, 81)
    source = "<loc>" <> String.duplicate("x&amp;", 40) <> "</loc>"
    assert {:ok, _, ledger} = XMLSpans.analyze_result(source, [document_text: true], initial)
    assert ledger.scratch == 81
    assert ledger.retained > 123
    assert ledger.counts.facts > 7
    capped = %{initial | limit: ledger.peak - 1}

    assert XMLSpans.analyze_result(source, [document_text: true], capped) ==
             {:error, {:limit, :analysis_bytes}}

    assert {:ok, _, exact} =
             XMLSpans.analyze_result(source, [document_text: true], %{capped | limit: ledger.peak})

    assert exact.retained == ledger.retained
    assert exact.counts == ledger.counts

    assert XMLSpans.analyze_result(source, [document_text: true], budget(1_000_000, 2)) ==
             {:error, {:limit, :lexical_facts}}
  end

  defp traced(mfa, fun) do
    parent = self()

    pid =
      spawn(fn ->
        receive do
          :go ->
            result = fun.()
            send(parent, {:result, self(), result})
            receive do: (:finish -> :ok)
        end
      end)

    :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(pid, true, [:call])
    send(pid, :go)

    try do
      assert_receive {:result, ^pid, result}, 5_000
      ref = :erlang.trace_delivered(pid)
      assert_receive {:trace_delivered, ^pid, ^ref}, 5_000
      {result, trace_calls(pid, [])}
    after
      :erlang.trace_pattern(mfa, false, [:local])
      send(pid, :finish)
    end
  end

  defp trace_calls(pid, acc) do
    receive do
      {:trace, ^pid, :call, call} -> trace_calls(pid, [call | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
