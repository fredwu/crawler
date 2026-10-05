defmodule Crawler.CrawlHTMLReferencePolicyTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.Store

  test "CSS role still fetches a repeated navigation URL at the depth boundary", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("html-reference-depth")
    root = tmp(scope)
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

    assert File.read!(saved(root, asset)) == "IMAGE"
    assert_link_opens(root, page, asset)
    target = Crawler.Linker.offline_link(page, asset)

    assert File.read!(saved(root, page)) ==
             <<0xEF, 0xBB, 0xBF>> <>
               ~s|<a href="#{target}" style="background:url(#{target})">A</a>| <>
               ~s|<a href="#{target}">B</a><a href="#{target}">C</a>|
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
