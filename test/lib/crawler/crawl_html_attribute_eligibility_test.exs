defmodule Crawler.CrawlHTMLAttributeEligibilityTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  test "fetches active image candidates once and preserves ignored matching attributes offline",
       %{
         site: site,
         url: url,
         req_options: req_options
       } do
    scope = unique_scope("html-attribute-eligibility")
    root = Path.join(tmp(), scope <> "-#{Base.encode16(:crypto.strong_rand_bytes(6))}")
    on_exit(fn -> File.rm_rf(root) end)
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

    ReqTestSite.expect_once(site, "GET", "/index.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, source)
    end)

    ReqTestSite.expect_once(site, "GET", "/shared.png", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.resp(200, "IMAGE")
    end)

    ReqTestSite.expect_once(site, "GET", "/next.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "NEXT")
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
        max_depths: 2,
        assets: ["images"],
        store: Store,
        save_to: root,
        req_options: req_options
      )

    export = ready_export(opts)
    source_resource = resource_for_url(export, page)

    [image, candidate, source_candidate, preload, next] =
      for index <- 0..4, do: edge_target(export, source_resource, index)

    image_href = relative_reference(source_resource, image)
    candidate_href = relative_reference(source_resource, candidate)
    source_href = relative_reference(source_resource, source_candidate)
    preload_href = relative_reference(source_resource, preload)
    next_href = relative_reference(source_resource, next)

    expected =
      ignored <>
        ~s|<img src="#{image_href}" srcset="#{candidate_href} 1x">| <>
        ~s|<source srcset="#{source_href} 1x">| <>
        ~s|<link rel="alternate&#9;PRELOAD" as="IM&#65;GE" imagesrcset="#{preload_href}&#32;1x">| <>
        ~s|<meta http-equiv="ReFrEsH" content="0; #{next_href}">|

    assert read_resource(export, source_resource) == <<0xEF, 0xBB, 0xBF>> <> expected
    refute Store.find_processed({url <> "/ignored.png", scope})

    for {target, href} <- [
          {image, image_href},
          {candidate, candidate_href},
          {source_candidate, source_href},
          {preload, preload_href}
        ] do
      assert target["url"] == url <> "/shared.png"
      assert Store.find_processed({target["url"], scope})
      assert read_resource(export, target) == "IMAGE"
      assert_opens(export, source_resource, target, href)
    end

    assert next["url"] == url <> "/next.html"
    assert Store.find_processed({next["url"], scope})
    assert read_resource(export, next) == <<0xEF, 0xBB, 0xBF>> <> "NEXT"
    assert_opens(export, source_resource, next, next_href)
  end
end
