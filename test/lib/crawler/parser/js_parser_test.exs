defmodule Crawler.Parser.JsParserTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.JsParser

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
