defmodule Crawler.Parser.ContextualKeywordsTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.JsParser
  alias Crawler.Parser.JsParser.Identifier
  alias Crawler.Parser.JsParser.Scanner

  @import ~S|import("./real.js");const r=/x/;|
  @regex ~S|/import(".\/hidden.js")/|

  test "classic script bindings named await and yield retain imports after division" do
    for word <- ~w(await yield), kind <- ~w(const let var) do
      source = "#{kind} #{word}=4;const n=#{word} / 2;" <> @import
      assert_specs(source)
    end
  end

  test "ordinary function and arrow grammar permits global contextual identifiers" do
    for word <- ~w(await yield), header <- ["function f()", "const f=()=>", "const f=value=>"] do
      source = "globalThis.#{word}=4;#{header}{const n=#{word} / 2;#{@import}};"
      assert_specs(source)
    end

    for word <- ~w(await yield) do
      assert_specs("globalThis.#{word}=4;const f=()=>#{word} / 2;" <> @import)
    end

    assert_specs("globalThis.yield=4;async function f(){const n=yield / 2;" <> @import <> "}")
    assert_specs("globalThis.await=4;function* f(){const n=await / 2;" <> @import <> "}")
  end

  test "Script patterns retain identifiers and Module expressions retain await operands" do
    for word <- ~w(await yield),
        binding <- [
          "#{word}=4",
          "other=1,#{word}=4",
          "{#{word}}=values",
          "{name:#{word}}=values",
          "[#{word}]=values",
          "{name:{#{word}=4}}=values",
          "[#{word}=4]=values"
        ] do
      source = "const #{binding};const n=#{word} / 2;" <> @import
      assert_specs(source)
    end

    for binding <- [
          "value = await #{@regex}",
          "{await: value}=values",
          "{value = await #{@regex}}=values",
          "[value = await #{@regex}]=values",
          "value = obj.await"
        ] do
      source = "const #{binding};await #{@regex};" <> @import
      assert_specs(source, :module)
    end
  end

  test "normal function and arrow parameters retain identifier grammar" do
    for word <- ~w(await yield),
        parameter <- [
          word,
          "#{word}=4",
          "{#{word}}",
          "{name:#{word}=4}",
          "[#{word}=4]",
          "#{word}=4,value=#{word} / 2"
        ],
        head <- ["function f(#{parameter})", "const f=(#{parameter})=>"] do
      source = "#{head} {const n=#{word} / 2;#{@import}};"
      assert_specs(source)
    end

    for word <- ~w(await yield), head <- ["#{word}", "(#{word})", "(#{word}=4)"] do
      assert_specs("const f=#{head}=>#{word} / 2;" <> @import)
    end
  end

  test "async and generator function scopes retain keyword regex operands" do
    for {word, header} <- [{"await", "async function f()"}, {"yield", "function* f()"}] do
      source =
        "const #{word}=4;#{header} {#{word} #{@regex};#{@import}}" <>
          "const n=#{word} / 2;"

      assert_specs(source)

      source =
        "#{header} {function inner(#{word}) {const n=#{word} / 2;}" <>
          "#{word} #{@regex};#{@import}}"

      assert_specs(source)
    end

    assert_specs("async function* f(){await #{@regex};yield #{@regex};" <> @import <> "}")
  end

  test "line terminators separate async identifiers from normal function declarations" do
    for separator <- ["\n", "/*\n*/", <<0x2028::utf8>>] do
      assert_specs("async#{separator}function f(){const n=await / 2;#{@import}}")
    end
  end

  test "async arrows restore enclosing bindings when their body ends" do
    for body <- ["await #{@regex}", "{await #{@regex};}"] do
      source =
        "const await=4;const f=async(value)=>#{body};const n=await / 2;" <> @import

      assert_specs(source)

      source =
        "const await=4;call(async value=>#{body});const n=await / 2;" <> @import

      assert_specs(source)
    end

    assert_specs(
      "const yield=4;function* f(){const inner=()=>yield / 2;yield #{@regex};" <> @import <> "}"
    )

    assert_specs(
      "const await=4;const f=async()=>function(){const n=await / 2;" <> @import <> "};"
    )
  end

  test "async and generator methods preserve keyword regexes with outer ordinary bindings" do
    for {word, method} <- [
          {"await", "async f()"},
          {"await", "async [name]()"},
          {"yield", "* f()"},
          {"yield", "* [name]()"}
        ],
        object <- ["const object={#{method}", "class Named {#{method}"] do
      source = "const #{word}=4;#{object} {#{word} #{@regex};}};" <> @import
      assert_specs(source)
    end

    for method <- ["f(await)", "[name]({await})"] do
      source = "const object={#{method} {const n=await / 2;#{@import}}};"
      assert_specs(source)
    end
  end

  test "nested lexical bindings retain outer async and generator keyword state" do
    for {word, header} <- [{"await", "async function f()"}, {"yield", "function* f()"}] do
      source =
        "#{header} {function inner() {{let #{word}=4;const n=#{word} / 2;}}" <>
          "#{word} #{@regex};#{@import}}"

      assert_specs(source)
    end

    assert_specs("const await=4;{const n=await / 2;}" <> @import)
    assert_specs("function f(){ {var await=4;} const n=await / 2;" <> @import <> "}")
  end

  test "function and class declaration names are bindings in their enclosing scope" do
    for declaration <- [
          "function await(){}",
          "async function await(){await #{@regex};}",
          "class await{}",
          "class await{async f(){await #{@regex};}}"
        ] do
      assert_specs(declaration <> " const n=await / 2;" <> @import)
    end

    for declaration <- ["function yield(){}", "function* yield(){yield #{@regex};}"] do
      assert_specs(declaration <> " const n=yield / 2;" <> @import)
    end
  end

  test "expression names are local to their function or class" do
    for word <- ~w(await yield) do
      assert_specs("const f=function #{word}(){const n=#{word} / 2;" <> @import <> "};")
    end

    assert_specs("const c=class await{f(){const n=await / 2;" <> @import <> "}};")
  end

  test "catch parameters and destructuring bind contextual identifiers within the catch body" do
    for word <- ~w(await yield),
        parameter <- [word, "{#{word}}", "{name:#{word}=4}", "[#{word}=4]"] do
      assert_specs("try{}catch(#{parameter}){const n=#{word} / 2;" <> @import <> "}")
    end
  end

  test "catch property names and default expressions do not create false bindings" do
    for parameter <- ["{await: value}", "{value=await #{@regex}}", "[value=await #{@regex}]"] do
      assert_specs("try{}catch(#{parameter}){}await #{@regex};" <> @import, :module)
    end

    for {word, header} <- [{"await", "async function f()"}, {"yield", "function* f()"}] do
      source =
        "#{header}{function inner(){try{}catch({#{word}}){const n=#{word} / 2;}}" <>
          "#{word} #{@regex};#{@import}}"

      assert_specs(source)
    end
  end

  test "source goal fixes identifier roles before later bindings" do
    for word <- ~w(await yield), declaration <- ["var #{word}=4", "function #{word}(){}"] do
      assert_specs("const n=#{word} / 2;#{declaration};" <> @import)
    end

    assert_specs("const n=await / 2;class await{};" <> @import)
    assert_specs("const n=await / 2;function nested(){var await=4;}" <> @import)

    source =
      ~S|const n=await /g;var await=4;import(".\/hidden.js");const m=g/g;import("./real.js");|

    assert JsParser.specs(source, :script) == ["./hidden.js", "./real.js"]
    assert JsParser.specs(source, :module) == ["./real.js"]
    assert JsParser.specs(source) == ["./real.js"]

    assert JsParser.elements(source, :script) == [
             {"link", [{"href", "./hidden.js"}], []},
             {"link", [{"href", "./real.js"}], []}
           ]
  end

  test "normal function scopes restore the enclosing Module await role" do
    assert_specs(
      "globalThis.await=4;const f=function await(){const n=await / 2;};await #{@regex};" <>
        @import,
      :module
    )

    assert_specs(
      "const object={\"f\"(){const n=await / 2;}};await #{@regex};" <> @import,
      :module
    )
  end

  test "identifier tokens keep decoded names separate from raw byte lengths" do
    assert {:ok, ~S|\u0061wait|, "await", " / 2"} = Identifier.take(~S|\u0061wait / 2|)
    assert {:ok, ~S|\u{79}ield|, "yield", ";"} = Identifier.take(~S|\u{79}ield;|)
    assert {:ok, "π", "π", ";"} = Identifier.take("π;")
  end

  test "escaped contextual identifiers retain raw source spans" do
    for {raw, word} <- [{~S|\u0061wait|, "await"}, {~S|\u0079ield|, "yield"}],
        declaration <- ["const #{raw}=4;", "var #{raw}=4;", "function #{raw}(){}"] do
      assert_specs(declaration <> "const n=#{word} / 2;" <> @import)
      assert_specs("const n=#{raw} / 2;" <> declaration <> @import)
    end

    for escaped <- [~S|\u0069mport|, ~S|\u0065xport|] do
      assert JsParser.specs(escaped <> ~S|("./hidden.js");| <> @import, :script) == ["./real.js"]
    end
  end

  test "all ordinary method property names establish normal function grammar" do
    for word <- ~w(await yield),
        method <- [
          ~s|"f"()|,
          "123()",
          "0xFF()",
          "1.2()",
          ".5()",
          "1e2()",
          "get f()",
          ~s|get "f"()|,
          "get 12()",
          "set f(value)",
          ~s|set "f"(value)|,
          "set 12(value)",
          "get [name]()",
          "set [name](value)",
          ~S|\u0061sync()|
        ] do
      assert_specs(
        "globalThis.#{word}=4;const object={#{method}{const n=#{word} / 2;#{@import}}};"
      )
    end

    for method <- [
          ~s|"f"()|,
          "12()",
          ~s|get "f"()|,
          "set 12(value)",
          ~s|static "f"()|,
          ~s|static get "f"()|,
          "static set 12(value)"
        ] do
      assert_specs("globalThis.await=4;class Named{#{method}{const n=await / 2;#{@import}}}")
    end
  end

  test "async and generator method prefixes survive every property-name form" do
    for name <- [
          "f",
          "function",
          "class",
          "async",
          "get",
          "set",
          "static",
          "await",
          "yield",
          ~s|"f"|,
          "12",
          "0xFF",
          "0b10",
          "0o12",
          "1.2",
          ".5",
          "1e2",
          "1_000",
          "[name]"
        ],
        {prefix, words} <- [
          {"async", ["await"]},
          {"*", ["yield"]},
          {"async *", ["await", "yield"]}
        ],
        container <- ["const object=", "class Named"] do
      operands = Enum.map_join(words, ";", &"#{&1} #{@regex}")
      source = "#{container}{#{prefix} #{name}(){#{operands};#{@import}}};"
      assert_specs(source)
    end

    for method <- [
          ~s|static async "f"()|,
          "static * f()",
          "static * 12()",
          "static async * [name]()"
        ] do
      operands = if String.contains?(method, "async"), do: "await #{@regex};", else: ""

      operands =
        if String.contains?(method, "*"), do: operands <> "yield #{@regex};", else: operands

      assert_specs("class Named{#{method}{#{operands}#{@import}}}")
    end

    assert_specs("const object={async:()=>await / 2,get:()=>yield / 2};" <> @import)
    assert_specs("class Named{async\n\"f\"(){const n=await / 2;#{@import}}}")

    assert_specs(
      "const object={get(){const n=await / 2;#{@import}},async(){const n=yield / 2;}};"
    )
  end

  defp assert_specs(source, goal \\ :script) do
    assert JsParser.specs(source, goal) == ["./real.js"], source
    assert [{at, length, "./real.js"}] = JsParser.spans(source, goal)
    assert binary_part(source, at, length) == "./real.js"
    {masked, _strings} = Scanner.scan(source, goal)
    assert byte_size(masked) == byte_size(source)
  end
end
