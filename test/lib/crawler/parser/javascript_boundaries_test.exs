defmodule Crawler.Parser.JavascriptBoundariesTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.JsParser
  alias Crawler.Parser.JsParser.Identifier
  alias Crawler.Parser.JsParser.Scanner
  alias Crawler.Parser.JsParser.StringLiteral

  @real ~S|import("./real.js");const r=/x/;|
  @decoy ~S|/import(".\/hidden.js")/|

  test "class method and static-block closes restore the next member header" do
    for first <- ["f(){}", "static{}", "static{{const n=1;}}", "get f(){}", "set f(value){}"],
        {next, operand} <- [{"async g()", "await"}, {"* g()", "yield"}, {"async * g()", "await"}],
        goal <- [:script, :module] do
      source = "class C{#{first}#{next}{#{operand} #{@decoy};}}" <> @real
      assert_specs(source, ["./real.js"], goal)
    end
  end

  test "an enclosing conditional colon closes an arrow expression" do
    source = "const await=4;const f=ready ? async()=>await #{@decoy} : await / 2;" <> @real
    assert_specs(source, ["./real.js"])

    source =
      "const await=4;const f=ready ? async()=>inner ? await #{@decoy} : await #{@decoy}" <>
        " : await / 2;" <> @real

    assert_specs(source, ["./real.js"])

    source = "const f=async()=>ready ? await #{@decoy} : await #{@decoy};" <> @real
    assert_specs(source, ["./real.js"])

    source = "function* g(){const f=ready ? ()=>yield / 2 : yield #{@decoy};#{@real}}"
    assert_specs(source, ["./real.js"])
  end

  test "template interpolation restores enclosing async and generator roles" do
    for {header, operand} <- [{"async function f()", "await"}, {"function* f()", "yield"}],
        interpolation <- [~S|()=>1|, ~S|()=>import("./inside.js")|, ~S|`${()=>1}`|] do
      source = "#{header}{const text=`${#{interpolation}}`;#{operand} #{@decoy};#{@real}}"

      expected =
        if String.contains?(interpolation, "inside.js"),
          do: ["./inside.js", "./real.js"],
          else: ["./real.js"]

      assert_specs(source, expected)
    end

    source = "const await=4;const text=`${async()=>await #{@decoy}}`;const n=await / 2;" <> @real
    assert_specs(source, ["./real.js"])

    source =
      "const await=4;const text=`${`${async()=>await #{@decoy}}`}`;const n=await / 2;" <> @real

    assert_specs(source, ["./real.js"])
  end

  test "computed method names retain their outer header across nested containers" do
    for key <- [
          "key({a:1})",
          "key([{},{}])",
          "key(class{f(){}async g(){await #{@decoy};}})",
          "key({async f(){await #{@decoy};},*[name](){yield #{@decoy};}})"
        ],
        {prefix, operands} <- [
          {"async", ["await"]},
          {"*", ["yield"]},
          {"async *", ["await", "yield"]}
        ],
        container <- ["const object=", "class C"],
        goal <- [:script, :module] do
      body = Enum.map_join(operands, ";", &"#{&1} #{@decoy}")
      source = "#{container}{#{prefix} [#{key}](){#{body};}};" <> @real
      assert_specs(source, ["./real.js"], goal)
    end

    source = "const object={[key({async f(){await #{@decoy};}})](){const n=await / 2;#{@real}}};"
    assert_specs(source, ["./real.js"])
  end

  test "braced Unicode escape validity follows codepoint value and preserves raw spans" do
    for zeros <- [7, 30, 200] do
      escape = "\\u{" <> String.duplicate("0", zeros) <> "2f}"
      source = "import(\".#{escape}real.js\");"
      assert_specs(source, ["./real.js"], :module)
      assert [{at, length, "./real.js"}] = JsParser.spans(source)
      assert binary_part(source, at, length) == ".#{escape}real.js"

      raw = "\\u{" <> String.duplicate("0", zeros) <> "61}wait"
      assert {:ok, ^raw, "await", ";"} = Identifier.take(raw <> ";")
      assert_specs("const #{raw}=4;const n=await / 2;" <> @real, ["./real.js"])
    end

    assert StringLiteral.decode(~S|\u{00000000000010FFFF}|) == {:ok, <<0x10FFFF::utf8>>}
    assert StringLiteral.decode(~S|\u{0000000000001F600}|) == {:ok, "😀"}
    assert StringLiteral.decode(~S|\u{0000000000000000}|) == {:ok, <<0>>}

    for invalid <- [
          ~S|\u{}|,
          ~S|\u{0000000000110000}|,
          ~S|\u{000000000000D800}|,
          ~S|\u{000000000000zz}|
        ] do
      assert StringLiteral.decode(invalid) == :error
      assert Identifier.take(invalid) == :none
    end
  end

  defp assert_specs(source, expected, goal \\ :script) do
    assert JsParser.specs(source, goal) == expected, source
    spans = JsParser.spans(source, goal)
    assert Enum.map(spans, &elem(&1, 2)) == expected
    {masked, _strings} = Scanner.scan(source, goal)
    assert byte_size(masked) == byte_size(source)
  end
end
