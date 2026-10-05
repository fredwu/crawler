defmodule Crawler.Parser.JsContextTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.JsParser
  alias Crawler.Parser.JsParser.Scanner

  @white_space [0x09, 0x0B, 0x0C, 0x20, 0xA0, 0x1680] ++
                 Enum.to_list(0x2000..0x200A) ++ [0x202F, 0x205F, 0x3000, 0xFEFF]
  @after_division ~S|;import("./real.js");const r=/x/;|
  @regex ~S|/import(".\/hidden.js")/.exec(text)|

  test "of is an ordinary identifier outside a for-of separator" do
    for expression <- [
          "const of=4;const n=of / 2",
          "const of=4;const n=πof / 2",
          "const of=4;const n=obj.of / 2",
          "const of=4;const n=obj?. /* café */ of / 2",
          "const of=4;for (let n=of / 2;n<2;n++) {}",
          "for (let of=4;of / 2;of--) {}",
          "for (of / 2;ready;) {}",
          "for (const value of of / 2) {}",
          "for (const value in of / 2) {}",
          "for (const value of (of / 2)) {}",
          "for (const value of values.map(of => of / 2)) {}"
        ] do
      source = expression <> @after_division
      assert JsParser.specs(source) == ["./real.js"], source
      assert_byte_spans(source)
    end
  end

  test "for-of separators permit regexes once and retain nested header context" do
    for binding <- ["value", "of", "const value", "let of", "const {of}", "const [of]", "obj.of"],
        header <- ["for", "for await"] do
      source = "#{header} (#{binding} of #{@regex}) {}" <> @after_division
      assert JsParser.specs(source) == ["./real.js"], source
      assert_byte_spans(source)
    end

    source =
      "for (const outer of (() => { for (const inner of #{@regex}) {} return of / 2; })()) {}" <>
        @after_division

    assert JsParser.specs(source) == ["./real.js"]
    assert_byte_spans(source)
  end

  test "ECMAScript whitespace separates imports and exports without shifting byte spans" do
    for char <- @white_space do
      gap = <<char::utf8>>

      source =
        "const π = 1;#{gap}import#{gap}\"./side.js\";" <>
          "#{gap}import#{gap}π#{gap}from#{gap}\"./from.js\";" <>
          "#{gap}export#{gap}{π}#{gap}from#{gap}\"./named.js\";" <>
          "#{gap}export#{gap}*#{gap}from#{gap}\"./star.js\";" <>
          "#{gap}import#{gap}(#{gap}\"./dynamic.js\"#{gap});"

      assert Enum.sort(JsParser.specs(source)) ==
               ["./dynamic.js", "./from.js", "./named.js", "./side.js", "./star.js"]

      assert_byte_spans(source)
      {masked, _strings} = Scanner.scan(source)
      if gap != " ", do: refute(masked =~ gap)
    end
  end

  test "whitespace leaves Unicode identifiers and property calls as single tokens" do
    for char <- @white_space do
      gap = <<char::utf8>>

      source =
        ~S|πimport("./fake.js"); importπ("./fake.js"); a\u200Cimport("./fake.js");| <>
          ~s|obj.#{gap}import("./fake.js");import#{gap}"./real.js";|

      assert JsParser.specs(source) == ["./real.js"]
      assert_byte_spans(source)
    end
  end

  test "non-ECMAScript spacing characters and whitespace inside literals are preserved" do
    for char <- [0x85, 0x180E, 0x200B] do
      spacing = <<char::utf8>>
      {masked, _strings} = Scanner.scan(";#{spacing}import \"./real.js\";")
      assert masked =~ spacing
    end

    source = "import \"./file\uFEFFname.js\";"
    assert JsParser.specs(source) == ["./file\uFEFFname.js"]
    assert_byte_spans(source)
  end

  test "whitespace does not create a line boundary or end a line comment" do
    for char <- @white_space do
      gap = <<char::utf8>>
      source = "// hidden#{gap}import \"./hidden.js\";\nimport \"./real.js\";"
      assert JsParser.specs(source) == ["./real.js"]

      source =
        "function f() { return#{gap}{} / 2; }" <>
          @after_division

      assert JsParser.specs(source) == ["./real.js"]
      assert_byte_spans(source)
    end
  end

  test "line terminators retain statement and comment boundaries beside interior FEFF" do
    for terminator <- ["\n", "\r", "\r\n", <<0x2028::utf8>>, <<0x2029::utf8>>] do
      source =
        "// import \"./hidden.js\";#{terminator}\uFEFFimport \"./side.js\";" <>
          "function f() { return\uFEFF#{terminator}{} /[\"']/.test(text); }" <>
          @after_division

      assert Enum.sort(JsParser.specs(source)) == ["./real.js", "./side.js"]
      assert_byte_spans(source)
    end
  end

  defp assert_byte_spans(source) do
    {masked, _strings} = Scanner.scan(source)
    assert byte_size(masked) == byte_size(source)

    for {start, length, specifier} <- JsParser.spans(source) do
      assert binary_part(source, start, length) == specifier
    end
  end
end
