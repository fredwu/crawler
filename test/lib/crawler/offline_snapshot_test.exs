defmodule Crawler.OfflineSnapshotTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  test "saves one file per resource and keeps the links, including fragments", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = "offline-mirror"
    root = Path.join(tmp("offline-mirror"), "archive")
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

    {:ok, opts} =
      start_crawl(page,
        req_options: req_options,
        save_to: root,
        max_manifest_bytes: 16_777_216,
        workers: 1,
        max_body: 1_048_576,
        max_analysis_bytes: 16_777_216,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        max_depths: 2,
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

    export = ready_export(opts)

    wait(fn ->
      Enum.each(urls, fn fetched ->
        assert Store.find_processed({fetched, scope})
      end)
    end)

    assert Store.find({page <> "#section", scope}) == Store.find({page, scope})
    assert Store.find({page <> "#top", scope}) == Store.find({page, scope})

    assert Store.find({"#{url}/blog/icons.svg#a", scope}) ==
             Store.find({"#{url}/blog/icons.svg", scope})

    source = root_resource(export, opts)
    html = read_resource(export, source)
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

    assert_variant_points(html, source, "#{url}/about", export)
    assert_variant_points(html, source, "#{url}/blog/plain.png", export)
    assert_variant_points(html, source, "#{url}/blog/other.html", export)
    assert_variant_points(html, source, "#{url}/blog/a.jpg", export)
    assert_variant_points(html, source, "#{url}/blog/b.jpg", export)
    assert_variant_points(html, source, "#{url}/blog/next.html", export)
    assert_variant_points(html, source, "#{url}/blog/later.html", export)
    assert_variant_points(html, source, "#{url}/blog/icons.svg", export, "#a")
    assert_variant_points(html, source, page, export, "#section")
    assert_variant_points(html, source, page, export, "#top")

    stylesheet = reference_target(export, source, css)
    css_body = read_resource(export, stylesheet)
    refute css_body =~ "url(../../images/a.png)"
    refute css_body =~ ~s|image-set("wide.png" 1x, "narrow.png" 2x)|
    assert css_body =~ "1x"
    assert_variant_points(css_body, stylesheet, "#{url}/images/a.png", export)
    assert_variant_points(css_body, stylesheet, "#{url}/css/wide.png", export)
    assert_variant_points(css_body, stylesheet, "#{url}/css/narrow.png", export)
    assert_variant_points(css_body, stylesheet, extra, export)

    extra_resource = reference_target(export, stylesheet, extra)
    extra_body = read_resource(export, extra_resource)
    refute extra_body =~ ~s|url("dot.png")|
    assert_variant_points(extra_body, extra_resource, "#{url}/css/dot.png", export)

    script = reference_target(export, source, app)
    js = read_resource(export, script)
    refute js =~ ~s("./lib.js")
    refute js =~ ~s("../util.js")
    refute js =~ ~s("/abs.js")
    refute js =~ ~s("./dyn.js")
    assert js =~ ~s("./nope.js")
    assert js =~ ~s("./also-nope.js")
    assert js =~ ~s("react")
    assert_variant_points(js, script, "#{url}/blog/lib.js", export)
    assert_variant_points(js, script, "#{url}/util.js", export)
    assert_variant_points(js, script, "#{url}/abs.js", export)
    assert_variant_points(js, script, "#{url}/blog/dyn.js", export)

    replacements = [
      {~s(imagesrcset="a.jpg 1x, b.jpg 2x"),
       ~s(imagesrcset="#{relative_reference(source, reference_target(export, source, url <> "/blog/a.jpg"))} 1x, #{relative_reference(source, reference_target(export, source, url <> "/blog/b.jpg"))} 2x")},
      {~s(href="/css/app.css"),
       ~s(href="#{relative_reference(source, reference_target(export, source, css))}")},
      {~s(data="file.pdf"),
       ~s(data="#{relative_reference(source, reference_target(export, source, url <> "/blog/file.pdf"))}")},
      {~s(src="movie.mp4"),
       ~s(src="#{relative_reference(source, reference_target(export, source, url <> "/blog/movie.mp4"))}")},
      {"url=next.html",
       "url=" <>
         relative_reference(source, reference_target(export, source, url <> "/blog/next.html"))},
      {"URL='later.html'",
       "URL='" <>
         relative_reference(source, reference_target(export, source, url <> "/blog/later.html")) <>
         "'"},
      {"src=plain.png",
       "src=" <>
         relative_reference(source, reference_target(export, source, url <> "/blog/plain.png"))},
      {"href=other.html",
       "href=" <>
         relative_reference(source, reference_target(export, source, url <> "/blog/other.html"))},
      {~s(src="app.js"),
       ~s(src="#{relative_reference(source, reference_target(export, source, app))}")},
      {~s(href="../../about"),
       ~s(href="#{relative_reference(source, reference_target(export, source, url <> "/about"))}")},
      {~s(href="#{page}#section"),
       ~s(href="#{relative_reference(source, reference_target(export, source, page), "#section")}")},
      {~s(href="#top"),
       ~s(href="#{relative_reference(source, reference_target(export, source, page), "#top")}")},
      {~s(href="icons.svg#a"),
       ~s(href="#{relative_reference(source, reference_target(export, source, url <> "/blog/icons.svg"), "#a")}")}
    ]

    assert html ==
             <<0xEF, 0xBB, 0xBF>> <>
               Enum.reduce(replacements, page_html(page), fn {from, to}, body ->
                 String.replace(body, from, to)
               end)

    for {resource, original, refs} <- [
          {stylesheet, app_css(),
           [
             {"extra.css", extra},
             {"wide.png", url <> "/css/wide.png"},
             {"narrow.png", url <> "/css/narrow.png"},
             {"../../images/a.png", url <> "/images/a.png"}
           ]},
          {extra_resource, ~s|body { background: url("dot.png"); }|,
           [{"dot.png", url <> "/css/dot.png"}]},
          {script, app_js(),
           [
             {"./lib.js", url <> "/blog/lib.js"},
             {"../util.js", url <> "/util.js"},
             {"/abs.js", url <> "/abs.js"},
             {"./dyn.js", url <> "/blog/dyn.js"}
           ]}
        ] do
      expected =
        Enum.reduce(refs, original, fn {literal, target_url}, body ->
          target = reference_target(export, resource, target_url)

          if target_url == extra do
            assert target["id"] == extra_resource["id"]
          else
            assert read_resource(export, target) == URI.parse(target_url).path
          end

          String.replace(body, literal, relative_reference(resource, target))
        end)

      assert read_resource(export, resource) == expected
    end

    for target_url <- urls -- [page, css, extra, app] do
      resources = Enum.filter(export.manifest["resources"], &(&1["url"] == target_url))
      assert resources != []
      assert Enum.all?(resources, &(read_resource(export, &1) == URI.parse(target_url).path))
    end
  end

  test "with no assets still saves refresh, object, and embed targets", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = "offline-bare"
    root = Path.join(tmp(unique_scope(scope)), "archive")
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

    {:ok, opts} =
      start_crawl(page,
        req_options: req_options,
        workers: 1,
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        max_depths: 2,
        assets: [],
        save_to: root,
        max_manifest_bytes: 16_777_216,
        scope: scope
      )

    wait(fn ->
      for path <- ~w(/bare/post /bare/file.pdf /bare/movie.mp4 /bare/next.html /bare/other.html) do
        assert Store.find_processed({"#{url}#{path}", scope})
      end
    end)

    export = ready_export(opts)
    source = resource_for_url(export, page)

    for path <- ~w(/bare/file.pdf /bare/movie.mp4 /bare/next.html /bare/other.html) do
      target = reference_target(export, source, url <> path)
      assert read_resource(export, target) == path
    end
  end

  test "fetches host-case and dot-segment aliases once", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = "offline-identity"
    root = Path.join(tmp(unique_scope(scope)), "archive")
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

    {:ok, opts} =
      start_crawl(entry,
        req_options: req_options,
        workers: 1,
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        max_depths: 2,
        save_to: root,
        max_manifest_bytes: 16_777_216,
        scope: scope
      )

    wait(fn ->
      assert Store.find_processed({same, scope})
      assert Store.find_processed({ellipsis, scope})
    end)

    assert Store.find_processed({upper, scope})
    assert Store.find_processed({dotted, scope})
    assert Store.find_processed({dot, scope})
    export = ready_export(opts)
    source = resource_for_url(export, entry)
    hrefs = Floki.attribute(Floki.parse_document!(read_resource(export, source)), "a", "href")

    targets =
      for {href, index} <- Enum.with_index(hrefs) do
        target = edge_target(export, source, index)
        assert_opens(export, source, target, href)
        target
      end

    assert [first, first, first, first, other] = targets
    refute first["id"] == other["id"]
    assert read_resource(export, first) == "same"
    assert read_resource(export, other) == "ellipsis"
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

  defp assert_variant_points(body, source, url, export, fragment \\ "") do
    target = reference_target(export, source, url)
    href = relative_reference(source, target, fragment)
    assert body =~ href
    assert_opens(export, source, target, href, fragment)
  end

  defp root_resource(export, opts) do
    record = :sys.get_state(Store).exports[{opts.scope, opts.generation}]
    resource_by_id(export, record.target_contexts[opts.target_handle].public_id)
  end
end
