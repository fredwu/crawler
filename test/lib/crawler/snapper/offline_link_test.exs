defmodule Crawler.Snapper.OfflineLinkTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker
  alias Crawler.Linker.Snapshot
  alias Crawler.Snapper.LinkReplacer

  @page "http://example.com/blog/post"

  test "keeps fragments on anchors and svg sprites" do
    html = """
    <a href="post.html?q=1#section"></a>
    <a href="#top"></a>
    <svg><use href="icons.svg#a"></use><use xlink:href="sprite.svg#b"></use></svg>
    """

    body = rewrite(html, @page)

    assert_points(body, @page, "http://example.com/blog/post.html?q=1", "#section")
    assert_points(body, @page, @page, "#top")
    assert_points(body, @page, "http://example.com/blog/icons.svg", "#a")
    assert_points(body, @page, "http://example.com/blog/sprite.svg", "#b")
    refute body =~ "post.html?q=1#section"
    refute body =~ ~s(href="#top")
    refute body =~ ~s(href="icons.svg#a")
    refute body =~ ~s(xlink:href="sprite.svg#b")
  end

  test "rewrites unquoted links from a directory index" do
    body = rewrite(~s(<img src=plain.png><a href=other.html></a>), @page)

    refute body =~ "src=plain.png"
    refute body =~ "href=other.html"
    assert_points(body, @page, "http://example.com/blog/plain.png")
    assert_points(body, @page, "http://example.com/blog/other.html")
  end

  test "rewrites imagesrcset, image-set, object, embed, and meta refresh" do
    html = """
    <link rel="preload" as="image" imagesrcset="a.jpg 1x, b.jpg 2x">
    <object data="file.pdf"></object>
    <embed src="movie.mp4"></embed>
    <meta http-equiv="refresh" content="0; url=next.html">
    <meta http-equiv="Refresh" content="5; URL='later.html'">
    <style>div { background: image-set("wide.png" 1x, "narrow.png" 2x); }</style>
    """

    body = rewrite(html, @page)

    refute body =~ ~s(imagesrcset="a.jpg 1x, b.jpg 2x")
    refute body =~ ~s(data="file.pdf")
    refute body =~ ~s(src="movie.mp4")
    refute body =~ "url=next.html"
    refute body =~ "URL='later.html'"
    refute body =~ ~s|image-set("wide.png" 1x, "narrow.png" 2x)|
    assert body =~ "1x"
    assert body =~ "2x"
    assert_points(body, @page, "http://example.com/blog/a.jpg")
    assert_points(body, @page, "http://example.com/blog/b.jpg")
    assert_points(body, @page, "http://example.com/blog/file.pdf")
    assert_points(body, @page, "http://example.com/blog/movie.mp4")
    assert_points(body, @page, "http://example.com/blog/next.html")
    assert_points(body, @page, "http://example.com/blog/later.html")
    assert_points(body, @page, "http://example.com/blog/wide.png")
    assert_points(body, @page, "http://example.com/blog/narrow.png")
  end

  test "keeps the next image-set file when another candidate is a data url" do
    css = ~s|div { background: image-set(url("data:image/png;base64,abc") 1x, "b.png" 2x); }|
    body = rewrite(css, "http://example.com/css/app.css", "text/css", "link")

    assert body =~ ~s|url("data:image/png;base64,abc") 1x|
    refute body =~ ~s|"b.png"|
    assert_points(body, "http://example.com/css/app.css", "http://example.com/css/b.png")
  end

  test "rewrites an unquoted image-set and leaves a refresh url in prose" do
    html = """
    <p>See url=next.html today</p>
    <meta http-equiv="refresh" content="0; url=next.html">
    <style>div { background: image-set(wide.png 1x, narrow.png 2x); }</style>
    """

    body = rewrite(html, @page)

    assert body =~ "See url=next.html today"
    refute body =~ ~s(content="0; url=next.html")
    refute body =~ "image-set(wide.png 1x, narrow.png 2x)"
    assert body =~ "1x"
    assert_points(body, @page, "http://example.com/blog/next.html")
    assert_points(body, @page, "http://example.com/blog/wide.png")
    assert_points(body, @page, "http://example.com/blog/narrow.png")
  end

  test "rewrites every repeated unquoted image-set and leaves nearby text" do
    css = """
    /* wide.png 1x */
    .a { background: image-set(wide.png 1x); }
    .b { background: image-set(wide.png 1x, narrow.png 2x); }
    .c { background: image-set(wide.png 1x, narrow.png 2x); }
    .d { background: image-set(wide.png); }
    .e { background: image-set(wide.png); }
    """

    page = "http://example.com/css/app.css"
    body = rewrite(css, page, "text/css", "link")
    wide = Linker.offline_link(page, "http://example.com/css/wide.png")
    narrow = Linker.offline_link(page, "http://example.com/css/narrow.png")

    assert body =~ "/* wide.png 1x */"
    refute body =~ "image-set(wide.png 1x)"
    refute body =~ "image-set(wide.png 1x, narrow.png 2x)"
    refute body =~ "image-set(wide.png)"
    refute body =~ "css/../../"
    assert occurrences(body, wide) == 5
    assert occurrences(body, narrow) == 2
    assert_points(body, page, "http://example.com/css/wide.png")
    assert_points(body, page, "http://example.com/css/narrow.png")
  end

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

  test "keeps distinct letter case inside hex image-set quotes" do
    html =
      ~s|<style>div { background: image-set(&#x27;A.png&#x27; 1x, &#x27;a.png&#x27; 2x); }</style>|

    body = rewrite(html, @page)

    assert_points(body, @page, "http://example.com/blog/A.png")
    assert_points(body, @page, "http://example.com/blog/a.png")
  end

  test "rewrites apostrophe entities in refresh and style attributes" do
    html =
      ~s|<meta http-equiv="refresh" content="0; URL=&apos;later.html&apos;"><div style="background: url(&apos;a.png&apos;)"></div><div style="background: image-set(&apos;b.png&apos; 1x)"></div>|

    body = rewrite(html, @page)

    refute body =~ "&apos;later.html&apos;"
    refute body =~ "&apos;a.png&apos;"
    refute body =~ "&apos;b.png&apos;"
    assert_points(body, @page, "http://example.com/blog/later.html")
    assert_points(body, @page, "http://example.com/blog/a.png")
    assert_points(body, @page, "http://example.com/blog/b.png")
  end

  test "rewrites an unquoted srcset list" do
    html = ~s|<img srcset=a.jpg,b.jpg><link rel="preload" as="image" imagesrcset=a.jpg,b.jpg>|
    body = rewrite(html, @page)
    wide = Linker.offline_link(@page, "http://example.com/blog/a.jpg")

    refute body =~ "srcset=a.jpg,b.jpg"
    refute body =~ "imagesrcset=a.jpg,b.jpg"
    assert occurrences(body, wide) == 2
    assert_points(body, @page, "http://example.com/blog/a.jpg")
    assert_points(body, @page, "http://example.com/blog/b.jpg")
  end

  test "rewrites a nested image-set and a stylesheet that is not utf-8" do
    css = "http://example.com/css/app.css"

    nested =
      rewrite(~s|div { background: image-set(image-set(a.png) 1x); }|, css, "text/css", "link")

    refute nested =~ "image-set(a.png)"
    assert_points(nested, css, "http://example.com/css/a.png")

    latin = "div{background:url(\"shown.png\")} image-set(\"caf" <> <<0xE9>> <> ".png\")"
    body = rewrite(latin, css, "text/css", "link")
    assert_points(body, css, "http://example.com/css/shown.png")
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

  test "rewrites a refresh url when an earlier attribute contains a closing bracket" do
    html = ~s|<meta data-name="a>b" http-equiv="refresh" content="0; url=next.html">|
    body = rewrite(html, @page)

    assert body =~ ~s|data-name="a>b"|
    refute body =~ "url=next.html"
    assert_points(body, @page, "http://example.com/blog/next.html")

    quoted = ~s|<meta http-equiv="refresh" content="0; url='a>b.html'">|
    quoted_body = rewrite(quoted, @page)
    refute quoted_body =~ "url='a>b.html'"
    assert_points(quoted_body, @page, "http://example.com/blog/a>b.html")
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

  test "drops a base tag when an attribute contains a closing bracket" do
    html =
      ~s|<head><base data-name="a>b" href="https://example.com/dir/"></head><a href="next.html"></a>|

    body = rewrite(html, @page)

    refute body =~ "<base"
    refute body =~ "https://example.com/dir"
    assert_points(body, @page, "https://example.com/dir/next.html")

    closed = ~s|<base href="https://example.com/dir/" />|
    refute rewrite(closed, @page) =~ "<base"
  end

  test "does not rewrite a parent prefix inside a longer unquoted link" do
    page = "http://example.com/blog/post/"

    html = """
    <a href="..">up</a>
    <img src=plain.png>
    <a href=other.html>next</a>
    <a href="../..">top</a>
    <img src=icon.png/>
    """

    body = rewrite(html, page)
    assert_points(body, page, "http://example.com/blog/")
    assert_points(body, page, "http://example.com/")
    assert_points(body, page, "http://example.com/blog/post/plain.png")
    assert_points(body, page, "http://example.com/blog/post/other.html")
    assert_points(body, page, "http://example.com/blog/post/icon.png")
    refute body =~ "__index.html/"
  end

  test "leaves an unquoted attribute in prose" do
    html = """
    <a href=other.html></a><p>Type href=other.html to continue</p>
    <img alt="a>b" src=plain.png>
    """

    body = rewrite(html, @page)
    assert body =~ "<p>Type href=other.html to continue</p>"
    refute body =~ "<a href=other.html>"
    assert body =~ ~s|alt="a>b"|
    assert_points(body, @page, "http://example.com/blog/other.html")
    assert_points(body, @page, "http://example.com/blog/plain.png")
  end

  test "does not rewrite a file name inside a data url" do
    css =
      ~s|div { background: image-set("data:text/css,body{background:url('a.png')}" 1x, "b.png" 2x); }|

    body = rewrite(css, "http://example.com/css/app.css", "text/css", "link")
    assert body =~ "url('a.png')"
    refute body =~ ~s|"b.png"|
    assert_points(body, "http://example.com/css/app.css", "http://example.com/css/b.png")
  end

  test "rewrites a refresh url that has spaces inside its quotes" do
    html = ~s|<meta http-equiv="refresh" content="0; url=' next.html '">|

    body = rewrite(html, @page)
    refute body =~ "url=' next.html '"
    assert_points(body, @page, "http://example.com/blog/next.html")
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

  test "rewrites hexadecimal double quotes without folding letter case" do
    html = """
    <meta http-equiv="refresh" content="0; url=&#x22;next.html&#x22;">
    <meta http-equiv="refresh" content="0; url=&#X0022;Later.html&#x0022;">
    <div style="background: image-set(&#x22;a.png&#x22; 1x)"></div>
    <style>div { background: image-set(&#X22;A.PNG&#x22; 1x, &#x22;a.png&#x22; 2x); }</style>
    <style>@import &#x22;theme.css&#x22;; div { background: url(&#x22;pic.png&#x22;); }</style>
    """

    body = rewrite(html, @page)

    refute body =~ "&#x22;next.html&#x22;"
    refute body =~ "&#X0022;Later.html&#x0022;"
    refute body =~ "&#x22;a.png&#x22;"
    refute body =~ "&#x22;A.PNG&#x22;"
    refute body =~ "&#x22;theme.css&#x22;"
    refute body =~ "&#x22;pic.png&#x22;"
    assert_points(body, @page, "http://example.com/blog/next.html")
    assert_points(body, @page, "http://example.com/blog/Later.html")
    assert_points(body, @page, "http://example.com/blog/a.png")
    assert_points(body, @page, "http://example.com/blog/A.PNG")
    assert_points(body, @page, "http://example.com/blog/theme.css")
    assert_points(body, @page, "http://example.com/blog/pic.png")
  end

  test "rewrites the page when a script contains a non-utf8 byte" do
    html = "<script>var caf" <> <<0xE9>> <> "=1; import \"./a.js\";</script><a href=\"p.html\">"
    body = rewrite(html, @page)

    assert_points(body, @page, "http://example.com/blog/p.html")
    assert_points(body, @page, "http://example.com/blog/a.js")
  end

  test "rewrites a stylesheet that climbs out of the host" do
    css = "http://example.com/css/app.css"

    body =
      rewrite(
        ~s|body { background: url(../../images/a.png); }|,
        css,
        "Text/CSS",
        "link"
      )

    refute body =~ "url(../../images/a.png)"
    assert_points(body, css, "http://example.com/images/a.png")
  end

  defp rewrite(body, url, content_type \\ "text/html", html_tag \\ "a") do
    assert {:ok, rewritten} =
             LinkReplacer.replace_links(body, %{
               url: url,
               referrer_url: url,
               content_type: content_type,
               html_tag: html_tag,
               assets: ["images", "css", "js"],
               depth: 1,
               max_depths: 3
             })

    rewritten
  end

  defp assert_points(body, from_url, target_url, fragment \\ "") do
    href = Linker.offline_link(from_url, target_url <> fragment)
    assert body =~ href

    {path, found} = split_fragment(href)
    assert found == fragment

    assert Path.expand(path, Path.dirname(Snapshot.path(from_url))) ==
             Path.expand(Snapshot.path(target_url))
  end

  defp split_fragment(href) do
    case String.split(href, "#", parts: 2) do
      [path, fragment] -> {path, "#" <> fragment}
      [path] -> {path, ""}
    end
  end

  defp occurrences(body, text) do
    body |> String.split(text) |> length() |> Kernel.-(1)
  end
end
