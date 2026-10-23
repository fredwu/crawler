defmodule Crawler.CrawlHTMLReferencePolicyTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  test "CSS role still fetches a repeated navigation URL at the depth boundary", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("html-reference-depth")
    root = Path.join(tmp(), scope <> "-#{Base.encode16(:crypto.strong_rand_bytes(6))}")
    on_exit(fn -> File.rm_rf(root) end)
    page = url <> "/page"
    asset = url <> "/asset.png"

    source =
      ~s|<a href="asset.png" style="background:url(asset.png)">A</a>| <>
        ~s|<a href="asset.png">B</a><a href="./asset.png">C</a>|

    ReqTestSite.expect_once(site, "GET", "/page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, source)
    end)

    ReqTestSite.expect_once(site, "GET", "/asset.png", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.resp(200, "IMAGE")
    end)

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
        max_depths: 1,
        assets: ["css"],
        req_options: req_options
      )

    on_exit(fn -> Crawler.stop(opts) end)

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({asset, scope})
    end)

    export = ready_export(opts)
    source_resource = resource_for_url(export, page)
    image = edge_target(export, source_resource, 1)
    assert read_resource(export, image) == "IMAGE"
    target = relative_reference(source_resource, image)
    assert_opens(export, source_resource, image, target)

    assert read_resource(export, source_resource) ==
             <<0xEF, 0xBB, 0xBF>> <>
               ~s|<a href="#{asset}" style="background:url(#{target})">A</a>| <>
               ~s|<a href="#{asset}">B</a><a href="#{asset}">C</a>|
  end

  test "browser ignored script sources do not make requests", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("html-script-source")
    page = url <> "/page"

    source =
      ~s|<script type="application/ld+json" src="ignored.json">import './ignored.js';</script>| <>
        ~s|<script type="module" src="app.js">import './ignored.js';</script>|

    ReqTestSite.expect_once(site, "GET", "/page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, source)
    end)

    ReqTestSite.expect_once(site, "GET", "/app.js", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/javascript")
      |> Plug.Conn.resp(200, "export {};")
    end)

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
        assets: ["js"],
        req_options: req_options
      )

    on_exit(fn -> Crawler.stop(opts) end)

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({url <> "/app.js", scope})
    end)

    refute Store.find({url <> "/ignored.json", scope})
    refute Store.find({url <> "/ignored.js", scope})
  end
end
