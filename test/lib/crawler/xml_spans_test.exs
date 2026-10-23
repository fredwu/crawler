defmodule Crawler.XMLSpansTest do
  use ExUnit.Case, async: true

  alias Crawler.HTMLSpans
  alias Crawler.MediaType
  alias Crawler.XMLSpans

  @html "http://www.w3.org/1999/xhtml"
  @svg "http://www.w3.org/2000/svg"
  @xlink "http://www.w3.org/1999/xlink"

  test "actual response MIME selects XML without changing embedded HTML SVG rules" do
    assert MediaType.document_mode("application/xhtml+xml; charset=utf-8") == :xml
    assert MediaType.document_mode("image/svg+xml") == :xml
    assert MediaType.document_mode("application/xml") == :xml
    assert MediaType.document_mode("text/html") == :html
    assert MediaType.document_mode("image/png") == nil

    source = ~s|<script src="a.js"/><a href="next.xhtml"/>|
    assert Enum.map(HTMLSpans.tags(source), & &1.name) == ["script"]

    assert {:ok, %{tags: tags}} = XMLSpans.analyze(source, content_type: "application/xhtml+xml")
    assert Enum.map(tags, & &1.name) == ["script", "a"]
    assert Enum.all?(tags, &(&1.namespace_uri == @html and &1.self_closing?))
  end

  test "self-closing script and style elements do not consume later XML" do
    source = ~s|<html xmlns="#{@html}"><script src="a.js"/><style/><a href="next"/></html>|
    assert {:ok, %{tags: tags}} = XMLSpans.analyze(source)
    assert Enum.map(tags, & &1.name) == ["html", "script", "style", "a", "html"]
    assert Enum.all?(tags, &is_nil(&1.content_span))
  end

  test "namespaces use declared URIs and preserve qualified names and XML case" do
    source =
      ~s|<s:svg xmlns:s="#{@svg}" xmlns:q="#{@xlink}" xmlns:xlink="urn:other">| <>
        ~s|<s:feImage q:href="paint.png" xlink:href="other.png" href="plain.png"/>| <>
        ~s|<image/><s:Image/></s:svg>|

    assert {:ok, %{tags: [_root, image, unqualified, capitalized, _close]}} =
             XMLSpans.analyze(source, content_type: "image/svg+xml")

    assert image.name == "feImage"
    assert image.qualified_name == "s:feImage"
    assert image.namespace_uri == @svg

    assert Enum.map(image.attributes, &{&1.qualified_name, &1.namespace_uri}) ==
             [{"q:href", @xlink}, {"xlink:href", "urn:other"}, {"href", nil}]

    assert unqualified.namespace_uri == nil
    assert capitalized.name == "Image"
    assert capitalized.namespace == :svg
  end

  test "the default namespace changes elements but never unprefixed attributes" do
    source =
      ~s|<svg xmlns="#{@svg}"><g xmlns="urn:other"><image href="no.png"/></g>| <>
        ~s|<image href="yes.png"/></svg>|

    assert {:ok, %{tags: tags}} = XMLSpans.analyze(source)
    images = Enum.filter(tags, &(&1.name == "image"))
    assert Enum.map(images, & &1.namespace_uri) == ["urn:other", @svg]
    assert Enum.all?(images, fn tag -> hd(tag.attributes).namespace_uri == nil end)
  end

  test "namespace-less SVG documents retain their established vocabulary" do
    assert {:ok, %{tags: [svg, image, _close]}} =
             XMLSpans.analyze(~s|<svg><image href="icon.png"/></svg>|,
               content_type: "image/svg+xml"
             )

    assert svg.namespace == :svg
    assert image.namespace == :svg
  end

  test "legal Unicode wrapper names and prefixes do not hide SVG references" do
    for name <- [
          "a\u0301",
          "a\u00B7",
          "a\u203F",
          "a\u2040",
          "\u200Cx",
          "\u2070",
          "\u3001",
          "\u{1F600}"
        ] do
      source =
        "<#{name} xmlns:#{name}=\"#{@svg}\"><#{name}:image href=\"icon.png\"/></#{name}>"

      assert {:ok, %{tags: [wrapper, image, _close]}} = XMLSpans.analyze(source)
      assert wrapper.name == name
      assert image.qualified_name == name <> ":image"
      assert image.namespace == :svg
      assert hd(image.attributes).decoded == "icon.png"
    end
  end

  test "XML name-start ranges include their full specified endpoints" do
    ranges = [
      {0xC0, 0xD6},
      {0xD8, 0xF6},
      {0xF8, 0x2FF},
      {0x370, 0x37D},
      {0x37F, 0x1FFF},
      {0x200C, 0x200D},
      {0x2070, 0x218F},
      {0x2C00, 0x2FEF},
      {0x3001, 0xD7FF},
      {0xF900, 0xFDCF},
      {0xFDF0, 0xFFFD},
      {0x10000, 0xEFFFF}
    ]

    for {first, last} <- ranges, point <- [first, last] do
      name = <<point::utf8>> <> "wrapper"
      assert {:ok, %{tags: [%{name: ^name}]}} = XMLSpans.analyze("<#{name}/>")
    end
  end

  test "Unicode categories do not admit characters outside XML name ranges" do
    for name <- ["\u0301a", "a\u00B2", "a\u037E", "\u{F0000}", ":svg", "a::svg", "svg:"] do
      assert XMLSpans.analyze("<#{name}/>") == {:error, :invalid_xml}
    end

    assert XMLSpans.analyze("<?a:b data?><svg/>") == {:error, :invalid_xml}
    assert {:ok, %{tags: [%{name: "svg"}]}} = XMLSpans.analyze("<?a\u0301 data?><svg/>")
  end

  test "XML text and CDATA keep decoded content and absolute source segments" do
    source = ~s|<script xmlns="#{@html}">const a="a&amp;b";<![CDATA[import("./b.js");]]></script>|
    assert {:ok, %{tags: [script, _close]}} = XMLSpans.analyze(source)
    assert script.content == ~s|const a="a&b";import("./b.js");|
    assert HTMLSpans.slice(source, script.content_span) =~ "<![CDATA["

    entity = Enum.find(script.content_segments, &(HTMLSpans.slice(source, &1.span) == "&amp;"))
    assert HTMLSpans.slice(script.content, entity.decoded_span) == "&"
    assert entity.kind == :xml_text

    cdata = Enum.find(script.content_segments, &(&1.kind == :xml_cdata))
    assert HTMLSpans.slice(source, cdata.span) == ~s|import("./b.js");|
    assert HTMLSpans.slice(script.content, cdata.decoded_span) == ~s|import("./b.js");|
  end

  test "xml:base is resolved incrementally and sibling scope is restored" do
    source =
      ~s|<svg xml:base="/assets/"><g xml:base="nested/">| <>
        ~s|<image href="one.png"/></g><image href="two.png"/>| <>
        ~s|<image xml:base="bad base" href="three.png"/></svg>|

    assert {:ok, %{tags: tags}} = XMLSpans.analyze(source, content_type: "image/svg+xml")

    images =
      tags
      |> XMLSpans.resolve_bases("https://example.test/root.svg")
      |> Enum.filter(&(&1.name == "image"))

    assert Enum.map(images, & &1.effective_base) == [
             "https://example.test/assets/nested/",
             "https://example.test/assets/",
             "https://example.test/assets/"
           ]
  end

  test "DTD declarations are opaque and external or undeclared entities are never expanded" do
    declaration =
      ~s|<!DOCTYPE svg SYSTEM "https://external.test/document.dtd" [<!ENTITY image SYSTEM "file:///secret">]>|

    assert {:ok, %{tags: [svg]}} = XMLSpans.analyze(declaration <> "<svg/>")
    assert svg.name == "svg"
    assert {:error, :invalid_xml} = XMLSpans.analyze(declaration <> "<svg>&image;</svg>")
    assert {:error, :invalid_xml} = XMLSpans.analyze(~s|<svg href="&unknown;"/>|)
  end

  test "only predefined and valid numeric XML entities are decoded" do
    assert XMLSpans.decode("&amp;&lt;&gt;&quot;&apos;&#233;&#x1F600;") == {:ok, "&<>\"'é😀"}

    for invalid <- ["&nbsp;", "&#0;", "&#xD800;", "&#x110000;", "&#-1;", "&#+65;", "&#x+41;"] do
      assert XMLSpans.decode(invalid) == :error
    end
  end

  test "XML syntax does not inherit HTML attribute and case recovery" do
    for source <- [
          ~s|<svg href=unquoted/>|,
          "<svg></SVG>",
          "<p:svg/>",
          ~s|<svg href="one" href="two"/>|,
          ~s|<svg xmlns:a="urn:same" xmlns:b="urn:same" a:x="1" b:x="2"/>|
        ] do
      assert {:error, :invalid_xml} = XMLSpans.analyze(source)
    end
  end

  test "XML newline and attribute normalization retain source mapping" do
    source = "<svg href=\"a\r\nb\tc&#10;d\"/>"
    assert {:ok, %{tags: [svg]}} = XMLSpans.analyze(source)
    assert hd(svg.attributes).decoded == "a b c\nd"
    assert XMLSpans.decode("a\r\nb\rc") == {:ok, "a\nb\nc"}

    {:ok, text, segments} = XMLSpans.decode_with_spans("a\r\nb")
    assert text == "a\nb"
    assert HTMLSpans.source_span(segments, {1, 1}) == {1, 2}
  end

  test "depth, token, attribute, and byte budgets return explicit outcomes" do
    assert XMLSpans.analyze("<svg><g/></svg>", max_depth: 1) == {:error, {:limit, :xml_depth}}
    assert XMLSpans.analyze("<svg><g/></svg>", max_tokens: 1) == {:error, {:limit, :xml_tokens}}

    assert XMLSpans.analyze(~s|<svg a="1" b="2"/>|, max_attributes: 1) ==
             {:error, {:limit, :xml_attributes}}

    assert XMLSpans.analyze("<svg/>", max_bytes: 5) == {:error, {:limit, :xml_bytes}}
  end

  test "a zero byte budget keeps empty input semantics and rejects nonempty input" do
    assert XMLSpans.analyze("", max_bytes: 0) == {:ok, %{tags: [], instructions: []}}
    assert XMLSpans.analyze("<svg/>", max_bytes: 0) == {:error, {:limit, :xml_bytes}}

    for key <- [:max_depth, :max_tokens, :max_attributes] do
      assert XMLSpans.analyze("", [{key, 0}]) == {:error, :invalid_limits}
    end

    assert XMLSpans.analyze("", max_bytes: -1) == {:error, :invalid_limits}
  end

  test "XML stylesheet instructions retain href spans and XML entity rules" do
    source = ~s|<?xml-stylesheet type="text/css" href="theme.css?a=1&amp;b=2"?><svg/>|
    assert {:ok, %{instructions: [sheet]}} = XMLSpans.analyze(source)
    href = Enum.find(sheet.attributes, &(&1.name == "href"))
    assert href.decoded == "theme.css?a=1&b=2"
    assert HTMLSpans.slice(source, href.value_span) == "theme.css?a=1&amp;b=2"
  end
end
