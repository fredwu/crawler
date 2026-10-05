defmodule Crawler.Parser.CssParser.UrlCommentsTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.CssParser
  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Snapper.LinkReplacer.Css

  test "unquoted URL tokens keep leading and trailing comment-looking payload bytes" do
    for {payload, value} <- [
          {"/*draft*/image.png", "/*draft*/image.png"},
          {"/**/image.png", "/**/image.png"},
          {"image.png/**/", "image.png/**/"},
          {~S|/*draft*/\"image.png|, ~s|/*draft*/"image.png|}
        ],
        whitespace <- ["", " ", "\t\n\r\f"] do
      source = "url(#{whitespace}#{payload}#{whitespace})"
      assert [%{value: ^value, quote: "", start: start, length: length}] = CssParser.spans(source)
      assert binary_part(source, start, length) == payload
      assert Scanner.comment_spans(source) == []

      assert Css.replace(source, value, "saved.png", entity_quotes: false) ==
               "url(#{whitespace}saved.png#{whitespace})"

      assert Css.replace(source, "image.png", "wrong.png", entity_quotes: false) == source
    end
  end

  test "comments before quotes or after unquoted whitespace make bad URL tokens" do
    for invalid <- [
          ~s|url(/*draft*/"image.png")|,
          ~s|url( /*draft*/'image.png')|,
          ~s|url(/*draft*/ "image.png")|,
          "url(image.png /**/)",
          "url(image.png\t/*draft*/)",
          ~s|url(image.png /*draft*/"hidden.png")|,
          "url(/*draft*/image.png /**/)"
        ] do
      source = invalid <> ";url(real.png)"
      assert Enum.map(CssParser.spans(source), & &1.value) == ["real.png"]
      assert Scanner.comment_spans(source) == []

      for target <- ["image.png", "hidden.png", "/*draft*/image.png"] do
        assert Css.replace(source, target, "wrong.png", entity_quotes: false) == source
      end

      assert Css.replace(source, "real.png", "saved.png", entity_quotes: false) ==
               invalid <> ";url(saved.png)"
    end
  end

  test "quoted URL functions allow comment trivia after the closing quote" do
    for quote <- ["\"", "'"] do
      source = "url( \t#{quote}image.png#{quote}/* first */ \n/* second */)"

      assert [%{value: "image.png", quote: ^quote, start: start, length: length}] =
               CssParser.spans(source)

      assert binary_part(source, start, length) == "#{quote}image.png#{quote}"

      assert Enum.map(Scanner.comment_spans(source), fn {start, length} ->
               binary_part(source, start, length)
             end) == ["/* second */", "/* first */"]

      assert Css.replace(source, "image.png", "saved.png", entity_quotes: false) ==
               "url( \t#{quote}saved.png#{quote}/* first */ \n/* second */)"
    end
  end

  test "HTML entity decoding keeps the URL token choice and exact source spans" do
    invalid = ~s|url(/*draft*/&quot;image.png&quot;),url(image.png /**/)|
    source = invalid <> ~s|,url( &quot;real.png&quot;/* after */)|

    assert [%{value: "real.png", start: start, length: length}] =
             CssParser.spans(source, entity_quotes: true)

    assert binary_part(source, start, length) == "&quot;real.png&quot;"
    assert Css.replace(source, "image.png", "wrong.png") == source

    assert Css.replace(source, "real.png", "saved.png") ==
             invalid <> ~s|,url( &quot;saved.png&quot;/* after */)|
  end
end
