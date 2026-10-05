defmodule Crawler.Parser.JavascriptScopeOwnersTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.JsParser
  alias Crawler.Parser.JsParser.Scanner

  @real ~S|import("./real.js");const r=/x/;|
  @decoy ~S|/import(".\/hidden.js")/|

  test "function parameter closes select their owner through concise default arrows" do
    for parameter <- [
          "cb=()=>1",
          "cb=async()=>1",
          "cb=()=>async()=>1",
          "cb=async()=>()=>1",
          "cb=()=>function named(){}"
        ],
        header <- ["function f", "async function f", "function* f"],
        goal <- [:script, :module] do
      operand = if header == "async function f", do: "await #{@decoy};", else: ""
      operand = if header == "function* f", do: "yield #{@decoy};", else: operand
      source = "#{header}(#{parameter}){#{operand}#{@real}}"
      assert_specs(source, goal)
    end

    source = "var await=4;function f(cb=async()=>()=>1){const n=await / 2;#{@real}}"
    assert_specs(source, :script)
  end

  test "object and class methods retain their parameter owner and body grammar" do
    for parameter <- ["cb=()=>1", "cb=async()=>()=>1"],
        {method, operands} <- [
          {"f", ""},
          {"async f", "await #{@decoy};"},
          {"*f", "yield #{@decoy};"},
          {"async *[name]", "await #{@decoy};yield #{@decoy};"}
        ],
        container <- ["const object=", "class C"],
        goal <- [:script, :module] do
      source = "#{container}{#{method}(#{parameter}){#{operands}#{@real}}};"
      assert_specs(source, goal)
    end

    source = "var await=4;class C{f(cb=async()=>1){const n=await / 2;#{@real}}}"
    assert_specs(source, :script)
  end

  test "a bare class field line break starts the next generator member" do
    for field <- ["x", "static x", "[name]", "function", "async"],
        gap <- ["\n", "/*\n*/", "// comment\n", <<0x2028::utf8>>],
        {method, operands} <- [
          {"f", ""},
          {"async f", "await #{@decoy};"},
          {"*f", "yield #{@decoy};"},
          {"async *[name]", "await #{@decoy};yield #{@decoy};"}
        ],
        goal <- [:script, :module] do
      source = "class C{#{field}#{gap}#{method}(cb=()=>1){#{operands}}}" <> @real
      assert_specs(source, goal)
    end

    for goal <- [:script, :module] do
      source = "class C{x=async()=>value\n* await #{@decoy};async f(){await #{@decoy};}}" <> @real
      assert_specs(source, goal)
    end
  end

  test "an initial hashbang is opaque through every line terminator" do
    for ending <- ["\n", "\r", "\r\n", <<0x2028::utf8>>, <<0x2029::utf8>>],
        contents <- [~S| import("./phantom.js")|, ~S| '" import("./phantom.js")|],
        goal <- [:script, :module] do
      prefix = "#!" <> contents <> ending
      source = prefix <> @real
      assert_specs(source, goal)
      assert [{at, _length, "./real.js"}] = JsParser.spans(source, goal)
      assert at == byte_size(prefix) + byte_size(~S|import("|)
      {masked, _strings} = Scanner.scan(source, goal)

      assert binary_part(masked, 0, byte_size(contents) + 2) ==
               String.duplicate(" ", byte_size(contents) + 2)
    end

    for source <- ["#!", ~S|#! import("./phantom.js") '|] do
      assert JsParser.specs(source) == []
      {masked, strings} = Scanner.scan(source)
      assert masked == String.duplicate(" ", byte_size(source))
      assert strings == []
    end
  end

  test "hashbang recognition requires the first source bytes" do
    for prefix <- [";", "\n", " ", <<0xFEFF::utf8>>] do
      {masked, _strings} = Scanner.scan(prefix <> ~S|#! import("./real.js");|)
      assert binary_part(masked, byte_size(prefix), 2) == "#!"
      assert String.contains?(masked, "import")
    end

    source =
      ~S|const text="#! import('./hidden.js')";const r=/#! import(".\/hidden.js")/;| <> @real

    assert_specs(source, :module)
  end

  defp assert_specs(source, goal) do
    assert JsParser.specs(source, goal) == ["./real.js"], source
    assert [{at, length, "./real.js"}] = JsParser.spans(source, goal)
    assert binary_part(source, at, length) == "./real.js"
    {masked, _strings} = Scanner.scan(source, goal)
    assert byte_size(masked) == byte_size(source)
  end
end
