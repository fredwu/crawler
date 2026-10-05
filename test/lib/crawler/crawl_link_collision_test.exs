defmodule Crawler.CrawlLinkCollisionTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.Store

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "overlapping original and offline links open their distinct saved bodies", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("link-collision")
    root = tmp(scope)
    page = "#{url}/index.html"
    relative = "../#{site.path}/foo.html"
    relative_target = "#{url}/#{site.path}/foo.html"
    absolute_target = "#{url}/foo.html"

    assert Crawler.Linker.offline_link(page, absolute_target) == relative

    ReqTestSite.expect_once(site, "GET", "/index.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, """
      <a href="#{relative}">relative</a>
      <a href="#{absolute_target}">absolute</a>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/#{site.path}/foo.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "relative body")
    end)

    ReqTestSite.expect_once(site, "GET", "/foo.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "absolute body")
    end)

    {:ok, opts} =
      start_crawl(page,
        scope: scope,
        workers: 2,
        retries: 0,
        store: Store,
        save_to: root,
        req_options: req_options
      )

    on_exit(fn -> Crawler.stop(opts) end)

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({relative_target, scope})
      assert Store.find_processed({absolute_target, scope})
    end)

    assert File.read!(saved(root, relative_target)) == @utf8_bom <> "relative body"
    assert File.read!(saved(root, absolute_target)) == @utf8_bom <> "absolute body"
    assert_link_opens(root, page, relative_target)
    assert_link_opens(root, page, absolute_target)
  end
end
