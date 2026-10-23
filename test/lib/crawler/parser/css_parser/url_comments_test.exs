defmodule Crawler.Parser.CssParser.UrlCommentsTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis
  alias Crawler.Parser.CssParser
  alias Crawler.Parser.CssParser.Scanner

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

      assert render_css(source, value, "saved.png") ==
               "url(#{whitespace}saved.png#{whitespace})"

      assert render_css(source, "image.png", "wrong.png") == source
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
        assert render_css(source, target, "wrong.png") == source
      end

      assert render_css(source, "real.png", "saved.png") ==
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

      assert render_css(source, "image.png", "saved.png") ==
               "url( \t#{quote}saved.png#{quote}/* first */ \n/* second */)"
    end
  end

  test "HTML entity decoding keeps the URL token choice and exact source spans" do
    invalid = ~s|url(/*draft*/&quot;image.png&quot;),url(image.png /**/)|
    source = invalid <> ~s|,url( &quot;real.png&quot;/* after */)|

    assert [%{value: "real.png", start: start, length: length}] =
             CssParser.spans(source, entity_quotes: true)

    assert binary_part(source, start, length) == "&quot;real.png&quot;"

    assert render_css(attribute(source), "image.png", "wrong.png", "text/html") ==
             attribute(source)

    assert render_css(attribute(source), "real.png", "saved.png", "text/html") ==
             attribute(invalid <> ~s|,url( &quot;saved.png&quot;/* after */)|)
  end

  defp attribute(source), do: ~s|<div style="#{source}"></div>|

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
