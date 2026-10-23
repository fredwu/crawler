defmodule Crawler.CrawlDocumentReaderTest do
  use Crawler.TestCase, async: false

  import Plug.Conn
  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  @plain "See <a href=\"/secret\">secret</a> and @import \"x.css\""

  test "plain text is stored and contributes no addresses", context do
    page = context.url <> "/start"

    html = """
    <a href="/notes.txt">Notes</a>
    <meta http-equiv="refresh" content="0; url=/landed.txt">
    <iframe src="/frame.txt"></iframe>
    <a href="/notes.md">Markdown</a>
    <a href="/sheet.csv">Sheet</a>
    """

    expect_html(context, "/start", html)

    for path <- ["/notes.txt", "/landed.txt", "/frame.txt"] do
      expect_bytes(context, path, "text/plain", @plain)
    end

    expect_bytes(context, "/notes.md", "text/markdown", @plain)
    expect_bytes(context, "/sheet.csv", "text/csv", @plain)

    {opts, root} = run(page, context, assets: ["css", "js", "images"])

    for path <- ["/notes.txt", "/landed.txt", "/frame.txt", "/notes.md", "/sheet.csv"] do
      assert read_resource(
               root,
               reference_target(root, resource_for_url(root, page), context.url <> path)
             ) == @plain

      assert %Store.Page{processed: true, body: @plain} =
               Store.find_processed({context.url <> path, opts.scope})
    end

    refute Store.find({context.url <> "/secret", opts.scope})
    refute Store.find({context.url <> "/x.css", opts.scope})
  end

  test "a stylesheet is read only when the response is css", context do
    page = context.url <> "/styled"
    css = context.url <> "/app.css"
    html_body = "<a href=\"/secret\"></a>\n@import \"other.css\";\n"

    expect_html(context, "/styled", """
    <link rel="stylesheet" href="/app.css">
    <link rel="alternate stylesheet" href="/alt.css" title="Alt">
    """)

    ReqTestSite.expect_once(context.site, "GET", "/app.css", fn conn ->
      conn
      |> put_resp_header("content-type", "text/html")
      |> put_resp_header("link", ~s|</from-header.css>; rel="stylesheet"|)
      |> put_resp_header("refresh", "0; url=/refreshed")
      |> resp(200, html_body)
    end)

    expect_bytes(context, "/alt.css", "text/css", "body{}")

    {opts, root} = run(page, context, assets: ["css"])

    assert read_resource(root, reference_target(root, resource_for_url(root, page), css)) ==
             html_body

    assert Store.find_processed({context.url <> "/alt.css", opts.scope})
    refute Store.find({context.url <> "/secret", opts.scope})
    refute Store.find({context.url <> "/other.css", opts.scope})
    refute Store.find({context.url <> "/from-header.css", opts.scope})
    refute Store.find({context.url <> "/refreshed", opts.scope})
  end

  test "a css response keeps its imports and ignores an anchor in a comment", context do
    page = context.url <> "/styled"
    css = context.url <> "/app.css"
    other = context.url <> "/other.css"
    image = context.url <> "/bg.png"

    sheet = """
    @import "other.css";
    /* <a href="/secret">secret</a> */
    a { background: url("bg.png"); }
    """

    expect_html(context, "/styled", ~s|<link rel="stylesheet" href="/app.css">|)
    expect_bytes(context, "/app.css", "text/css; charset=utf-8", sheet)
    expect_bytes(context, "/other.css", "text/css", "body{}")
    expect_bytes(context, "/bg.png", "image/png", "png")

    {opts, root} = run(page, context, assets: ["css"])
    saved_css = read_resource(root, reference_target(root, resource_for_url(root, page), css))

    assert Store.find_processed({other, opts.scope})
    assert Store.find_processed({image, opts.scope})
    refute Store.find({context.url <> "/secret", opts.scope})
    assert saved_css =~ ~s|<a href="/secret">|

    assert_link_opens(
      root,
      reference_target(root, resource_for_url(root, page), css),
      reference_target(root, reference_target(root, resource_for_url(root, page), css), other)
    )

    assert_link_opens(
      root,
      reference_target(root, resource_for_url(root, page), css),
      reference_target(root, reference_target(root, resource_for_url(root, page), css), image)
    )
  end

  test "a script is read only when the response is javascript", context do
    page = context.url <> "/scripts"
    script = context.url <> "/app.js"
    html_script = context.url <> "/html.js"
    plain_script = context.url <> "/plain.js"
    dep = context.url <> "/dep.js"
    js = "import \"./dep.js\";\nconst html = \"<a href='/secret'>\";\n"
    html_body = "<a href=\"/secret\"></a>\nimport \"./dep.js\";\n"

    expect_html(context, "/scripts", """
    <script type="module" src="/app.js"></script>
    <script src="/html.js"></script>
    <script src="/plain.js"></script>
    """)

    expect_bytes(context, "/app.js", "application/javascript", js)
    expect_bytes(context, "/html.js", "text/html", html_body)
    expect_bytes(context, "/plain.js", "text/plain", html_body)
    expect_bytes(context, "/dep.js", "text/javascript", "dep")

    {opts, root} = run(page, context, assets: ["js"])
    script_resource = reference_target(root, resource_for_url(root, page), script)
    dependency = reference_target(root, script_resource, dep)
    saved_js = read_resource(root, script_resource)

    assert %Store.Page{processed: true, body: "dep"} = Store.find_processed({dep, opts.scope})
    assert read_resource(root, dependency) == "dep"
    refute Store.find({context.url <> "/secret", opts.scope})
    assert saved_js =~ "<a href='/secret'>"

    assert_link_opens(root, script_resource, dependency)

    assert read_resource(root, reference_target(root, resource_for_url(root, page), html_script)) ==
             html_body

    assert read_resource(root, reference_target(root, resource_for_url(root, page), plain_script)) ==
             html_body
  end

  test "the response type wins over the file name and the referring tag", context do
    page = context.url <> "/typed"
    readme = context.url <> "/readme.txt"

    expect_html(context, "/typed", """
    <a href="/readme.txt">Readme</a>
    <a href="/app.css">CSS</a>
    <a href="/app.js">JS</a>
    <a href="/page.xhtml">XHTML</a>
    """)

    expect_bytes(context, "/readme.txt", "text/plain", @plain)
    expect_bytes(context, "/app.css", "text/css", ~s|@import "other.css";|)
    expect_bytes(context, "/other.css", "text/css", "body{}")
    expect_bytes(context, "/app.js", "text/javascript; charset=utf-8", ~s|import "./dep.js";|)
    expect_bytes(context, "/dep.js", "text/javascript", "dep")

    expect_bytes(
      context,
      "/page.xhtml",
      "application/xhtml+xml",
      ~s|<a href="/next">Next</a>|
    )

    expect_html(context, "/next", "next")

    {opts, root} = run(page, context, assets: ["css", "js"])

    assert read_resource(root, reference_target(root, resource_for_url(root, page), readme)) ==
             @plain

    refute Store.find({context.url <> "/secret", opts.scope})
    assert Store.find_processed({context.url <> "/other.css", opts.scope})
    assert Store.find_processed({context.url <> "/dep.js", opts.scope})

    assert %Store.Page{processed: true, body: "next"} =
             Store.find_processed({context.url <> "/next", opts.scope})

    xhtml = reference_target(root, resource_for_url(root, page), context.url <> "/page.xhtml")
    next = reference_target(root, xhtml, context.url <> "/next")
    assert read_resource(root, next) == <<0xEF, 0xBB, 0xBF>> <> "next"
  end

  defp run(page, context, extra) do
    scope = unique_scope("document-reader")
    root = Path.join(tmp(), scope <> "-#{Base.encode16(:crypto.strong_rand_bytes(6))}")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, opts} =
      start_crawl(
        page,
        Keyword.merge(
          [
            scope: scope,
            workers: 1,
            max_body: 1_048_576,
            max_analysis_bytes: 16_000_000,
            max_css_work: 5_000,
            max_css_pictures: 1_000,
            max_manifest_bytes: 16_777_216,
            retries: 0,
            max_depths: 3,
            store: Store,
            save_to: root,
            req_options: context.req_options
          ],
          extra
        )
      )

    on_exit(fn -> Crawler.stop(opts) end)
    {opts, ready_export(opts)}
  end

  defp expect_html(context, path, body) do
    ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
      conn
      |> put_resp_header("content-type", "text/html")
      |> resp(200, body)
    end)
  end

  defp expect_bytes(context, path, type, body) do
    ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
      conn
      |> put_resp_header("content-type", type)
      |> resp(200, body)
    end)
  end
end
