defmodule Crawler.CrawlHTMLAttributeEligibilityTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.Linker
  alias Crawler.Store

  test "fetches active image candidates once and preserves ignored matching attributes offline",
       %{
         site: site,
         url: url,
         req_options: req_options
       } do
    scope = unique_scope("html-attribute-eligibility")
    root = tmp(scope)
    page = url <> "/index.html"

    ignored =
      ~s|<img imagesrcset="shared.png 1x, ignored.png 2x">| <>
        ~s|<source imagesrcset="shared.png 1x, ignored.png 2x">| <>
        ~s|<link imagesrcset="shared.png 1x, ignored.png 2x">| <>
        ~s|<link rel="preload" as=" image " href="ignored.png" imagesrcset="shared.png 1x">| <>
        ~s|<link rel="&#160;preload&#160;" as="image" href="ignored.png" imagesrcset="shared.png 1x">| <>
        ~s|<meta http-equiv=" refresh " content="0; next.html">|

    source =
      ignored <>
        ~s|<img src="shared.png" srcset="shared.png 1x">| <>
        ~s|<source srcset="shared.png 1x">| <>
        ~s|<link rel="alternate&#9;PRELOAD" as="IM&#65;GE" imagesrcset="shared.png&#32;1x">| <>
        ~s|<meta http-equiv="ReFrEsH" content="0; next.html">|

    on_exit(fn -> File.rm_rf(root) end)

    ReqTestSite.expect_once(site, "GET", "/index.html", fn conn ->
      Plug.Conn.resp(conn, 200, source)
    end)

    ReqTestSite.expect_once(site, "GET", "/shared.png", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.resp(200, "IMAGE")
    end)

    ReqTestSite.expect_once(site, "GET", "/next.html", fn conn ->
      Plug.Conn.resp(conn, 200, "NEXT")
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
    image = Linker.offline_link(page, url <> "/shared.png")
    next = Linker.offline_link(page, url <> "/next.html")

    expected =
      ignored <>
        ~s|<img src="#{image}" srcset="#{image} 1x">| <>
        ~s|<source srcset="#{image} 1x">| <>
        ~s|<link rel="alternate&#9;PRELOAD" as="IM&#65;GE" imagesrcset="#{image}&#32;1x">| <>
        ~s|<meta http-equiv="ReFrEsH" content="0; #{next}">|

    assert File.read!(saved(root, page)) == <<0xEF, 0xBB, 0xBF>> <> expected
    refute Store.find_processed({url <> "/ignored.png", scope})

    for path <- ["shared.png", "next.html"] do
      target = url <> "/" <> path
      assert Store.find_processed({target, scope})
      assert_link_opens(root, page, target)
    end

    assert File.read!(saved(root, url <> "/shared.png")) == "IMAGE"
  end
end
