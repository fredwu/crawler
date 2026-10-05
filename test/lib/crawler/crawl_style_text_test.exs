defmodule Crawler.CrawlStyleTextTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.RequestLog
  alias Crawler.Store

  test "raw style queries and decoded attribute queries fetch their own files", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("style-text")
    root = tmp(scope)
    page = "#{url}/style-page"
    raw_target = "#{url}/assets/asset.png?x=1&amp;y=2"
    attribute_target = "#{url}/assets/asset.png?x=1&y=2"
    requests = RequestLog.new()

    ReqTestSite.expect_once(site, "GET", "/style-page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, """
      <base href="/assets/">
      <style>.raw { background: url("asset.png?x=1&amp;y=2") }</style>
      <div style="background:url(&quot;asset.png?x=1&amp;y=2&quot;)"></div>
      """)
    end)

    ReqTestSite.expect(site, "GET", "/assets/asset.png", fn conn ->
      RequestLog.record(requests, conn.query_string)

      body =
        case conn.query_string do
          "x=1&amp;y=2" -> "raw style asset"
          "x=1&y=2" -> "attribute style asset"
        end

      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.resp(200, body)
    end)

    {:ok, opts} =
      start_crawl(page,
        scope: scope,
        workers: 2,
        retries: 0,
        store: Store,
        save_to: root,
        assets: ["css", "images"],
        req_options: req_options
      )

    on_exit(fn -> Crawler.stop(opts) end)

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({raw_target, scope})
      assert Store.find_processed({attribute_target, scope})
    end)

    assert RequestLog.frequencies(requests) == %{"x=1&amp;y=2" => 1, "x=1&y=2" => 1}
    assert File.read!(saved(root, raw_target)) == "raw style asset"
    assert File.read!(saved(root, attribute_target)) == "attribute style asset"
    assert_link_opens(root, page, raw_target)
    assert_link_opens(root, page, attribute_target)
  end
end
