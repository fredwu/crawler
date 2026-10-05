defmodule Crawler.Parser.AssetDiscoveryTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser

  @page "http://example.com/blog/post"

  test "follows a modulepreload without another reference to its module" do
    html = ~s|<link rel="alternate ModulePreload" href="only.js">|
    opts = %{url: @page, html_tag: "a", content_type: "text/html", assets: ["js"]}

    assert Parser.parse_links(html, opts, fn element, opts -> {element, opts[:html_tag]} end) ==
             [{{"link", "only.js", "href", "http://example.com/blog/only.js"}, "script"}]

    assert Parser.parse_links(html, %{opts | assets: []}, fn element, _opts -> element end) == []
  end

  test "reads html and css links when the content type is not plain lowercase" do
    html = ~s(<a href="other.html"></a>)

    for type <- ["Text/HTML", "text/html ; charset=utf-8", "TEXT/HTML;charset=UTF-8"] do
      assert links(html, content_type: type, html_tag: "a") == [
               "http://example.com/blog/other.html"
             ]
    end

    css = ~s|@import "other.css"; body { background: url("dot.png"); }|

    for type <- ["Text/CSS", "text/css ; charset=utf-8"] do
      assert links(css, content_type: type, html_tag: "link", assets: []) == [
               "http://example.com/blog/dot.png",
               "http://example.com/blog/other.css"
             ]
    end
  end

  test "follows imagesrcset, image-set, object, embed, refresh, and module imports" do
    html = """
    <link rel="preload" as="image" imagesrcset="a.jpg 1x, b.jpg 2x">
    <object data="file.pdf"></object>
    <embed src="movie.mp4">
    <meta http-equiv="refresh" content="0; url=next.html">
    <meta http-equiv="Refresh" content="5; URL='later.html'">
    <img src=plain.png>
    <a href=other.html></a>
    <script type="module" src="app.js"></script>
    <script type="module">
      // import "./nope.js"
      import "./lib.js";
      import x from "../util.js";
      export { y } from "/abs.js";
      import("./dyn.js");
      import "react";
    </script>
    <style>
      div { background: image-set("wide.png" 1x, "narrow.png" 2x); }
    </style>
    """

    assert links(html, content_type: "Text/HTML", html_tag: "a") ==
             [
               "http://example.com/abs.js",
               "http://example.com/blog/a.jpg",
               "http://example.com/blog/app.js",
               "http://example.com/blog/b.jpg",
               "http://example.com/blog/dyn.js",
               "http://example.com/blog/file.pdf",
               "http://example.com/blog/later.html",
               "http://example.com/blog/lib.js",
               "http://example.com/blog/movie.mp4",
               "http://example.com/blog/narrow.png",
               "http://example.com/blog/next.html",
               "http://example.com/blog/other.html",
               "http://example.com/blog/plain.png",
               "http://example.com/blog/wide.png",
               "http://example.com/util.js"
             ]
  end

  test "with no asset flags still follows refresh, object, embed, and anchors" do
    html = """
    <link rel="preload" as="image" imagesrcset="a.jpg 1x, b.jpg 2x">
    <object data="file.pdf"></object>
    <embed src="movie.mp4">
    <meta http-equiv="refresh" content="0; url=next.html">
    <img src=plain.png>
    <a href=other.html></a>
    <script type="module">import "./lib.js";</script>
    <style>div { background: image-set("wide.png" 1x); }</style>
    """

    assert links(html, content_type: "text/html", html_tag: "a", assets: []) == [
             "http://example.com/blog/file.pdf",
             "http://example.com/blog/movie.mp4",
             "http://example.com/blog/next.html",
             "http://example.com/blog/other.html"
           ]
  end

  test "follows an import after a quote entity in a script" do
    html = """
    <script type="module">
    const note = "&#x22;";
    import "./hidden.js";
    const other = "&quot;";
    import "./next.js";
    </script>
    <script type="module">const code = "import &quot;./nope.js&quot;";</script>
    """

    assert links(html, content_type: "text/html", html_tag: "a") == [
             "http://example.com/blog/hidden.js",
             "http://example.com/blog/next.js"
           ]
  end

  test "keeps style text raw while decoding entities in style attributes" do
    html =
      ~s|<style>.raw { background: url("raw.png?x=1&amp;y=2") }</style>| <>
        ~s|<div style="background:url(&quot;attribute.png?x=1&amp;y=2&quot;)"></div>|

    assert links(html, content_type: "text/html", html_tag: "a") == [
             "http://example.com/blog/attribute.png?x=1&y=2",
             "http://example.com/blog/raw.png?x=1&amp;y=2"
           ]
  end

  test "skips json-ld and reads a javascript script whose type is not lowercase" do
    html = """
    <script type="application/ld+json">
    import "./nope.js";
    </script>
    <script type="Text/JavaScript">
    import "./lib.js";
    </script>
    """

    assert links(html, content_type: "text/html", html_tag: "a") == [
             "http://example.com/blog/lib.js"
           ]
  end

  test "follows imports inside a javascript response" do
    source = """
    import "./lib.js";
    export { y } from "/abs.js";
    import "react";
    """

    assert links(source, content_type: "application/javascript", html_tag: "script", assets: []) ==
             [
               "http://example.com/abs.js",
               "http://example.com/blog/lib.js"
             ]
  end

  defp links(body, opts) do
    opts =
      Map.merge(
        %{
          url: @page,
          referrer_url: @page,
          assets: ["images", "css", "js"],
          html_tag: "a",
          content_type: "text/html"
        },
        Map.new(opts)
      )

    parent = self()

    Parser.parse_links(body, opts, fn element, _opts ->
      send(parent, {:link, link_url(element)})
    end)

    collect()
  end

  defp link_url({_tag, _raw, _attr, url}), do: url
  defp link_url({_attr, url}), do: url

  defp collect(acc \\ []) do
    receive do
      {:link, url} -> collect([url | acc])
    after
      0 -> Enum.sort(acc)
    end
  end
end
