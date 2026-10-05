defmodule Crawler.Charset.LiteralQuotesTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset
  alias Crawler.Charset.CSS
  alias Crawler.Charset.HTML
  alias Crawler.Charset.Labels

  test "literal inner quotes do not hide a later supported meta declaration" do
    for {outer, inner} <- [{"\"", "'"}, {"'", "\""}],
        label <- [inner <> "latin1", "latin1" <> inner, inner <> "latin1" <> inner] do
      source =
        "<meta charset=" <> outer <> label <> outer <> ~s|><meta charset="utf-8">café|

      decoded =
        "<meta charset=" <> outer <> "utf-8" <> outer <> ~s|><meta charset="utf-8">café|

      assert HTML.charset(source) == "utf-8"
      assert Charset.decode(source, %{content_type: "text/html"}) == decoded
    end
  end

  test "literal quotes in an XML label allow a supported XHTML meta declaration" do
    for label <- ["'latin1", "latin1'", "'latin1'"] do
      source =
        ~s|<?xml version="1.0" encoding="#{label}"?><meta charset="utf-8">café|

      assert HTML.xml_charset(source) == nil

      assert Charset.decode(source, %{content_type: "application/xhtml+xml"}) ==
               ~s|<?xml version="1.0" encoding="utf-8"?><meta charset="utf-8">café|
    end
  end

  test "declaration extractors still remove real HTTP CSS and XML syntax quotes" do
    for quote <- ["\"", "'"] do
      field = "text/plain; charset=" <> quote <> "latin1" <> quote
      assert Labels.charset_param(field) == "latin1"

      assert Charset.decode("caf" <> <<0xE9>>, %{
               content_type: "text/plain",
               headers: [{"content-type", field}]
             }) == "café"
    end

    css = ~s|@charset "latin1"; .caf| <> <<0xE9>> <> "{}"
    assert CSS.charset(css) == "latin1"
    assert Charset.decode(css, %{content_type: "text/css"}) == ~s|@charset "utf-8"; .café{}|

    xml = ~s|<?xml version="1.0" encoding="latin1"?><p>caf| <> <<0xE9>> <> "</p>"
    assert HTML.xml_charset(xml) == "latin1"

    assert Charset.decode(xml, %{content_type: "application/xhtml+xml"}) ==
             ~s|<?xml version="1.0" encoding="utf-8"?><p>café</p>|
  end
end
