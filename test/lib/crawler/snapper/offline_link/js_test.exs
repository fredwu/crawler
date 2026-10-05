defmodule Crawler.Snapper.OfflineLink.JsTest do
  use Crawler.OfflineLinkCase, async: true

  test "rewrites javascript specifiers and leaves package imports" do
    source = """
    // import "./nope.js"
    import "./lib.js";
    import helper from "../util.js";
    export { y } from "/abs.js";
    import("./dyn.js");
    import "react";
    """

    app = "http://example.com/blog/app.js"
    body = rewrite(source, app, "application/javascript", "script")

    refute body =~ ~s("./lib.js")
    refute body =~ ~s("../util.js")
    refute body =~ ~s("/abs.js")
    refute body =~ ~s("./dyn.js")
    assert body =~ ~s("./nope.js")
    assert body =~ ~s("react")
    assert_points(body, app, "http://example.com/blog/lib.js")
    assert_points(body, app, "http://example.com/util.js")
    assert_points(body, app, "http://example.com/abs.js")
    assert_points(body, app, "http://example.com/blog/dyn.js")
  end

  for attrs <- [
        ~s|data-type="application/json" type="module"|,
        ~s|data-note='type="application/json"' type="module"|,
        ~s|data-note="type='application/json'"|
      ] do
    test "uses actual script type attributes when #{attrs}" do
      attrs = unquote(attrs)
      body = rewrite(~s|<script #{attrs}>import "./shared.js";</script>|, @page)
      offline = Linker.offline_link(@page, "http://example.com/blog/shared.js")

      assert body == ~s|<script #{attrs}>import "#{offline}";</script>|
    end
  end

  test "keeps non-javascript script text when data-type names a javascript type" do
    html = """
    <script data-type="module" type="application/ld+json">import "./shared.js";</script>
    <script type="module">import "./shared.js";</script>
    """

    body = rewrite(html, @page)
    offline = Linker.offline_link(@page, "http://example.com/blog/shared.js")

    assert body =~
             ~s|<script data-type="module" type="application/ld+json">import "./shared.js";</script>|

    assert body =~ ~s|<script type="module">import "#{offline}";</script>|
    assert occurrences(body, offline) == 1
  end

  test "rewrites only real module specifiers" do
    html = """
    <p>Call import "./lib.js" from the module.</p>
    <script type="module">
    import "./lib.js";
    const note = 'from "./lib.js"';
    // import "./lib.js"
    obj.import("./lib.js");
    </script>
    <script type="application/ld+json">{"import": "./lib.js"}</script>
    """

    body = rewrite(html, @page)
    assert body =~ ~s|<p>Call import "./lib.js" from the module.</p>|
    assert body =~ ~s|const note = 'from "./lib.js"';|
    assert body =~ ~s|// import "./lib.js"|
    assert body =~ ~s|obj.import("./lib.js");|
    assert body =~ ~s|{"import": "./lib.js"}|
    assert_points(body, @page, "http://example.com/blog/lib.js")
    assert occurrences(body, "example.com/blog/lib.js") == 1
  end

  test "rewrites an import that follows a regular expression in a script" do
    html = """
    <script type="module">const quoted = /["']/; import "./panel.js";</script>
    """

    body = rewrite(html, @page)
    assert body =~ ~s|/["']/|
    refute body =~ ~s|"./panel.js"|
    assert_points(body, @page, "http://example.com/blog/panel.js")
  end

  test "rewrites an import after a statement regular expression" do
    html = """
    <script type="module">
    if (value) /["']/.test(value);
    else if (ok) /["']/.test(ok);
    for (const x of items) /["']/.test(x);
    import("./panel.js");
    foo()/2; import "./kept.js";
    </script>
    """

    body = rewrite(html, @page)
    assert body =~ ~s|/["']/|
    refute body =~ ~s|"./panel.js"|
    refute body =~ ~s|"./kept.js"|
    assert_points(body, @page, "http://example.com/blog/panel.js")
    assert_points(body, @page, "http://example.com/blog/kept.js")
  end

  test "rewrites imports after ASI and switch declarations while preserving regex and comment bytes" do
    for terminator <- ["\n", "\r", "\r\n", <<0x2028::utf8>>, <<0x2029::utf8>>],
        declaration <- ["function f() {}", "async function f() {}", "class Named {}"],
        prefix <- [
          "const n = 1#{terminator}",
          "const n = 1/* café#{terminator} */",
          "switch (n) { case condition ? 1 : 2: "
        ] do
      closing = if String.starts_with?(prefix, "switch"), do: " }", else: ""

      source =
        prefix <>
          declaration <>
          terminator <>
          ~S|/["']/.test(text); import("./real.js"); const hidden = /import(".\/hidden.js")/;| <>
          closing

      assert_rewritten_module(source)
    end
  end

  test "rewrites top-level imports after return line boundaries without changing block regexes" do
    for terminator <- ["\n", "\r", "\r\n", <<0x2028::utf8>>, <<0x2029::utf8>>],
        separator <- [terminator, "/* café" <> terminator <> " */", ";" <> terminator] do
      source =
        "function f() { return" <>
          separator <>
          ~S|{} /["']/.test(text); } import("./real.js");|

      assert_rewritten_module(source)
    end

    for {opening, closing} <- [{" ", ""}, {"/* café */", ""}, {" (\n", ")"}] do
      source =
        "function f() { return#{opening}{}#{closing} / 2; }" <>
          ~S|import("./real.js"); const r = /x/;|

      assert_rewritten_module(source)
    end
  end

  test "rewrites outside imports after labelled blocks while preserving block regex bytes" do
    for label <- ["label:", "outer: inner:", "πlabel /* café */ :", "label\n:"],
        prefix <- ["", "const n = 1\n", "return\n"] do
      source =
        "function f() { #{prefix}#{label}" <>
          ~S| {} /["']/.test(text); } import("./real.js");|

      assert_rewritten_module(source)
    end

    for expression <- [
          "const n = { label: {} / 2 }",
          "const n = { child: { label: {} / 2 } }",
          "const n = ready ? obj?.label : {} / 2",
          "const n = ready ? {} : {} / 2"
        ] do
      assert_rewritten_module(expression <> ~S|; import("./real.js"); const r = /x/;|)
    end
  end

  test "rewrites imports after multiline expression division without rewriting regex decoys" do
    for expression <- [
          "const n =\nfunction() {}",
          "const n =\nasync function() {}",
          "const n =\nclass {}",
          "const n = obj.\nfunction()"
        ] do
      source =
        expression <> ~S| / 2; import("./real.js"); const hidden = /import(".\/hidden.js")/;|

      assert_rewritten_module(source)
    end
  end

  for expression <- ["n++", "n--", "++n", "--n"] do
    test "rewrites an import after division with #{expression} and preserves regular expressions" do
      source =
        ~s|let n=2;#{unquote(expression)} / 2;import("./chunk.js");| <>
          ~S|const quoted=/["']/;const decoy=/import\("\.\/hidden.js"\)/;|

      target = "http://example.com/blog/chunk.js"
      app = "http://example.com/blog/app.js"
      js = rewrite(source, app, "application/javascript", "script")
      js_import = ~s|import("#{Linker.offline_link(app, target)}")|

      assert js == String.replace(source, ~s|import("./chunk.js")|, js_import)
      assert_points(js, app, target)

      html = rewrite(~s|<script type="module">#{source}</script>|, @page)
      html_import = ~s|import("#{Linker.offline_link(@page, target)}")|
      expected_source = String.replace(source, ~s|import("./chunk.js")|, html_import)

      assert html == ~s|<script type="module">#{expected_source}</script>|
      assert_points(html, @page, target)
    end
  end

  test "rewrites an import and an export that share a specifier" do
    source = """
    import "./lib.js";
    export { a } from "./lib.js";
    """

    app = "http://example.com/app.js"
    js = rewrite(source, app, "application/javascript", "script")
    {:ok, target} = Crawler.URL.resolve("./lib.js", app)

    assert js =~ "export { a } from"
    refute js =~ ~s("./lib.js")
    assert occurrences(js, Linker.offline_link(app, target)) == 2

    html = ~s|<script type="module">import "./lib.js"; export { a } from "./lib.js";</script>|
    page = rewrite(html, @page)
    {:ok, page_target} = Crawler.URL.resolve("./lib.js", @page)

    assert page =~ ~s|<script type="module">|
    assert page =~ "export { a } from"
    refute page =~ ~s("./lib.js")
    assert occurrences(page, Linker.offline_link(@page, page_target)) == 2
  end

  test "rewrites two forms of one remote specifier" do
    app = "http://example.com/app.js"
    source = ~s|import("https://a.co/a.js");import "https://a.co/a.js";|
    body = rewrite(source, app, "application/javascript", "script")
    {:ok, target} = Crawler.URL.resolve("https://a.co/a.js", app)

    refute body =~ "https://a.co/a.js"
    assert occurrences(body, Linker.offline_link(app, target)) == 2
  end

  test "rewrites a dynamic import inside a template and keeps concatenation" do
    source = """
    const x = `pre ${import("./lib.js")} post`;
    import "./top.js";
    import(`./${name}.js`);
    import("./lib.js" + extra);
    import(`./other.js` + extra);
    import("./opt.js", { assert: { type: "json" } });
    """

    app = "http://example.com/app.js"
    body = rewrite(source, app, "application/javascript", "script")

    assert body =~ "`pre ${import(\""
    assert body =~ "\")} post`"
    assert body =~ ~s|`./${name}.js`|
    assert body =~ ~s|import("./lib.js" + extra)|
    assert body =~ ~s|import(`./other.js` + extra)|
    refute body =~ ~s|import("./opt.js",|
    assert body =~ "assert:"
    assert_points(body, app, "http://example.com/lib.js")
    assert_points(body, app, "http://example.com/top.js")
    assert_points(body, app, "http://example.com/opt.js")
  end

  test "does not rewrite a property call when space follows the dot" do
    source = """
    obj. import("./lib.js");
    obj.
    import("./lib.js");
    obj./* c */import("./lib.js");
    System . import("./lib.js");
    loader?. import("./lib.js");
    loader?.import("./kept.js");
    function* g(){ yield import("./real.js"); }
    """

    app = "http://example.com/app.js"
    body = rewrite(source, app, "application/javascript", "script")

    assert body =~ ~s|obj. import("./lib.js");|
    assert body =~ "obj.\nimport(\"./lib.js\");"
    assert body =~ ~s|obj./* c */import("./lib.js");|
    assert body =~ ~s|System . import("./lib.js");|
    assert body =~ ~s|loader?. import("./lib.js");|
    assert body =~ ~s|loader?.import("./kept.js");|
    refute body =~ ~s|"./real.js"|
    assert_points(body, app, "http://example.com/real.js")
  end

  test "rewrites an import that follows a quote entity in a script" do
    html = """
    <script type="module">
    const note = "&#x22;";
    import "./hidden.js";
    </script>
    """

    body = rewrite(html, @page)
    assert body =~ "&#x22;"
    refute body =~ ~s|"./hidden.js"|
    assert_points(body, @page, "http://example.com/blog/hidden.js")
  end

  test "rewrites an import when a script attribute contains a closing bracket" do
    html = ~s|<script type="module" data-name="a>b">import "./a.js"</script>|
    body = rewrite(html, @page)

    assert body =~ ~s|data-name="a>b"|
    refute body =~ ~s|"./a.js"|
    assert_points(body, @page, "http://example.com/blog/a.js")
  end

  test "rewrites specifiers separated by comments or written with backticks" do
    source = """
    import(/* webpackChunkName: "a" */ "/abs.js");
    import foo from /* c */ "../util.js";
    import // comment
    "./lib.js";
    import(`./dyn.js`);
    export { y } from `./tick.js`;
    import /* c */ ("./gap.js");
    import(`./${name}.js`);
    import "HTTPS://cdn.example/lib.js";
    import "react";
    import("react");
    """

    app = "http://example.com/blog/app.js"
    body = rewrite(source, app, "application/javascript", "script")

    assert body =~ "webpackChunkName"
    assert body =~ "// comment"
    assert body =~ ~s|`./${name}.js`|
    assert body =~ ~s("react")
    assert body =~ ~s|import("react")|
    refute body =~ ~s("/abs.js")
    refute body =~ ~s("../util.js")
    refute body =~ ~s("./lib.js")
    refute body =~ "./dyn.js"
    refute body =~ "./tick.js"
    refute body =~ "./gap.js"
    refute body =~ "HTTPS://cdn.example/lib.js"
    assert_points(body, app, "http://example.com/abs.js")
    assert_points(body, app, "http://example.com/util.js")
    assert_points(body, app, "http://example.com/blog/lib.js")
    assert_points(body, app, "http://example.com/blog/dyn.js")
    assert_points(body, app, "http://example.com/blog/tick.js")
    assert_points(body, app, "http://example.com/blog/gap.js")
    assert_points(body, app, "https://cdn.example/lib.js")
  end

  test "rewrites real imports after property division and keeps identifier calls intact" do
    for access <- [".", "?./* café */"], word <- ["return", "catch()"] do
      source =
        "const n = obj#{access}#{word} / 2;" <>
          ~S|$import("./fake.js"); πimport("./fake.js"); importπ("./fake.js"); a\u0061import("./fake.js"); import("./real.js"); const r = /x/;|

      assert_rewritten_module(source)
    end
  end

  defp assert_rewritten_module(source) do
    target = "http://example.com/blog/real.js"
    app = "http://example.com/blog/app.js"
    js = rewrite(source, app, "application/javascript", "script")
    js_import = ~s|import("#{Linker.offline_link(app, target)}")|
    assert js == String.replace(source, ~s|import("./real.js")|, js_import)
    assert_points(js, app, target)

    html = rewrite(~s|<script type="module">#{source}</script>|, @page)
    html_import = ~s|import("#{Linker.offline_link(@page, target)}")|
    expected = String.replace(source, ~s|import("./real.js")|, html_import)
    assert html == ~s|<script type="module">#{expected}</script>|
    assert_points(html, @page, target)
  end
end
