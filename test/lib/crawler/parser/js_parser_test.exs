defmodule Crawler.Parser.JsParserTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.JsParser
  alias Crawler.Parser.JsParser.Scanner

  test "property keywords preserve division instead of starting regexes or statement headers" do
    for word <-
          ~w(return yield await case default else finally try catch if while for with switch function class export from import),
        access <- [".", "?.", "./* café */", "?.\n/* café */"],
        call <- ["", "()"] do
      source =
        "const n = obj#{access}#{word}#{call} / 2;" <>
          ~S|import("./real.js"); const r = /import(".\/hidden.js")/;|

      assert JsParser.specs(source) == ["./real.js"], source
    end
  end

  test "real return and control keywords still permit regular expressions" do
    for {prefix, suffix} <- [
          {"function f() { return ", "}"},
          {"function* f() { yield ", "}"},
          {"try {} catch (error) ", ""},
          {"if (ready) ", ""},
          {"while (ready) ", ""},
          {"for (;;) ", ""}
        ] do
      source = prefix <> ~S|/import(".\/hidden.js")/.test(text); import("./real.js");| <> suffix
      assert JsParser.specs(source) == ["./real.js"], prefix
    end
  end

  test "import is a complete identifier token rather than part of another identifier" do
    for identifier <- [
          "$import",
          "_import",
          "πimport",
          "importπ",
          "a\u0301import",
          "a\u200Cimport",
          "a\u00B7import",
          "a\u30FBimport",
          "\u1885import",
          ~S|\u{61}import|,
          ~S|import\u0061|
        ] do
      source = identifier <> ~S|("./fake.js"); import("./real.js");|

      assert JsParser.specs(source) == ["./real.js"], identifier
      assert [{start, length, "./real.js"}] = JsParser.spans(source)
      assert binary_part(source, start, length) == "./real.js"
      {masked, _strings} = Scanner.scan(source)
      assert byte_size(masked) == byte_size(source)
    end

    source = ~S|$export("./fake.js"); πimport("./fake.js"); import value from "./real.js";|
    assert JsParser.specs(source) == ["./real.js"]
  end

  test "distinguishes division after object expressions from regular expressions after blocks" do
    source =
      ~S|const n = {} / 2; import("./chunk.js"); const r = /x/;| <>
        ~S|const nested = {child: {}} / 2; import("./nested.js");| <>
        ~S|if (ready) {} /import\("\.\/hidden.js"\)/.test(text); import("./block.js");|

    assert JsParser.specs(source) == ["./chunk.js", "./nested.js", "./block.js"]
    {masked, _strings} = Scanner.scan(source)
    assert byte_size(masked) == byte_size(source)
    assert masked =~ "{} / 2;"
    assert masked =~ "{}} / 2;"
    refute masked =~ "hidden.js"
  end

  test "division after function and class expressions does not hide later imports" do
    for expression <- [
          "function() {}",
          "function named() {}",
          "async function() {}",
          "function* named() {}",
          "function(value = function() {}) {}",
          "class {}",
          "class Named {}",
          "class extends Factory({}) {}",
          "class extends (class {}) {}"
        ] do
      source =
        "const n = #{expression} / 2;" <>
          ~S|import("./chunk.js"); const r = /import(".\/hidden.js")/;|

      assert JsParser.specs(source) == ["./chunk.js"], expression
      {masked, _strings} = Scanner.scan(source)
      assert masked =~ " / 2;"
      refute masked =~ "hidden.js"
    end
  end

  test "declaration bodies and nested function blocks allow regular expressions" do
    for declaration <- [
          "function named() {}",
          "async function named() {}",
          "function* named() {}",
          "class Named {}",
          "export function named() {}",
          "export default async function named() {}",
          "export default class {}"
        ] do
      source =
        declaration <>
          ~S| /import(".\/hidden.js")/.test(text); import("./real.js");|

      assert JsParser.specs(source) == ["./real.js"], declaration
    end

    for header <- ["const fn = () =>", "const fn = function()", "const fn = async function()"] do
      source =
        header <>
          ~S| { {} /import(".\/hidden.js")/.test(text); return import("./body.js"); }; import("./after.js");|

      assert JsParser.specs(source) == ["./body.js", "./after.js"], header
    end
  end

  test "line terminators and multiline comments permit function and class declarations after ASI" do
    for terminator <- ["\n", "\r", "\r\n", <<0x2028::utf8>>, <<0x2029::utf8>>],
        separator <- [terminator, "/* café" <> terminator <> " */", "// café" <> terminator],
        declaration <- ["function f() {}", "async function f() {}", "class Named {}"] do
      source =
        "const n = 1" <>
          separator <>
          declaration <>
          terminator <>
          ~S|/["']/.test(text); import("./real.js"); const hidden = /import(".\/hidden.js")/;|

      assert JsParser.specs(source) == ["./real.js"]
      assert [{start, length, "./real.js"}] = JsParser.spans(source)
      assert binary_part(source, start, length) == "./real.js"
    end
  end

  test "return line boundaries start statement blocks and keep later top-level imports visible" do
    for terminator <- ["\n", "\r", "\r\n", <<0x2028::utf8>>, <<0x2029::utf8>>],
        separator <- [terminator, "/* café" <> terminator <> " */", ";" <> terminator] do
      source =
        "function f() { return" <>
          separator <>
          ~S|{} /["']/.test(text); } import("./real.js");|

      assert JsParser.specs(source) == ["./real.js"]
      assert [{start, length, "./real.js"}] = JsParser.spans(source)
      assert binary_part(source, start, length) == "./real.js"
    end

    for {opening, closing} <- [{" ", ""}, {"/* café */", ""}, {" (\n", ")"}] do
      source =
        "function f() { return#{opening}{}#{closing} / 2; }" <>
          ~S|import("./real.js"); const r = /x/;|

      assert JsParser.specs(source) == ["./real.js"]
    end
  end

  test "ordinary statement labels allow block regexes and keep outside imports visible" do
    for label <- ["label:", "outer: inner:", "πlabel /* café */ :", "label\n:"],
        prefix <- ["", "const n = 1\n", "return\n"] do
      source =
        "function f() { #{prefix}#{label}" <>
          ~S| {} /["']/.test(text); } import("./real.js");|

      assert JsParser.specs(source) == ["./real.js"]
      assert [{start, length, "./real.js"}] = JsParser.spans(source)
      assert binary_part(source, start, length) == "./real.js"
    end

    for expression <- [
          "const n = { label: {} / 2 }",
          "const n = { child: { label: {} / 2 } }",
          "const n = ready ? obj?.label : {} / 2",
          "const n = ready ? {} : {} / 2"
        ] do
      source = expression <> ~S|; import("./real.js"); const r = /x/;|
      assert JsParser.specs(source) == ["./real.js"]
    end
  end

  test "switch labels start statement lists without treating conditional or object colons as labels" do
    for label <- [
          "case 1",
          "case condition ? 1 : 2",
          "case condition ? left ?? 1 : obj?.value",
          "default"
        ],
        declaration <- ["function f() {}", "async function f() {}", "class Named {}"] do
      source =
        "switch (value) { #{label}: #{declaration}" <>
          ~S| /["']/.test(text); import("./real.js"); break; }| <>
          ~S|const object = { case: function() {} / 2 }; import("./after.js"); const r = /x/;|

      assert JsParser.specs(source) == ["./real.js", "./after.js"]
    end
  end

  test "line breaks keep expression bodies and property keywords in expression context" do
    for terminator <- ["\n", "\r", "\r\n", <<0x2028::utf8>>, <<0x2029::utf8>>],
        expression <- [
          "const n = #{terminator}function() {}",
          "const n = #{terminator}async function() {}",
          "const n = #{terminator}class {}",
          "const n = class extends #{terminator}function() {} {}",
          "const n = obj.#{terminator}function()",
          "const n = obj?.#{terminator}class()"
        ] do
      source = expression <> ~S| / 2; import("./real.js"); const r = /import(".\/hidden.js")/;|
      assert JsParser.specs(source) == ["./real.js"]
    end

    source =
      ~S|function outer() { return| <>
        "\n" <>
        ~S|function inner() {} /["']/.test(text); import("./return.js"); }|

    assert JsParser.specs(source) == ["./return.js"]
  end

  test "quoted binding names do not hide the actual from specifier" do
    source = ~S|
    import { "name" as name } from "./dep.js";
    export { name as "name" } from "./dep.js";
    import { 'from' as local } from './user\u0020file.js';
    export { local as "name's" } from "./user's.js";
    const text = 'export { name as "name" } from "./fake.js"';
    // import { "name" as name } from "./fake.js";
    |

    assert JsParser.specs(source) == ["./dep.js", "./user file.js", "./user's.js"]
    assert length(JsParser.spans(source)) == 4

    for {start, length, cooked} <- JsParser.spans(source) do
      raw = binary_part(source, start, length)
      assert {:ok, ^cooked} = Crawler.Parser.JsParser.StringLiteral.decode(raw)
    end
  end

  test "uses matching delimiters and cooks escaped specifiers while keeping raw byte spans" do
    literals = [
      {~S|"./user's.js"|, "./user's.js"},
      {~S|'./say"hi.js'|, ~s|./say"hi.js|},
      {~S|"./user\u0020file.js"|, "./user file.js"},
      {~S|'./\x63hunk.js'|, "./chunk.js"},
      {~S|"./caf\u00e9.js"|, "./café.js"},
      {~S|`./\u{1F680}.js`|, "./🚀.js"},
      {~S|"./\uD83D\uDE80.js"|, "./🚀.js"},
      {~S|'./user\'s.js'|, "./user's.js"},
      {~S|"./literal${name}.js"|, "./literal${name}.js"},
      {~S|`./literal\${name}.js`|, "./literal${name}.js"},
      {"\"./long\\\r\nname.js\"", "./longname.js"}
    ]

    for {literal, cooked} <- literals,
        statement <- [
          "import #{literal};",
          "export { value } from #{literal};",
          "import(#{literal});"
        ] do
      source = ~s|const label = "café";\n| <> statement

      assert JsParser.specs(source) == [cooked]
      assert [{start, length, ^cooked}] = JsParser.spans(source)
      assert binary_part(source, start, length) == binary_part(literal, 1, byte_size(literal) - 2)
    end
  end

  test "keeps escaped strings, regexes, comments, computed imports and package imports out of specs" do
    source =
      ~S|const note = "import(\"./fake.js\")";| <>
        ~S|const pattern = /import\("\.\/fake.js"\)/;| <>
        ~S|/* import("./fake.js"); */| <>
        ~S|import("./user\u0020file.js" + name); import(`./${name}.js`);| <>
        ~S|import("re\u0061ct"); import("./bad\uXYZW.js"); import("./bad\uD800.js");| <>
        ~S|import("./real.js");|

    assert JsParser.specs(source) == ["./real.js"]
  end

  test "all JavaScript line terminators end a line comment and start a statement" do
    for terminator <- ["\n", "\r", "\r\n", <<0x2028::utf8>>, <<0x2029::utf8>>],
        prefix <- [~s|// import "./hidden.js"|, ~s|const note = "café"|] do
      source = prefix <> terminator <> ~s|import "./real.js";|

      assert JsParser.specs(source) == ["./real.js"]
      assert [{start, length, "./real.js"}] = JsParser.spans(source)
      assert binary_part(source, start, length) == "./real.js"
    end
  end

  test "follows relative, root, and remote specifiers" do
    source = """
    import "./lib.js";
    import helper from "../util.js";
    export { y } from "/abs.js";
    import("./dyn.js");
    import "https://cdn.example/lib.js";
    import "//cdn.example/other.js";
    """

    assert Enum.sort(JsParser.specs(source)) ==
             Enum.sort([
               "./lib.js",
               "../util.js",
               "/abs.js",
               "./dyn.js",
               "https://cdn.example/lib.js",
               "//cdn.example/other.js"
             ])
  end

  test "follows an import after a byte that is not utf-8" do
    source = "var name = \"caf" <> <<0xE9>> <> "\";\nimport \"./lib.js\";\n"

    assert JsParser.specs(source) == ["./lib.js"]
  end

  test "follows specifiers separated from the keyword by a comment" do
    source = """
    import(/* webpackChunkName: "a" */ "/abs.js");
    import foo from /* c */ "../util.js";
    import // comment
    "./lib.js";
    import /* c */ ("./gap.js");
    """

    assert Enum.sort(JsParser.specs(source)) ==
             Enum.sort(["/abs.js", "../util.js", "./lib.js", "./gap.js"])
  end

  test "follows imports that come after a regular expression" do
    source = """
    const quoted = /["']/;
    export function load(){ return import("./panel.js"); }
    import "./later.js";
    const re = /\\//g; import "./slash.js";
    const x = a / b; import "./kept.js";
    """

    assert Enum.sort(JsParser.specs(source)) ==
             Enum.sort(["./panel.js", "./later.js", "./slash.js", "./kept.js"])
  end

  test "skips a property call named import" do
    source = """
    obj.import("./plugin.js");
    obj. import("./plugin.js");
    obj.
    import("./plugin.js");
    obj./* c */import("./plugin.js");
    System.import("./plugin.js");
    System . import("./plugin.js");
    loader?.import("./kept.js");
    loader?. import("./kept.js");
    function* g(){ yield import("./real.js"); }
    """

    assert JsParser.specs(source) == ["./real.js"]
  end

  for expression <- ["n++", "n--", "++n", "--n"] do
    test "follows an import after division with #{expression} and skips regular expression text" do
      source =
        ~s|let n=2;#{unquote(expression)} / 2;import("./chunk.js");| <>
          ~S|const quoted=/["']/;const decoy=/import\("\.\/hidden.js"\)/;|

      assert JsParser.specs(source) == ["./chunk.js"]
    end
  end

  test "follows an import after a closing brace" do
    source = """
    }import "./a.js";
    }export { y } from "./b.js";
    const note = "}import './nope.js'";
    switch (x) { default: /["']/.test(x) } import "./c.js";
    """

    assert Enum.sort(JsParser.specs(source)) == Enum.sort(["./a.js", "./b.js", "./c.js"])
  end

  test "follows an import after a regular expression in a for-await loop" do
    source = """
    for await (const x of items) /["']/.test(x);
    import "./a.js";
    """

    assert JsParser.specs(source) == ["./a.js"]
  end

  test "follows a regular expression in statement position" do
    source = """
    if (value) /["']/.test(value);
    else if (ok) /["']/.test(ok);
    for (const x of items) /["']/.test(x);
    import("./panel.js");
    foo()/2;
    import "./a.js";
    """

    assert Enum.sort(JsParser.specs(source)) == Enum.sort(["./panel.js", "./a.js"])
  end

  test "does not treat a slash after a call or a bracket as a regular expression" do
    call = "foo()\n/[\"']/\nimport \"./a.js\";\n"
    list = "const xs = [\"a\"]\n/[\"']/\nimport \"./b.js\";\n"
    index = "xs[0]\n/[\"']/\nimport \"./c.js\";\n"

    assert JsParser.specs(call) == []
    assert JsParser.specs(list) == []
    assert JsParser.specs(index) == []
  end

  test "follows a dynamic import with options and skips concatenation" do
    kept = ~s|import("./lib.js", { assert: { type: "json" } });|
    skipped = ~s|import("./lib.js" + extra); import(`./lib.js` + extra);|

    assert JsParser.specs(kept) == ["./lib.js"]
    assert JsParser.specs(skipped) == []
  end

  test "follows an import inside a template interpolation" do
    source = """
    const x = `pre ${import("./lib.js")} post`;
    import "./top.js";
    import(`./${x}.js`);
    """

    assert Enum.sort(JsParser.specs(source)) == Enum.sort(["./lib.js", "./top.js"])
  end

  test "keeps byte spans inside nested template interpolations" do
    source =
      "const label = \"café\";\n" <>
        ~S|const result = `outer ${`inner ${import("./inner.js")} import('./text.js')`} ${import("./outer.js")}`;|

    spans = JsParser.spans(source)

    assert Enum.sort(Enum.map(spans, &elem(&1, 2))) == ["./inner.js", "./outer.js"]

    for {start, length, specifier} <- spans do
      assert binary_part(source, start, length) == specifier
    end
  end

  test "skips import text in unfinished strings and templates" do
    assert JsParser.specs(~S|const text = "import('./string.js')|) == []

    assert JsParser.specs("const text = `\nimport './template.js';") == []

    assert JsParser.specs(~S|const text = `value ${import("./real.js")} import('./text.js')|) ==
             ["./real.js"]
  end

  test "follows backtick specifiers and keeps an upper-case scheme" do
    source = """
    import(`./dyn.js`);
    export { y } from `./tick.js`;
    import "HTTPS://cdn.example/lib.js";
    import(`./${name}.js`);
    """

    assert Enum.sort(JsParser.specs(source)) ==
             Enum.sort(["./dyn.js", "./tick.js", "HTTPS://cdn.example/lib.js"])
  end

  test "follows imports split across lines" do
    source = """
    import {
      helper
    } from "../util.js";
    export {
      y
    } from "/abs.js";
    import "./lib.js";
    """

    assert Enum.sort(JsParser.specs(source)) ==
             Enum.sort(["../util.js", "/abs.js", "./lib.js"])
  end

  test "skips imports that are only text inside a string" do
    source = """
    const note = "import('./string.js')";
    const block = `
    import "./template.js";
    export { y } from "/template-from.js";
    `;
    const lines = "
    import './multiline.js'";
    import "./lib.js";
    import("./dyn.js");
    """

    assert Enum.sort(JsParser.specs(source)) == Enum.sort(["./lib.js", "./dyn.js"])
  end

  test "skips packages and comments" do
    source = """
    // import "./nope.js"
    /* export { y } from "/abs.js" */
    const note = "import './string.js'";
    import "react";
    import "lodash/get";
    import.meta.url;
    import "./lib.js";
    """

    assert JsParser.specs(source) == ["./lib.js"]
  end
end
