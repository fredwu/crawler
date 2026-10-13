defmodule Crawler.CrawlDocumentScopeTest do
  use Crawler.TestCase, async: false

  import Plug.Conn
  import Crawler.SnapshotHelpers

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
    root = tmp(scope)

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

    saved = File.read!(saved(root, page))
    assert saved =~ ~s|src="/frame.html"|
    assert saved =~ "inert.html"
    assert saved =~ "plain-style.png"
    refute saved =~ ~s|href="live.html"|
    refute saved =~ "url(paint.png)"

    assert File.read!(saved(root, context.url <> "/images/picture.svg")) == @picture
    refute File.read!(saved(root, context.url <> "/diagram.svg")) =~ ~s|href="theme.css"|
    refute Crawler.running?(opts)
  end

  defp crawl(page, context, root, scope, assets) do
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, opts} =
      start_crawl(page,
        scope: scope,
        workers: 1,
        retries: 0,
        max_depths: 3,
        assets: assets,
        store: Store,
        save_to: root,
        req_options: context.req_options
      )

    on_exit(fn -> Crawler.stop(opts) end)
    wait(5_000, fn -> refute Crawler.running?(opts) end)
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
