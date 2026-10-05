defmodule Crawler.Parser.CssParser.UrlEofTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.CssParser
  alias Crawler.Snapper.LinkReplacer.Css

  test "valid URL values at EOF retain exact spans and rewrite without adding source delimiters" do
    for prefix <- [".a{background:url(", "@import url("],
        {payload, value, quote} <- [
          {"image.png", "image.png", ""},
          {"/*draft*/image.png", "/*draft*/image.png", ""},
          {~S|foo\)bar.png|, "foo)bar.png", ""},
          {~s|"image.png"|, "image.png", "\""},
          {"'image.png'", "image.png", "'"}
        ],
        whitespace <- ["", " \t\n\r\f"] do
      source = prefix <> " \t" <> payload <> whitespace

      assert [%{value: ^value, quote: ^quote, start: start, length: length}] =
               CssParser.spans(source)

      assert start == byte_size(prefix <> " \t")
      assert length == byte_size(payload)
      assert binary_part(source, start, length) == payload
      assert CssParser.parse(source) == [{"link", [{"href", value}], []}]

      assert Css.replace(source, value, "saved.png", entity_quotes: false) ==
               prefix <> " \t" <> quote <> "saved.png" <> quote <> whitespace
    end
  end

  test "a terminal unquoted escape at EOF decodes to a replacement character" do
    source = ".a{background:url(image.png\\"
    assert [%{value: "image.png�", start: start, length: length}] = CssParser.spans(source)
    assert binary_part(source, start, length) == "image.png\\"

    assert Css.replace(source, "image.png�", "saved.png", entity_quotes: false) ==
             ".a{background:url(saved.png"
  end

  test "quoted URL functions at EOF retain trailing comments and source entity quotes" do
    for suffix <- ["/* after */", " \t/* after */\n", "/* unfinished"] do
      source = ~s|@import url(&quot;theme.css&quot;| <> suffix

      assert [%{value: "theme.css", start: start, length: length}] =
               CssParser.spans(source, entity_quotes: true)

      assert binary_part(source, start, length) == "&quot;theme.css&quot;"

      assert Css.replace(source, "theme.css", "saved.css") ==
               ~s|@import url(&quot;saved.css&quot;| <> suffix
    end
  end

  test "strings at EOF remain discoverable and rewrites preserve the missing closing quote" do
    for prefix <- ["@import ", "@import url(", ".a{background:url(", ".a{background:image-set("],
        quote <- ["\"", "'"],
        {payload, value} <- [
          {"theme.css", "theme.css"},
          {~S|the\6d e.css|, "theme.css"},
          {"theme.css\\", "theme.css"},
          {"theme.css\\\n", "theme.css"}
        ] do
      source = prefix <> quote <> payload

      assert [%{value: ^value, quote: ^quote, closed?: false, start: start, length: length}] =
               CssParser.spans(source)

      assert start == byte_size(prefix)
      assert binary_part(source, start, length) == quote <> payload
      assert CssParser.parse(source) == [{"link", [{"href", value}], []}]

      assert Css.replace(source, value, "saved.css", entity_quotes: false) ==
               prefix <> quote <> "saved.css"
    end
  end

  test "entity-quoted strings at EOF retain their original opening quote and exact source span" do
    for quote <- ["&quot;", "&apos;", "&#34;", "&#39;", "&#x22;", "&#x27;"] do
      source = "@import url(" <> quote <> "theme.css"

      assert [%{value: "theme.css", closed?: false, start: start, length: length}] =
               CssParser.spans(source, entity_quotes: true)

      assert binary_part(source, start, length) == quote <> "theme.css"

      assert Css.replace(source, "theme.css", "saved.css") ==
               "@import url(" <> quote <> "saved.css"
    end
  end

  test "unescaped newlines still reject strings before EOF" do
    for prefix <- ["@import ", "@import url(", ".a{background:url(", ".a{background:image-set("],
        quote <- ["\"", "'"],
        newline <- ["\n", "\r\n", "\f"] do
      source = prefix <> quote <> "image" <> newline <> ".png"
      assert CssParser.spans(source) == []
      assert Css.replace(source, "image", "saved.png", entity_quotes: false) == source
    end
  end

  test "EOF does not turn malformed URL payloads into resources" do
    payloads = [
      ~s|image".png|,
      "image'.png",
      "image(.png",
      ~s|/*draft*/"image.png"|,
      "image.png more.png",
      "image.png /**/",
      "image.png ;url(hidden.png",
      ~s|"image\n.png"|
    ]

    payloads = payloads ++ Enum.map(["\n", "\r\n", "\f"], &"image\\#{&1}.png")

    for prefix <- [".a{background:url(", "@import url("], payload <- payloads do
      source = prefix <> payload
      assert CssParser.spans(source) == []
      assert CssParser.parse(source) == []

      for target <- [payload, "image.png", "more.png", "hidden.png"] do
        assert Css.replace(source, target, "saved.png", entity_quotes: false) == source
      end
    end
  end
end
