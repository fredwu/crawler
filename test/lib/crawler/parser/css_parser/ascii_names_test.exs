defmodule Crawler.Parser.CssParser.AsciiNamesTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.CssParser
  alias Crawler.Parser.CssParser.Identifier
  alias Crawler.Snapper.LinkReplacer.Css

  test "Unicode lookalike function names remain unknown after escape decoding" do
    for name <- ["-webKit-image-set", ~S|-web\212A it-image-set|, "image-ſet", "ＵＲＬ"] do
      unknown = ~s|#{name}("real.png" 1x)|
      source = unknown <> ";background:url(real.png)"
      assert CssParser.parse(unknown) == []
      assert [%{value: "real.png", start: start, length: length}] = CssParser.spans(source)
      assert start == byte_size(unknown <> ";background:url(")
      assert binary_part(source, start, length) == "real.png"

      assert Css.replace(source, "real.png", "saved.png", entity_quotes: false) ==
               unknown <> ";background:url(saved.png)"
    end

    assert Identifier.take("-webKit-image-set(tail)") == {"-webKit-image-set", "(tail)"}
    assert Identifier.take(~S|-web\212A it-image-set(tail)|) == {"-webKit-image-set", "(tail)"}
  end

  test "ASCII uppercase and escaped ASCII function names retain exact source bytes" do
    for {name, descriptor} <- [
          {"URL", ""},
          {~S|\55RL|, ""},
          {"IMAGE-SET", " 1x"},
          {~S|\49 MAGE-SET|, " 1x"},
          {"-WEBKIT-IMAGE-SET", " 1x"},
          {~S|-WEB\4B IT-IMAGE-SET|, " 1x"}
        ] do
      source = ~s|#{name}("real.png"#{descriptor})|
      assert CssParser.parse(source) == [{"link", [{"href", "real.png"}], []}]
      assert [%{start: start, length: length, value: "real.png"}] = CssParser.spans(source)
      assert binary_part(source, start, length) == ~s|"real.png"|

      assert Css.replace(source, "real.png", "saved.png", entity_quotes: false) ==
               ~s|#{name}("saved.png"#{descriptor})|
    end
  end

  test "at-keyword matching folds ASCII letters without changing Unicode lookalikes" do
    for name <- ["IMPORT", ~S|\49 MPORT|, ~S|I\4d PORT|] do
      source = ~s|@#{name} "theme.css";|
      assert CssParser.parse(source) == [{"link", [{"href", "theme.css"}], []}]

      assert Css.replace(source, "theme.css", "saved.css", entity_quotes: false) ==
               ~s|@#{name} "saved.css";|
    end

    for name <- ["İMPORT", "ＩＭＰＯＲＴ", ~S|\130 MPORT|] do
      source = ~s|@#{name} "theme.css";|
      assert CssParser.parse(source) == []
      assert Css.replace(source, "theme.css", "saved.css", entity_quotes: false) == source
    end
  end
end
