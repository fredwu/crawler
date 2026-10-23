defmodule Crawler.CrawlSrcsetTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  test "data-first srcset and imagesrcset candidates open their saved files", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("data-first-srcset")
    root = Path.join(tmp(), scope <> "-#{Base.encode16(:crypto.strong_rand_bytes(6))}")
    on_exit(fn -> File.rm_rf(root) end)
    page = "#{url}/srcset-page"
    image = "#{url}/image.png"
    preload = "#{url}/preload.png"
    data = "data:image/png;base64,YQ=="

    ReqTestSite.expect_once(site, "GET", "/srcset-page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, """
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
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        retries: 0,
        store: Store,
        save_to: root,
        assets: ["images"],
        req_options: req_options
      )

    on_exit(fn -> Crawler.stop(opts) end)

    export = ready_export(opts)

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({image, scope})
      assert Store.find_processed({preload, scope})
    end)

    source = resource_for_url(export, page)
    image_resource = reference_target(export, source, image)
    preload_resource = reference_target(export, source, preload)
    image_href = relative_reference(source, image_resource)
    preload_href = relative_reference(source, preload_resource)

    assert read_resource(export, image_resource) == "image candidate"
    assert read_resource(export, preload_resource) == "preload candidate"

    assert read_resource(export, source) ==
             <<0xEF, 0xBB, 0xBF>> <>
               """
               <img srcset="#{data} 1x, #{image_href} 2x">
               <link rel="preload" as="image" imagesrcset="#{data} 1x, #{preload_href} 2x">
               """

    assert_opens(export, source, image_resource, image_href)
    assert_opens(export, source, preload_resource, preload_href)
  end
end
