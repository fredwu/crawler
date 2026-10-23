defmodule Crawler.CrawlDocumentScopeTest do
  use Crawler.TestCase, async: false

  import Plug.Conn
  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  @diagram """
  <?xml-stylesheet type="text/css" href="theme.css"?>
  <svg><image href="icon.png"/><rect fill="url(paint.png)"/></svg>
  """

  @picture """
  <?xml-stylesheet type="text/css" href="theme.css"?>
  <svg><image href="icon.png"/><rect fill="url(paint.png)"/></svg>
  """

  test "live frames, shadow roots, and svg documents make requests inert markup does not",
       context do
    page = context.url <> "/dir/page"
    scope = unique_scope("document-scope")
    root = Path.join(tmp(), scope <> "-#{Base.encode16(:crypto.strong_rand_bytes(6))}")
    on_exit(fn -> File.rm_rf(root) end)

    html = """
    <base href="/assets/">
    <style type="text/plain">body { background: url(plain-style.png) }</style>
    <template><a href="inert.html">Inert</a></template>
    <template shadowrootmode="open">
      <base href="/wrong/">
      <a href="live.html">Live</a>
      <script src="app.js"></script>
    </template>
    <iframe src="/frame.html" srcdoc="&lt;a href=&quot;framed.html&quot;&gt;F&lt;/a&gt;"></iframe>
    <svg><rect fill="url(paint.png)"/></svg>
    <a href="/diagram.svg">Diagram</a>
    <img src="/images/picture.svg">
    """

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, html))
    expect_html(context, "/assets/live.html", "live")
    expect_bytes(context, "/assets/app.js", "text/javascript", "js")
    expect_html(context, "/assets/framed.html", "framed")
    expect_bytes(context, "/assets/paint.png", "image/png", "png")
    expect_svg(context, "/diagram.svg", @diagram, "image/svg+xml")
    expect_bytes(context, "/theme.css", "text/css", "css")
    expect_bytes(context, "/icon.png", "image/png", "png")
    expect_bytes(context, "/paint.png", "image/png", "png")
    expect_svg(context, "/images/picture.svg", @picture, "image/svg+xml")

    opts = crawl(page, context, root, scope, ["css", "images", "js"])

    for path <- [
          "/assets/live.html",
          "/assets/app.js",
          "/assets/framed.html",
          "/assets/paint.png",
          "/diagram.svg",
          "/theme.css",
          "/icon.png",
          "/paint.png",
          "/images/picture.svg"
        ] do
      assert Store.find_processed({context.url <> path, scope})
    end

    for path <- [
          "/frame.html",
          "/assets/inert.html",
          "/assets/plain-style.png",
          "/wrong/live.html",
          "/images/theme.css",
          "/images/icon.png",
          "/images/paint.png"
        ] do
      refute Store.find({context.url <> path, scope})
    end

    export = ready_export(opts)
    source = resource_for_url(export, page)
    saved = read_resource(export, source)
    assert saved =~ ~s|src="/frame.html"|
    assert saved =~ "inert.html"
    assert saved =~ "plain-style.png"
    refute saved =~ ~s|href="live.html"|
    refute saved =~ "url(paint.png)"

    assert read_resource(
             export,
             reference_target(export, source, context.url <> "/images/picture.svg")
           ) == @picture

    refute read_resource(export, reference_target(export, source, context.url <> "/diagram.svg")) =~
             ~s|href="theme.css"|

    diagram = reference_target(export, source, context.url <> "/diagram.svg")
    assert_link_opens(export, source, diagram)

    for {url, body} <- [
          {context.url <> "/theme.css", "css"},
          {context.url <> "/icon.png", "png"},
          {context.url <> "/paint.png", "png"}
        ] do
      target = reference_target(export, diagram, url)
      assert_link_opens(export, diagram, target)
      assert read_resource(export, target) == body
    end

    refute Crawler.running?(opts)
  end

  test "XML stylesheet instructions share document variables in the saved SVG", context do
    page = context.url <> "/drawing.svg"
    scope = unique_scope("xml-stylesheet-group")
    root = Path.join(tmp(), scope <> "-#{Base.encode16(:crypto.strong_rand_bytes(6))}")
    on_exit(fn -> File.rm_rf(root) end)

    drawing = """
    <?xml-stylesheet type="text/css" href="defs.css"?>
    <?xml-stylesheet type="text/css" href="reader.css"?>
    <svg xmlns="http://www.w3.org/2000/svg"><rect class="paint"/></svg>
    """

    definitions = ~s|:root{--paint:url("paint.png");--idle:url("idle.png")}|
    reader = ".paint{fill:var(--paint)}"
    image = <<137, 80, 78, 71, 0, 255>>
    expect_svg(context, "/drawing.svg", drawing, "image/svg+xml")
    expect_bytes(context, "/defs.css", "text/css", definitions)
    expect_bytes(context, "/reader.css", "text/css", reader)
    expect_bytes(context, "/paint.png", "image/png", image)

    opts = crawl(page, context, root, scope, ["css", "images"])
    export = ready_export(opts)
    source = resource_for_url(export, page)
    definitions_resource = reference_target(export, source, context.url <> "/defs.css")
    reader_resource = reference_target(export, source, context.url <> "/reader.css")
    picture = reference_target(export, definitions_resource, context.url <> "/paint.png")
    assert source["content_type"] == "image/svg+xml"
    assert definitions_resource["content_type"] == "text/css"
    assert reader_resource["content_type"] == "text/css"
    assert picture["content_type"] == "image/png"
    assert read_resource(export, picture) == image
    assert read_resource(export, reader_resource) == reader
    refute Store.find({context.url <> "/idle.png", scope})

    expected_drawing =
      drawing
      |> String.replace("defs.css", relative_reference(source, definitions_resource))
      |> String.replace("reader.css", relative_reference(source, reader_resource))

    assert read_resource(export, source) == expected_drawing

    assert read_resource(export, definitions_resource) ==
             String.replace(
               definitions,
               "paint.png",
               relative_reference(definitions_resource, picture)
             )

    assert_link_opens(export, source, definitions_resource)
    assert_link_opens(export, source, reader_resource)
    assert_link_opens(export, definitions_resource, picture)
  end

  defp crawl(page, context, root, scope, assets) do
    {:ok, opts} =
      start_crawl(page,
        scope: scope,
        workers: 1,
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        max_manifest_bytes: 16_777_216,
        retries: 0,
        max_depths: 3,
        assets: assets,
        store: Store,
        save_to: root,
        req_options: context.req_options
      )

    on_exit(fn -> Crawler.stop(opts) end)
    ready_export(opts)
    opts
  end

  defp expect_svg(context, path, body, content_type) do
    ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
      conn
      |> put_resp_header("content-type", content_type)
      |> resp(200, body)
    end)
  end

  defp expect_bytes(context, path, content_type, body) do
    ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
      conn
      |> put_resp_header("content-type", content_type)
      |> resp(200, body)
    end)
  end

  defp expect_html(context, path, body) do
    ReqTestSite.expect_once(context.site, "GET", path, &html(&1, body))
  end

  defp html(conn, body) do
    conn
    |> put_resp_header("content-type", "text/html")
    |> resp(200, body)
  end
end
