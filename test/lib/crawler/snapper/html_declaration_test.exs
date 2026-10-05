defmodule Crawler.Snapper.HtmlDeclarationTest do
  use Crawler.OfflineLinkCase, async: true

  alias Crawler.Charset
  alias Crawler.HTMLSpans
  alias Crawler.Parser.HtmlParser

  for declaration <- [
        ~s|<!bogus ">|,
        ~s|<?bogus ">|,
        ~s|<?bogus x=">|,
        ~s|<!DOCTYPE html ">|,
        ~s|<!DOCTYPE html PUBLIC "a>|,
        ~s|<!DOCTYPE html SYSTEM 'a>|
      ] do
    test "#{declaration} ends before its following real anchor regardless of quotes" do
      declaration = unquote(declaration)
      source = declaration <> ~s|<a href="next">real</a>|
      target = Linker.offline_link(@page, "http://example.com/blog/next")

      assert source |> HtmlParser.parse(%{}) |> Floki.attribute("href") == ["next"]
      assert rewrite(source, @page) == declaration <> ~s|<a href="#{target}">real</a>|
    end

    test "#{declaration} cannot hide a following charset declaration" do
      declaration = unquote(declaration)

      source =
        declaration <>
          ~s|<meta charset="latin1"><a href="caf| <>
          <<0xE9>> <>
          ~s|">caf| <>
          <<0xE9>> <>
          ~s|</a>|

      expected = declaration <> ~s|<meta charset="utf-8"><a href="café">café</a>|
      assert Charset.decode(source, %{content_type: "text/html"}) == expected
    end
  end

  for doctype <- [
        ~s|<!DOCTYPE html PUBLIC "public identifier" 'system identifier'>|,
        ~s|<!DOCTYPE html SYSTEM "system identifier">|
      ] do
    test "#{doctype} and adjacent comments and foreign CDATA retain their source" do
      prefix = unquote(doctype) <> ~s|<!-- <a href="next"> -->|

      cdata = ~s|<svg><![CDATA[x><a href="next">]]></svg>|
      source = prefix <> cdata <> ~s|<a href="next">real</a>|
      target = Linker.offline_link(@page, "http://example.com/blog/next")

      assert source |> HtmlParser.parse(%{}) |> Floki.attribute("href") == ["next"]
      assert rewrite(source, @page) == prefix <> cdata <> ~s|<a href="#{target}">real</a>|
    end
  end

  test "parser declaration normalization uses the same attribute and raw-text boundaries" do
    opaque =
      ~s|<!-- <?bogus x="> --><i title='<?bogus x=">'></i>| <>
        ~s|<script>"<!DOCTYPE html PUBLIC 'a>"</script>| <>
        ~s|<style>/* <?bogus x="> */</style>| <>
        ~s|<svg><![CDATA[<?bogus x=">]]></svg>|

    assert HTMLSpans.parser_source(opaque) == opaque
  end

  test "XHTML XML declaration conversion and discovery preserve the original source" do
    declaration = ~s|<?xml version="1.0" encoding="latin1"?>|
    source = declaration <> ~s|<a href="caf| <> <<0xE9>> <> ~s|">go</a>|
    decoded = Charset.decode(source, %{content_type: "application/xhtml+xml"})
    expected = ~s|<?xml version="1.0" encoding="utf-8"?><a href="café">go</a>|
    target = Linker.offline_link(@page, "http://example.com/blog/café")

    assert decoded == expected
    assert decoded |> HtmlParser.parse(%{}) |> Floki.attribute("href") == ["café"]

    assert rewrite(decoded, @page, "application/xhtml+xml") ==
             ~s|<?xml version="1.0" encoding="utf-8"?><a href="#{target}">go</a>|
  end
end
