defmodule Crawler.Charset.HTMLMetaEncodingTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset
  alias Crawler.Linker
  alias Crawler.Snapper.LinkReplacer

  @page "http://example.com/index.html"
  @text ~s|<p>café</p><a href="café">go</a>|

  for label <- ["UTF-16", "UTF-16LE", "UTF-16BE"],
      declaration <- [:charset, :content] do
    test "HTML #{declaration} meta #{label} selects UTF-8 text and rewrites its real link" do
      declaration = declaration(unquote(declaration), unquote(label))
      source = declaration <> @text
      decoded = Charset.decode(source, %{content_type: "text/html"})
      assert decoded == String.replace(declaration, unquote(label), "utf-8") <> @text
      assert decoded |> Floki.parse_document!() |> Floki.attribute("a", "href") == ["café"]

      assert {:ok, body} =
               LinkReplacer.replace_links(decoded, %{
                 url: @page,
                 content_type: "text/html",
                 html_tag: "a",
                 assets: [],
                 depth: 1,
                 max_depths: 3
               })

      assert body |> Floki.parse_document!() |> Floki.attribute("a", "href") ==
               [Linker.offline_link(@page, "http://example.com/café")]
    end
  end

  test "HTTP charset still selects real UTF-16 bytes before HTML meta normalization" do
    source = declaration(:charset, "UTF-16LE") <> @text
    encoded = :unicode.characters_to_binary(source, :utf8, {:utf16, :little})

    assert Charset.decode(encoded, %{
             content_type: "text/html",
             headers: [{"content-type", "text/html; charset=utf-16le"}]
           }) == declaration(:charset, "utf-8") <> @text
  end

  test "BOM decoding still selects real UTF-16 bytes over a conflicting HTTP charset" do
    source = declaration(:content, "UTF-16BE") <> @text
    encoded = <<0xFE, 0xFF>> <> :unicode.characters_to_binary(source, :utf8, {:utf16, :big})

    assert Charset.decode(encoded, %{
             content_type: "text/html",
             headers: [{"content-type", "text/html; charset=latin1"}]
           }) == declaration(:content, "utf-8") <> @text
  end

  test "XHTML XML declarations still select real UTF-16 bytes" do
    source =
      ~s|<?xml version="1.0" encoding="utf-16le"?>| <> declaration(:charset, "UTF-16BE") <> @text

    assert Crawler.Charset.HTML.xml_charset(source) == "utf-16le"
    encoded = <<0xFF, 0xFE>> <> :unicode.characters_to_binary(source, :utf8, {:utf16, :little})

    assert Charset.decode(encoded, %{content_type: "application/xhtml+xml"}) ==
             ~s|<?xml version="1.0" encoding="utf-8"?>| <> declaration(:charset, "utf-8") <> @text
  end

  defp declaration(:charset, label), do: ~s|<meta charset="#{label}">|

  defp declaration(:content, label),
    do: ~s|<meta http-equiv="content-type" content="text/html; charset=#{label}">|
end
