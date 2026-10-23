defmodule Crawler.CrawlStyleTextTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.RequestLog
  alias Crawler.Store

  test "raw style queries and decoded attribute queries fetch their own files", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("style-text")
    root = tmp(scope, "archive")
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

    export = ready_export(opts)
    source = resource_for_url(export, page)

    assert RequestLog.frequencies(requests) == %{"x=1&amp;y=2" => 1, "x=1&y=2" => 1}

    assert read_resource(export, reference_target(export, source, raw_target)) ==
             "raw style asset"

    assert read_resource(export, reference_target(export, source, attribute_target)) ==
             "attribute style asset"

    body = read_resource(export, source)

    assert [raw_reference] =
             Regex.run(~r/<style>.*?url\("([^"]+)"\)/s, body, capture: :all_but_first)

    assert [attribute_reference] =
             Regex.run(~r/<div style="background:url\(&quot;([^&]+)&quot;\)"/, body,
               capture: :all_but_first
             )

    assert_opens(export, source, reference_target(export, source, raw_target), raw_reference)

    assert_opens(
      export,
      source,
      reference_target(export, source, attribute_target),
      attribute_reference
    )
  end
end
