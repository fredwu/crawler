defmodule Crawler.OfflineSnapshotTest do
  use Crawler.TestCase, async: false

  alias Crawler.Linker
  alias Crawler.Linker.Snapshot
  alias Crawler.Store

  test "saves one file per resource and keeps the links, including fragments", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = "offline-mirror"
    root = tmp("offline-mirror")
    page = "#{url}/blog/post"
    css = "#{url}/css/app.css"
    extra = "#{url}/css/extra.css"
    app = "#{url}/blog/app.js"

    serve(site, "/blog/post", "Text/HTML; charset=UTF-8", page_html(page))
    serve(site, "/css/app.css", "Text/CSS", app_css())

    serve(
      site,
      "/css/extra.css",
      "text/css ; charset=utf-8",
      ~s|body { background: url("dot.png"); }|
    )

    serve(site, "/blog/app.js", "application/javascript", app_js())

    for path <- ~w(
      /blog/a.jpg
      /blog/b.jpg
      /blog/file.pdf
      /blog/movie.mp4
      /blog/next.html
      /blog/later.html
      /blog/plain.png
      /blog/other.html
      /blog/icons.svg
      /about
      /blog/lib.js
      /util.js
      /abs.js
      /blog/dyn.js
      /css/wide.png
      /css/narrow.png
      /images/a.png
      /css/dot.png
    ) do
      serve(site, path, "text/plain", path)
    end

    {:ok, _opts} =
      Crawler.crawl(page,
        req_options: req_options,
        save_to: root,
        workers: 2,
        max_depths: 4,
        assets: ["images", "css", "js"],
        scope: scope
      )

    urls = [
      page,
      css,
      extra,
      app,
      "#{url}/blog/a.jpg",
      "#{url}/blog/b.jpg",
      "#{url}/blog/file.pdf",
      "#{url}/blog/movie.mp4",
      "#{url}/blog/next.html",
      "#{url}/blog/later.html",
      "#{url}/blog/plain.png",
      "#{url}/blog/other.html",
      "#{url}/blog/icons.svg",
      "#{url}/about",
      "#{url}/blog/lib.js",
      "#{url}/util.js",
      "#{url}/abs.js",
      "#{url}/blog/dyn.js",
      "#{url}/css/wide.png",
      "#{url}/css/narrow.png",
      "#{url}/images/a.png",
      "#{url}/css/dot.png"
    ]

    wait(fn ->
      Enum.each(urls, fn fetched ->
        assert Store.find_processed({fetched, scope})
      end)
    end)

    assert Store.find({page <> "#section", scope}) == Store.find({page, scope})
    assert Store.find({page <> "#top", scope}) == Store.find({page, scope})

    assert Store.find({"#{url}/blog/icons.svg#a", scope}) ==
             Store.find({"#{url}/blog/icons.svg", scope})

    html = File.read!(saved(root, page))
    assert html =~ "See postcard today"
    refute html =~ ~s(href="../../about")
    refute html =~ "src=plain.png"
    refute html =~ "href=other.html"
    refute html =~ ~s(imagesrcset="a.jpg 1x, b.jpg 2x")
    refute html =~ ~s(data="file.pdf")
    refute html =~ ~s(src="movie.mp4")
    refute html =~ "url=next.html"
    refute html =~ "URL='later.html'"
    refute html =~ ~s(href="icons.svg#a")
    assert html =~ "1x"
    assert html =~ "2x"

    assert_points(html, page, "#{url}/about", root)
    assert_points(html, page, "#{url}/blog/plain.png", root)
    assert_points(html, page, "#{url}/blog/other.html", root)
    assert_points(html, page, "#{url}/blog/a.jpg", root)
    assert_points(html, page, "#{url}/blog/b.jpg", root)
    assert_points(html, page, "#{url}/blog/next.html", root)
    assert_points(html, page, "#{url}/blog/later.html", root)
    assert_points(html, page, "#{url}/blog/icons.svg", root, "#a")
    assert_points(html, page, page, root, "#section")
    assert_points(html, page, page, root, "#top")

    css_body = File.read!(saved(root, css))
    refute css_body =~ "url(../../images/a.png)"
    refute css_body =~ ~s|image-set("wide.png" 1x, "narrow.png" 2x)|
    assert css_body =~ "1x"
    assert_points(css_body, css, "#{url}/images/a.png", root)
    assert_points(css_body, css, "#{url}/css/wide.png", root)
    assert_points(css_body, css, "#{url}/css/narrow.png", root)
    assert_points(css_body, css, extra, root)

    extra_body = File.read!(saved(root, extra))
    refute extra_body =~ ~s|url("dot.png")|
    assert_points(extra_body, extra, "#{url}/css/dot.png", root)

    js = File.read!(saved(root, app))
    refute js =~ ~s("./lib.js")
    refute js =~ ~s("../util.js")
    refute js =~ ~s("/abs.js")
    refute js =~ ~s("./dyn.js")
    assert js =~ ~s("./nope.js")
    assert js =~ ~s("./also-nope.js")
    assert js =~ ~s("react")
    assert_points(js, app, "#{url}/blog/lib.js", root)
    assert_points(js, app, "#{url}/util.js", root)
    assert_points(js, app, "#{url}/abs.js", root)
    assert_points(js, app, "#{url}/blog/dyn.js", root)
  end

  test "with no assets still saves refresh, object, and embed targets", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = "offline-bare"
    page = "#{url}/bare/post"

    serve(site, "/bare/post", "text/html", """
    <link rel="preload" as="image" imagesrcset="a.jpg 1x, b.jpg 2x">
    <object data="file.pdf"></object>
    <embed src="movie.mp4">
    <meta http-equiv="refresh" content="0; url=next.html">
    <img src=plain.png>
    <a href=other.html></a>
    <script type="module">import "./lib.js";</script>
    <style>div { background: image-set("wide.png" 1x); }</style>
    """)

    for path <- ~w(/bare/file.pdf /bare/movie.mp4 /bare/next.html /bare/other.html) do
      serve(site, path, "text/plain", path)
    end

    {:ok, _opts} =
      Crawler.crawl(page,
        req_options: req_options,
        workers: 1,
        max_depths: 2,
        assets: [],
        scope: scope
      )

    wait(fn ->
      for path <- ~w(/bare/post /bare/file.pdf /bare/movie.mp4 /bare/next.html /bare/other.html) do
        assert Store.find_processed({"#{url}#{path}", scope})
      end
    end)
  end

  test "fetches host-case and dot-segment aliases once", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = "offline-identity"
    entry = "#{url}/identity/entry"
    same = "#{url}/identity/same"
    upper = String.replace(same, "://localhost:", "://LocalHost:")
    dotted = "#{url}/identity/a/../same"
    dot = "#{url}/identity/./same"
    ellipsis = "#{url}/identity/a/.../other"

    serve(site, "/identity/entry", "text/html", """
    <a href="#{upper}"></a>
    <a href="#{same}"></a>
    <a href="#{dotted}"></a>
    <a href="#{dot}"></a>
    <a href="#{ellipsis}"></a>
    """)

    serve(site, "/identity/same", "text/plain", "same")
    serve(site, "/identity/a/.../other", "text/plain", "ellipsis")

    {:ok, _opts} =
      Crawler.crawl(entry,
        req_options: req_options,
        workers: 1,
        max_depths: 2,
        scope: scope
      )

    wait(fn ->
      assert Store.find_processed({same, scope})
      assert Store.find_processed({ellipsis, scope})
    end)

    assert Store.find_processed({upper, scope})
    assert Store.find_processed({dotted, scope})
    assert Store.find_processed({dot, scope})
    assert Snapshot.path(upper) == Snapshot.path(same)
    assert Snapshot.path(dotted) == Snapshot.path(same)
    assert Snapshot.path(dot) == Snapshot.path(same)
    refute Snapshot.path(ellipsis) == Snapshot.path(same)
  end

  defp page_html(page) do
    """
    <!doctype html>
    <link rel="preload" as="image" imagesrcset="a.jpg 1x, b.jpg 2x">
    <link rel="stylesheet" href="/css/app.css">
    <object data="file.pdf"></object>
    <embed src="movie.mp4">
    <meta http-equiv="refresh" content="0; url=next.html">
    <meta http-equiv="Refresh" content="5; URL='later.html'">
    <img src=plain.png>
    <a href=other.html>other</a>
    <script type="module" src="app.js"></script>
    <a href="../../about">about</a>
    <a href="#{page}#section">section</a>
    <a href="#top">top</a>
    <svg><use href="icons.svg#a"></use></svg>
    <p>See postcard today</p>
    """
  end

  defp app_css do
    """
    @import "extra.css";
    div { background: image-set("wide.png" 1x, "narrow.png" 2x); }
    body { background: url(../../images/a.png); }
    """
  end

  defp app_js do
    """
    // import "./nope.js"
    /* import "./also-nope.js" */
    import "./lib.js";
    import helper from "../util.js";
    export { y } from "/abs.js";
    import("./dyn.js");
    import "react";
    """
  end

  defp serve(site, path, type, body) do
    ReqTestSite.expect_once(site, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", type)
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp saved(root, url), do: Path.join(root, Snapshot.path(url))

  defp assert_points(body, from_url, target_url, root, fragment \\ "") do
    href = Linker.offline_link(from_url, target_url <> fragment)
    assert body =~ href

    {path, found} = split_fragment(href)
    assert found == fragment

    assert Path.expand(path, Path.dirname(saved(root, from_url))) ==
             Path.expand(saved(root, target_url))
  end

  defp split_fragment(href) do
    case String.split(href, "#", parts: 2) do
      [path, fragment] -> {path, "#" <> fragment}
      [path] -> {path, ""}
    end
  end
end
