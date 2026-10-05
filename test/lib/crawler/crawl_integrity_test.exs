defmodule Crawler.CrawlIntegrityTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.Store

  test "rewritten scripts and styles open saved bytes without their original integrity hashes", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("offline-integrity")
    root = tmp(scope)
    page = "#{url}/index.html"
    script = "#{url}/app.js"
    dependency = "#{url}/chunk.js"
    stylesheet = "#{url}/app.css"
    image = "#{url}/image.png"
    script_source = ~s|import "./chunk.js";|
    css_source = ~s|.x{background:url("image.png")}|
    script_integrity = integrity(:sha256, script_source)
    css_integrity = integrity(:sha384, css_source)

    ReqTestSite.expect_once(site, "GET", "/index.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, """
      <script type="module" src="app.js" integrity="#{script_integrity}"></script>
      <link rel="modulepreload" href="app.js" integrity="#{script_integrity}">
      <link rel="stylesheet" href="app.css" integrity="#{css_integrity}">
      """)
    end)

    for {path, content_type, body} <- [
          {"/app.js", "application/javascript", script_source},
          {"/chunk.js", "application/javascript", "export const value = 1;"},
          {"/app.css", "text/css", css_source},
          {"/image.png", "image/png", "image bytes"}
        ] do
      ReqTestSite.expect_once(site, "GET", path, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", content_type)
        |> Plug.Conn.resp(200, body)
      end)
    end

    {:ok, opts} =
      start_crawl(page,
        scope: scope,
        workers: 2,
        retries: 0,
        store: Store,
        save_to: root,
        assets: ["css", "js", "images"],
        req_options: req_options
      )

    on_exit(fn -> Crawler.stop(opts) end)

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({dependency, scope})
      assert Store.find_processed({image, scope})
    end)

    saved_js = File.read!(saved(root, script))
    saved_css = File.read!(saved(root, stylesheet))
    refute saved_js == script_source
    refute saved_css == css_source
    refute integrity(:sha256, saved_js) == script_integrity
    refute integrity(:sha384, saved_css) == css_integrity
    refute File.read!(saved(root, page)) =~ "integrity="

    assert_link_opens(root, page, script)
    assert_link_opens(root, page, stylesheet)
    assert_link_opens(root, script, dependency)
    assert_link_opens(root, stylesheet, image)
  end

  defp integrity(algorithm, body) do
    Atom.to_string(algorithm) <> "-" <> Base.encode64(:crypto.hash(algorithm, body))
  end
end
