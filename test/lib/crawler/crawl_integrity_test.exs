defmodule Crawler.CrawlIntegrityTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  test "rewritten scripts and styles open saved bytes without their original integrity hashes", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("offline-integrity")
    root = Path.join(tmp(), scope <> "-#{Base.encode16(:crypto.strong_rand_bytes(6))}")
    on_exit(fn -> File.rm_rf(root) end)
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
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
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

    export = ready_export(opts)
    source = resource_for_url(export, page)
    script_resource = edge_target(export, source, 0)
    preload_resource = edge_target(export, source, 1)
    stylesheet_resource = edge_target(export, source, 2)
    assert script_resource["url"] == script
    assert preload_resource["url"] == script
    assert stylesheet_resource["url"] == stylesheet
    saved_js = read_resource(export, script_resource)
    saved_css = read_resource(export, stylesheet_resource)
    refute saved_js == script_source
    refute saved_css == css_source
    refute integrity(:sha256, saved_js) == script_integrity
    refute integrity(:sha384, saved_css) == css_integrity
    saved_page = read_resource(export, source)
    refute saved_page =~ "integrity="
    {:ok, document} = Floki.parse_document(saved_page)
    [script_href] = Floki.attribute(document, "script", "src")
    [preload_href] = Floki.attribute(document, "link[rel=modulepreload]", "href")
    [stylesheet_href] = Floki.attribute(document, "link[rel=stylesheet]", "href")
    assert_opens(export, source, script_resource, script_href)
    assert_opens(export, source, preload_resource, preload_href)
    assert_opens(export, source, stylesheet_resource, stylesheet_href)

    for resource <- Enum.uniq([script_resource, preload_resource]) do
      target = reference_target(export, resource, dependency)
      [_, href] = Regex.run(~r/import "([^"]+)";/, read_resource(export, resource))
      assert_opens(export, resource, target, href)
      assert read_resource(export, target) == "export const value = 1;"
    end

    target = reference_target(export, stylesheet_resource, image)
    [_, href] = Regex.run(~r/url\("([^"]+)"\)/, saved_css)
    assert_opens(export, stylesheet_resource, target, href)
    assert read_resource(export, target) == "image bytes"
  end

  defp integrity(algorithm, body) do
    Atom.to_string(algorithm) <> "-" <> Base.encode64(:crypto.hash(algorithm, body))
  end
end
