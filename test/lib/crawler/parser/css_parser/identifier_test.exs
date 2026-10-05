defmodule Crawler.Parser.CssParser.IdentifierTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.CssParser
  alias Crawler.Parser.CssParser.Identifier
  alias Crawler.Parser.CssParser.Scanner

  test "hex escapes decode Unicode while preserving the original delimiter and tail" do
    for {raw, decoded} <- [
          {~S|caf\00e9|, "café"},
          {~S|\3BB-name|, "λ-name"},
          {~S|\1f642-name|, "🙂-name"},
          {~S|\10FFFF-name|, <<0x10FFFF::utf8>> <> "-name"},
          {~S|\0000750rl|, "u0rl"}
        ] do
      tail = "(remaining/* text */)"
      assert {^decoded, ^tail} = Identifier.take(raw <> tail)
    end
  end

  test "escaped identifiers retain comment byte positions after optional escape whitespace" do
    for whitespace <- [" ", "\t", "\n", "\r", "\r\n", "\f"] do
      raw = "u\\000072" <> whitespace <> "l"
      payload = "(raw/*draft.png);"
      comment = "/* external café */"
      suffix = ~s|.b{background:url("real.png")}|
      source = raw <> payload <> comment <> suffix

      assert {"url", ^payload} = Identifier.take(raw <> payload)
      assert [{start, length}] = Scanner.comment_spans(source)
      assert start == byte_size(raw <> payload)
      assert binary_part(source, start, length) == comment

      assert CssParser.parse(source) == [
               {"link", [{"href", "raw/*draft.png"}], []},
               {"link", [{"href", "real.png"}], []}
             ]
    end
  end

  test "zero, surrogate, and out-of-range escapes use replacement characters" do
    for raw <- [~S|\0tag|, ~S|\D800 tag|, ~S|\dfff tag|, ~S|\110000tag|, ~S|\FFFFFFtag|] do
      assert {"�tag", ":value"} = Identifier.take(raw <> ":value")
    end
  end

  test "simple escapes keep Unicode and escaped punctuation within the identifier" do
    for {raw, decoded} <- [
          {"name\\λ", "nameλ"},
          {~S|a\)b|, "a)b"},
          {~S|a\+b|, "a+b"},
          {~S|a\\b|, "a\\b"}
        ] do
      assert {^decoded, "(tail)"} = Identifier.take(raw <> "(tail)")
      source = raw <> "(tail)/* external */"
      assert [{start, length}] = Scanner.comment_spans(source)
      assert start == byte_size(raw <> "(tail)")
      assert binary_part(source, start, length) == "/* external */"
    end
  end

  test "an invalid newline escape stops the identifier without creating a URL function" do
    for newline <- ["\n", "\r", "\r\n", "\f"] do
      tail = newline <> "rl(value)"
      assert {"u\\", ^tail} = Identifier.take("u\\" <> tail)

      source = "u\\" <> tail <> ~s|;.b{background:url("real.png") }|
      assert CssParser.parse(source) == [{"link", [{"href", "real.png"}], []}]
    end
  end

  test "EOF and malformed bytes terminate without dropping the following raw tail" do
    assert Identifier.take("") == {"", ""}
    assert Identifier.take("\\") == {"\\", ""}
    assert Identifier.take("name\\") == {"name\\", ""}

    invalid = "name\\" <> <<0xFF>>
    assert {"name" <> <<0xFF>>, "(tail)"} == Identifier.take(invalid <> "(tail)")

    source = invalid <> ~s|;.b{background:url("real.png") }|
    assert CssParser.parse(source) == [{"link", [{"href", "real.png"}], []}]
  end
end
