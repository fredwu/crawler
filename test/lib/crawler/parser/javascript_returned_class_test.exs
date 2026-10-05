defmodule Crawler.Parser.JavascriptReturnedClassTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.JsParser
  alias Crawler.Parser.JsParser.Scanner

  @real ~S|import("./real.js");const r=/x/;|
  @decoy ~S|/import(".\/hidden.js")/|

  test "returned class methods establish their own contextual grammar" do
    for arrow <- ["()=>", "async()=>"],
        header <- ["class", "class Named", "class Named extends factory({a:1})"],
        {method, operands} <- [
          {"async m", "await #{@decoy};"},
          {"*m", "yield #{@decoy};"},
          {"async *m", "await #{@decoy};yield #{@decoy};"}
        ],
        goal <- [:script, :module] do
      source = "const f=#{arrow}#{header}{#{method}(){#{operands}}};" <> @real
      assert_specs(source, goal)
    end

    for arrow <- ["()=>", "async()=>"], header <- ["class", "class Named"] do
      source = "var await=4;const f=#{arrow}#{header}{m(){const n=await / 2;#{@real}}};"
      assert_specs(source, :script)
    end
  end

  test "nested returned functions and class headers keep the enclosing concise arrow" do
    for arrow <- ["()=>", "async()=>", "()=>async()=>"],
        goal <- [:script, :module] do
      source =
        "const f=#{arrow}function returned(cb=()=>1){return class Named " <>
          "extends (class{async inherited(){await #{@decoy};}}){async m(){await #{@decoy};#{@real}}}};"

      assert_specs(source, goal)

      source =
        "const f=#{arrow}class\nNamed extends factory({a:1})\n" <>
          "{async m(){await #{@decoy};}} / 2;" <> @real

      assert_specs(source, goal)
    end
  end

  test "direct arrow blocks and expression boundaries retain their ownership" do
    for goal <- [:script, :module] do
      source = "const f=async()=>/*\n*/{await #{@decoy};#{@real}};"
      assert_specs(source, goal)

      source =
        "async function run(){const text=`${()=>class{async m(){await #{@decoy};}}}`;await #{@decoy};#{@real}}"

      assert_specs(source, goal)
    end

    for boundary <- ["\nconst n=await / 2;", ";const n=await / 2;"] do
      source =
        "var await=4;const f=async()=>class{async m(){await #{@decoy};}}#{boundary}" <> @real

      assert_specs(source, :script)
    end

    source =
      "var await=4;const f=ready?async()=>class{async m(){await #{@decoy};}}:await / 2;" <> @real

    assert_specs(source, :script)

    source = "var await=4;const text=`${async()=>class{m(){const n=await / 2;#{@real}}}}`;"
    assert_specs(source, :script)
  end

  defp assert_specs(source, goal) do
    assert JsParser.specs(source, goal) == ["./real.js"], source
    assert [{at, length, "./real.js"}] = JsParser.spans(source, goal)
    assert binary_part(source, at, length) == "./real.js"
    {masked, _strings} = Scanner.scan(source, goal)
    assert byte_size(masked) == byte_size(source)
  end
end
