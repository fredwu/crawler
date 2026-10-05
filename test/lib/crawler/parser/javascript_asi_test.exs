defmodule Crawler.Parser.JavascriptAsiTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.JsParser
  alias Crawler.Parser.JsParser.Scanner

  @real ~S|import("./real.js");const r=/x/;|
  @decoy ~S|/import(".\/hidden.js")/|

  test "confirmed ASI ends concise async arrows before the next statement" do
    for gap <- ["\n", "\r\n", "/*\n*/", "// comment\n", <<0x2028::utf8>>],
        head <- ["async()=>1", "async()=>async()=>1", "async()=>function named(){}"] do
      source = "var await=4;const f=#{head}#{gap}const n=await / 2;" <> @real
      assert_specs(source, :script)
    end

    for operator <- ["++", "--"], gap <- ["\n", "/*\n*/"] do
      source = "var await=4;const f=async()=>value#{gap}#{operator}await / 2;" <> @real
      assert_specs(source, :script)
    end

    source = "async function f(){const inner=()=>1\nawait #{@decoy};#{@real}}"
    assert_specs(source, :script)
    assert_specs(source, :module)

    source = "const f=()=>1\nawait #{@decoy};" <> @real
    assert_specs(source, :module)
  end

  test "continued multiline arrow expressions keep their async role" do
    for continuation <- [
          "value\n(await #{@decoy})",
          "value\n[await #{@decoy}]",
          "value\n.then(await #{@decoy})",
          "value\n + await #{@decoy}",
          "value\n - await #{@decoy}",
          "value/*\n*/ + + await #{@decoy}",
          "value/*\n*/ - - await #{@decoy}",
          "value\n in object && await #{@decoy}",
          "value\n instanceof Object && await #{@decoy}",
          "tag\n`${await #{@decoy}}`",
          "ready ? value\n : await #{@decoy}",
          "function\n named(){return 1;}",
          "class\n C{async f(){await #{@decoy};}}"
        ] do
      source = "const f=async()=>#{continuation};" <> @real
      assert_specs(source, :script)
      assert_specs(source, :module)
    end
  end

  test "confirmed class field ASI restores member headers" do
    for gap <- ["\n", "/*\n*/", "// comment\n", <<0x2029::utf8>>],
        field <- ["x", "x=1", "x=async()=>1", "x=()=>{}", "static x=1", "function", "class"],
        method <- ["async f()", "async * f()", ~s|async "f"()|, "async [name]()"],
        goal <- [:script, :module] do
      source = "class C{#{field}#{gap}#{method}{await #{@decoy};}}" <> @real
      assert_specs(source, goal)
    end
  end

  test "multiline class fields and headers retain their own grammar" do
    for member <- [
          "x=async()=>value\n(await #{@decoy})",
          "x=async()=>value\n[await #{@decoy}]",
          "x=async()=>value\n + await #{@decoy}",
          "x=async()=>tag\n`${await #{@decoy}}`",
          "x=async()=>ready ? value\n : await #{@decoy}",
          "async\n[name](){const n=1 / 2;}",
          "async [\nkey({a:1})\n](){await #{@decoy};}",
          "async *\nf(){await #{@decoy};yield #{@decoy};}",
          "get\nf(){return 1;}"
        ],
        goal <- [:script, :module] do
      source = "class C{#{member};async g(){await #{@decoy};}}" <> @real
      assert_specs(source, goal)
    end
  end

  defp assert_specs(source, goal) do
    assert JsParser.specs(source, goal) == ["./real.js"], source
    assert [{at, length, "./real.js"}] = JsParser.spans(source, goal)
    assert binary_part(source, at, length) == "./real.js"
    {masked, _strings} = Scanner.scan(source, goal)
    assert byte_size(masked) == byte_size(source)
  end
end
