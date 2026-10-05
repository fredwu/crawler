defmodule Crawler.CrawlSVGHrefSelectionTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.Linker
  alias Crawler.Store

  test "SVG href authority prevents fallback requests and preserves saved source", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("svg-href-selection")
    root = tmp(scope)
    page = url <> "/index.html"

    source =
      "<svg>" <>
        ~s|<a xlink:href="ignored.svg" href="shared.svg"/>| <>
        ~s|<image href="shared.svg" xlink:href="ignored.svg"/>| <>
        ~s|<use xlink:href="shared.svg"/>| <>
        ~s|<a href="" xlink:href="ignored.svg"/>| <>
        ~s|<image href="" href="ignored.svg" xlink:href="ignored.svg"/>| <>
        ~s|<use href="" xlink:href="ignored.svg"/>| <>
        "</svg>"

    on_exit(fn -> File.rm_rf(root) end)

    ReqTestSite.expect_once(site, "GET", "/index.html", fn conn ->
      Plug.Conn.resp(conn, 200, source)
    end)

    ReqTestSite.expect_once(site, "GET", "/shared.svg", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/svg+xml")
      |> Plug.Conn.resp(200, "<svg/>")
    end)

    {:ok, opts} =
      start_crawl(page,
        scope: scope,
        workers: 2,
        retries: 0,
        max_depths: 2,
        assets: ["images"],
        store: Store,
        save_to: root,
        req_options: req_options
      )

    wait(2_000, fn -> refute Crawler.running?(opts) end)
    shared = url <> "/shared.svg"
    target = Linker.offline_link(page, shared)

    expected =
      "<svg>" <>
        ~s|<a xlink:href="ignored.svg" href="#{target}"/>| <>
        ~s|<image href="#{target}" xlink:href="ignored.svg"/>| <>
        ~s|<use xlink:href="#{target}"/>| <>
        ~s|<a href="" xlink:href="ignored.svg"/>| <>
        ~s|<image href="" href="ignored.svg" xlink:href="ignored.svg"/>| <>
        ~s|<use href="" xlink:href="ignored.svg"/>| <>
        "</svg>"

    assert File.read!(saved(root, page)) == <<0xEF, 0xBB, 0xBF>> <> expected
    refute Store.find({url <> "/ignored.svg", scope})
    assert Store.find_processed({shared, scope})
    assert_link_opens(root, page, shared)
  end
end
