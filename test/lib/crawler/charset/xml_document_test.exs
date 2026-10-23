defmodule Crawler.Charset.XMLDocumentTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset
  alias Crawler.XMLSpans

  test "UTF-16 SVG is decoded before namespace-aware source analysis" do
    source =
      ~s|<?xml version="1.0" encoding="UTF-16"?><s:svg xmlns:s="http://www.w3.org/2000/svg"><s:image href="café.png"/></s:svg>|

    expected = String.replace(source, "UTF-16", "utf-8")

    for {endian, bom} <- [{:little, <<0xFF, 0xFE>>}, {:big, <<0xFE, 0xFF>>}],
        prefix <- [bom, ""] do
      encoded = prefix <> :unicode.characters_to_binary(source, :utf8, {:utf16, endian})
      body = Charset.decode(encoded, %{content_type: "image/svg+xml"})
      assert body == expected
      assert {:ok, %{tags: [_svg, image, _close]}} = XMLSpans.analyze(body)
      assert image.namespace == :svg
      assert hd(image.attributes).decoded == "café.png"
    end
  end

  test "HTTP charset and BOM precedence also applies to SVG" do
    source = ~s|<?xml version="1.0" encoding="latin1"?><svg><image href="café.png"/></svg>|
    expected = String.replace(source, "latin1", "utf-8")
    latin = :unicode.characters_to_binary(source, :utf8, :latin1)

    assert Charset.decode(latin, %{content_type: "image/svg+xml"}) == expected

    assert Charset.decode(<<0xEF, 0xBB, 0xBF>> <> source, %{
             content_type: "image/svg+xml",
             headers: [{"content-type", "image/svg+xml; charset=latin1"}]
           }) == expected
  end

  test "XHTML encoding follows XML declarations rather than HTML meta declarations" do
    source =
      ~s|<?xml version="1.0" encoding="latin1"?><html><meta charset="latin1"/><a href="café"/></html>|

    latin = :unicode.characters_to_binary(source, :utf8, :latin1)

    assert Charset.decode(latin, %{content_type: "application/xhtml+xml"}) ==
             String.replace(source, ~s|encoding="latin1"|, ~s|encoding="utf-8"|)
  end
end
