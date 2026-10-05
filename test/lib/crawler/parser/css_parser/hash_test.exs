defmodule Crawler.Parser.CssParser.HashTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.CssParser
  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Snapper.LinkReplacer.Css

  test "hash names cannot create URL functions or image-set candidates" do
    for hash <- ["#url", ~S|#\75rl|, ~S|#u\72l|, ~S|#\000075 rl|, "#0url", "#éurl"] do
      opaque = ".x{--opaque:#{hash}(hidden.png);"
      source = opaque <> "background:url(real.png)}"
      assert CssParser.parse(source) == [{"link", [{"href", "real.png"}], []}]
      assert [%{start: start, length: length, value: "real.png"}] = CssParser.spans(source)
      assert binary_part(source, start, length) == "real.png"
      assert Css.replace(source, "hidden.png", "wrong.png", entity_quotes: false) == source

      assert Css.replace(source, "real.png", "saved.png", entity_quotes: false) ==
               opaque <> "background:url(saved.png)}"
    end

    for hash <- ["#image-set", ~S|#\69mage-set|, "#-webkit-image-set"] do
      source = "#{hash}(\"hidden.png\" 1x);image-set(\"real.png\" 1x)"
      assert CssParser.parse(source) == [{"link", [{"href", "real.png"}], []}]
      assert Css.replace(source, "hidden.png", "wrong.png", entity_quotes: false) == source
    end
  end

  test "hash tokens preserve source bytes and comment positions around real functions" do
    opaque = ~S|.x{--opaque:#\75rl(real.png);--name:#1\000075 rl;}|
    comment = "/* café */"
    source = opaque <> comment <> ~S|.y{background:u\72l(real.png)}|
    assert Scanner.comment_spans(source) == [{byte_size(opaque), byte_size(comment)}]

    assert Css.replace(source, "real.png", "saved.png", entity_quotes: false) ==
             opaque <> comment <> ~S|.y{background:u\72l(saved.png)}|
  end

  test "real URL functions remain discoverable after hash delimiters and inside simple blocks" do
    for hash <- ["# ", "#;", "#\\\n", "#\\\r\n", "#\\\f"] do
      assert CssParser.parse(hash <> "url(real.png)") == [{"link", [{"href", "real.png"}], []}]
    end

    assert CssParser.parse("#url(url(real.png))") == [{"link", [{"href", "real.png"}], []}]

    assert CssParser.parse(~s|image-set(#url(hidden.png) 1x,"real.png" 2x)|) ==
             [{"link", [{"href", "real.png"}], []}]
  end
end
