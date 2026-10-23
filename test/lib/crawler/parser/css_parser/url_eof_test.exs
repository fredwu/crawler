defmodule Crawler.Parser.CssParser.UrlEofTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis
  alias Crawler.Parser.CssParser

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

      assert render_css(source, value, "saved.png") ==
               prefix <> " \t" <> quote <> "saved.png" <> quote <> whitespace
    end
  end

  test "a terminal unquoted escape at EOF decodes to a replacement character" do
    source = ".a{background:url(image.png\\"
    assert [%{value: "image.png�", start: start, length: length}] = CssParser.spans(source)
    assert binary_part(source, start, length) == "image.png\\"

    assert render_css(source, "image.png�", "saved.png") ==
             ".a{background:url(saved.png"
  end

  test "quoted URL functions at EOF retain trailing comments and source entity quotes" do
    for suffix <- ["/* after */", " \t/* after */\n", "/* unfinished"] do
      source = ~s|@import url(&quot;theme.css&quot;| <> suffix

      assert [%{value: "theme.css", start: start, length: length}] =
               CssParser.spans(source, entity_quotes: true)

      assert binary_part(source, start, length) == "&quot;theme.css&quot;"

      rendered = render_css(xml_style(source), "theme.css", "saved.css", "application/xhtml+xml")
      assert rendered == xml_style(~s|@import url("saved.css"| <> suffix)

      assert {:ok, analysis} =
               Analysis.analyze(rendered, %{content_type: "application/xhtml+xml"})

      [css] = for {_id, region} <- analysis.regions, region.kind == :css, do: region.source
      assert [%{value: "saved.css", quote: "\"", closed?: true}] = CssParser.spans(css)
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

      assert render_css(source, value, "saved.css") ==
               prefix <> quote <> "saved.css"
    end
  end

  test "entity-quoted strings at EOF retain their original opening quote and exact source span" do
    for quote <- ["&quot;", "&apos;", "&#34;", "&#39;", "&#x22;", "&#x27;"] do
      source = "@import url(" <> quote <> "theme.css"

      assert [%{value: "theme.css", closed?: false, start: start, length: length}] =
               CssParser.spans(source, entity_quotes: true)

      assert binary_part(source, start, length) == quote <> "theme.css"

      decoded_quote = if quote in ["&apos;", "&#39;", "&#x27;"], do: "'", else: "\""
      rendered = render_css(xml_style(source), "theme.css", "saved.css", "application/xhtml+xml")
      assert rendered == xml_style("@import url(" <> decoded_quote <> "saved.css")

      assert {:ok, analysis} =
               Analysis.analyze(rendered, %{content_type: "application/xhtml+xml"})

      [css] = for {_id, region} <- analysis.regions, region.kind == :css, do: region.source
      assert [%{value: "saved.css", quote: ^decoded_quote, closed?: false}] = CssParser.spans(css)
    end
  end

  test "unescaped newlines still reject strings before EOF" do
    for prefix <- ["@import ", "@import url(", ".a{background:url(", ".a{background:image-set("],
        quote <- ["\"", "'"],
        newline <- ["\n", "\r\n", "\f"] do
      source = prefix <> quote <> "image" <> newline <> ".png"
      assert CssParser.spans(source) == []
      assert render_css(source, "image", "saved.png") == source
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
        assert render_css(source, target, "saved.png") == source
      end
    end
  end

  defp xml_style(source), do: ~s|<style xmlns="http://www.w3.org/1999/xhtml">#{source}</style>|

  defp render_css(source, value, path, type \\ "text/css") do
    opts = %{
      url: "https://example.test/styles/main.css",
      content_type: type,
      assets: ["css", "images"]
    }

    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)

    assert {:ok, bound} =
             Analysis.bind(collection, fn ref ->
               if ref.source_role == :css and ref.context.html_tag == "link" and
                    ref.value == value,
                  do: %{fixture: :css_resource, path: path}
             end)

    assert {:ok, rendered} =
             Analysis.render(analysis, bound, fn
               %{target: %{fixture: :css_resource, path: path}} -> {:local, path}
               _ref -> :keep
             end)

    rendered
  end
end
