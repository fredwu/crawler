defmodule Crawler.CrawlLinkCollisionTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "overlapping original and offline links open their distinct saved bodies", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("link-collision")
    root = Path.join(tmp(scope), "archive")
    page = "#{url}/index.html"
    relative = "../#{site.path}/foo.html"
    relative_target = "#{url}/#{site.path}/foo.html"
    absolute_target = "#{url}/foo.html"

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
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        retries: 0,
        store: Store,
        save_to: root,
        req_options: req_options
      )

    on_exit(fn -> Crawler.stop(opts) end)

    export = ready_export(opts)
    assert Store.find_processed({relative_target, scope})
    assert Store.find_processed({absolute_target, scope})

    source = resource_for_url(export, page)

    assert [relative_href, absolute_href] =
             Floki.attribute(Floki.parse_document!(read_resource(export, source)), "a", "href")

    first = edge_target(export, source, 0)
    second = edge_target(export, source, 1)
    refute first["id"] == second["id"]
    assert_opens(export, source, first, relative_href)
    assert_opens(export, source, second, absolute_href)
    assert read_resource(export, first) == @utf8_bom <> "relative body"
    assert read_resource(export, second) == @utf8_bom <> "absolute body"
  end
end
