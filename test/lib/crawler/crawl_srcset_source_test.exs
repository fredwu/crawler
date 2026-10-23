defmodule Crawler.CrawlSrcsetSourceTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  test "encoded srcset boundaries fetch both candidates and retain the base target offline", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("srcset-source")
    root = Path.join(tmp(), scope <> "-#{Base.encode16(:crypto.strong_rand_bytes(6))}")
    on_exit(fn -> File.rm_rf(root) end)
    page = url <> "/index.html"

    source =
      ~s|<base href="/docs/" target="_blank">| <>
        ~s|<img srcset="a.png&#32;1x&#44;&#x20;b.png&#x09;2x">| <>
        ~s|<link rel="preload" as="image" imagesrcset="a.png&#32;1x&#44;&#x20;b.png&#x09;2x">|

    ReqTestSite.expect_once(site, "GET", "/index.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, source)
    end)

    for name <- ["a", "b"] do
      ReqTestSite.expect_once(site, "GET", "/docs/#{name}.png", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "image/png")
        |> Plug.Conn.resp(200, "IMAGE #{name}")
      end)
    end

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

    [image_a, image_b, preload_a, preload_b] =
      for index <- 0..3, do: edge_target(export, source_resource, index)

    a = relative_reference(source_resource, image_a)
    b = relative_reference(source_resource, image_b)
    preload_a_href = relative_reference(source_resource, preload_a)
    preload_b_href = relative_reference(source_resource, preload_b)

    expected =
      ~s|<base target="_blank">| <>
        ~s|<img srcset="#{a}&#32;1x&#44;&#x20;#{b}&#x09;2x">| <>
        ~s|<link rel="preload" as="image" imagesrcset="#{preload_a_href}&#32;1x&#44;&#x20;#{preload_b_href}&#x09;2x">|

    assert read_resource(export, source_resource) == <<0xEF, 0xBB, 0xBF>> <> expected

    for {target, href, name} <- [
          {image_a, a, "a"},
          {image_b, b, "b"},
          {preload_a, preload_a_href, "a"},
          {preload_b, preload_b_href, "b"}
        ] do
      assert target["url"] == url <> "/docs/#{name}.png"
      assert Store.find_processed({target["url"], scope})
      assert read_resource(export, target) == "IMAGE #{name}"
      assert_opens(export, source_resource, target, href)
    end
  end
end
