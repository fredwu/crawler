defmodule Crawler.CrawlSrcsetTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.Store

  test "data-first srcset and imagesrcset candidates open their saved files", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("data-first-srcset")
    root = tmp(scope)
    page = "#{url}/srcset-page"
    image = "#{url}/image.png"
    preload = "#{url}/preload.png"
    data = "data:image/png;base64,YQ=="

    ReqTestSite.expect_once(site, "GET", "/srcset-page", fn conn ->
      Plug.Conn.resp(conn, 200, """
      <img srcset="#{data} 1x, image.png 2x">
      <link rel="preload" as="image" imagesrcset="#{data} 1x, preload.png 2x">
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/image.png", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.resp(200, "image candidate")
    end)

    ReqTestSite.expect_once(site, "GET", "/preload.png", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.resp(200, "preload candidate")
    end)

    {:ok, opts} =
      start_crawl(page,
        scope: scope,
        workers: 2,
        retries: 0,
        store: Store,
        save_to: root,
        assets: ["images"],
        req_options: req_options
      )

    on_exit(fn -> Crawler.stop(opts) end)

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({image, scope})
      assert Store.find_processed({preload, scope})
    end)

    assert File.read!(saved(root, image)) == "image candidate"
    assert File.read!(saved(root, preload)) == "preload candidate"
    assert File.read!(saved(root, page)) =~ data <> " 1x"
    assert_link_opens(root, page, image)
    assert_link_opens(root, page, preload)
  end
end
