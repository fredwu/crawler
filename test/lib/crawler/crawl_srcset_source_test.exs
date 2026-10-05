defmodule Crawler.CrawlSrcsetSourceTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.Linker
  alias Crawler.Store

  test "encoded srcset boundaries fetch both candidates and retain the base target offline", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("srcset-source")
    root = tmp(scope)
    page = url <> "/index.html"

    source =
      ~s|<base href="/docs/" target="_blank">| <>
        ~s|<img srcset="a.png&#32;1x&#44;&#x20;b.png&#x09;2x">| <>
        ~s|<link rel="preload" as="image" imagesrcset="a.png&#32;1x&#44;&#x20;b.png&#x09;2x">|

    on_exit(fn -> File.rm_rf(root) end)

    ReqTestSite.expect_once(site, "GET", "/index.html", fn conn ->
      Plug.Conn.resp(conn, 200, source)
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
        retries: 0,
        max_depths: 2,
        assets: ["images"],
        store: Store,
        save_to: root,
        req_options: req_options
      )

    wait(2_000, fn -> refute Crawler.running?(opts) end)
    a = Linker.offline_link(page, url <> "/docs/a.png")
    b = Linker.offline_link(page, url <> "/docs/b.png")

    expected =
      ~s|<base target="_blank">| <>
        ~s|<img srcset="#{a}&#32;1x&#44;&#x20;#{b}&#x09;2x">| <>
        ~s|<link rel="preload" as="image" imagesrcset="#{a}&#32;1x&#44;&#x20;#{b}&#x09;2x">|

    assert File.read!(saved(root, page)) == <<0xEF, 0xBB, 0xBF>> <> expected

    for name <- ["a", "b"] do
      target = url <> "/docs/#{name}.png"
      assert Store.find_processed({target, scope})
      assert File.read!(saved(root, target)) == "IMAGE #{name}"
      assert_link_opens(root, page, target)
    end
  end
end
