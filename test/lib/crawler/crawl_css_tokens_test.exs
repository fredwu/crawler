defmodule Crawler.CrawlCssTokensTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.Store

  test "CSS hash payloads stay literal while real URL functions fetch and open their assets", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("css-hash-context")
    root = tmp(scope)
    page = "#{url}/css-hash-page"
    css = "#{url}/assets/hash.css"
    image = "#{url}/assets/real.png"

    opaque =
      ~S|.x{--same:#url(real.png);--opaque:#url(hidden.png);--escaped:#\75rl(escaped.png);--set:#image-set("hidden-set.png" 1x);}|

    stylesheet = opaque <> ~S|.live{background:u\72l(real.png)}|

    ReqTestSite.expect_once(site, "GET", "/css-hash-page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, ~s|<link rel="stylesheet" href="/assets/hash.css">|)
    end)

    ReqTestSite.expect_once(site, "GET", "/assets/hash.css", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/css")
      |> Plug.Conn.resp(200, stylesheet)
    end)

    ReqTestSite.expect_once(site, "GET", "/assets/real.png", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.resp(200, "IMAGE /assets/real.png")
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
      assert Store.find_processed({css, scope})
      assert Store.find_processed({image, scope})
    end)

    assert File.read!(saved(root, css)) ==
             opaque <> ~s|.live{background:u\\72l(#{Crawler.Linker.offline_link(css, image)})}|

    assert_link_opens(root, page, css)
    assert_link_opens(root, css, image)
    assert File.read!(saved(root, image)) == "IMAGE /assets/real.png"

    for name <- ["hidden.png", "escaped.png", "hidden-set.png"] do
      refute Store.find({"#{url}/assets/#{name}", scope})
      refute File.exists?(saved(root, "#{url}/assets/#{name}"))
    end
  end

  test "CSS URL comment-looking payloads fetch their full path and bad URL targets stay unfetched",
       %{
         site: site,
         url: url,
         req_options: req_options
       } do
    scope = unique_scope("css-url-comments")
    root = tmp(scope)
    page = "#{url}/css-comment-page"
    css = "#{url}/assets/comments.css"
    comment_image = "#{url}/*draft*/image.png"
    image = "#{url}/assets/real.png"

    invalid =
      ~s|url(/*draft*/"quoted.png"),url(spaced.png /**/),url(/**/'single.png')|

    stylesheet =
      ~s|.x{background:url( /*draft*/image.png ),url("real.png"/* after */),#{invalid}}|

    ReqTestSite.expect_once(site, "GET", "/css-comment-page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, ~s|<link rel="stylesheet" href="/assets/comments.css">|)
    end)

    ReqTestSite.expect_once(site, "GET", "/assets/comments.css", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/css")
      |> Plug.Conn.resp(200, stylesheet)
    end)

    for path <- ["/*draft*/image.png", "/assets/real.png"] do
      ReqTestSite.expect_once(site, "GET", path, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "image/png")
        |> Plug.Conn.resp(200, "IMAGE #{path}")
      end)
    end

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
      assert Store.find_processed({css, scope})
      assert Store.find_processed({image, scope})
      assert Store.find_processed({comment_image, scope})
    end)

    assert File.read!(saved(root, css)) ==
             ~s|.x{background:url( #{Crawler.Linker.offline_link(css, comment_image)} ),url("#{Crawler.Linker.offline_link(css, image)}"/* after */),#{invalid}}|

    assert_link_opens(root, page, css)
    assert_link_opens(root, css, image)
    assert_link_opens(root, css, comment_image)
    assert File.read!(saved(root, comment_image)) == "IMAGE /*draft*/image.png"

    for name <- ["image.png", "quoted.png", "spaced.png", "single.png"] do
      refute Store.find({"#{url}/assets/#{name}", scope})
      refute File.exists?(saved(root, "#{url}/assets/#{name}"))
    end
  end

  test "CSS literals stay unchanged and escaped URL values open the asset that was fetched", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("css-token-context")
    root = tmp(scope)
    page = "#{url}/css-token-page"
    css = "#{url}/assets/app.css"
    escaped_image = "#{url}/assets/foo)bar.png"
    image = "#{url}/assets/real.png"

    literal =
      ~S|.label{content:"url(real.png) url(hidden.png) @import 'hidden.css'; image-set('hidden-set.png' 1x)"}|

    stylesheet = literal <> ~S|.live{background:url(real.png),url(foo\)bar.png)}|

    ReqTestSite.expect_once(site, "GET", "/css-token-page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, ~s|<link rel="stylesheet" href="/assets/app.css">|)
    end)

    ReqTestSite.expect_once(site, "GET", "/assets/app.css", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/css")
      |> Plug.Conn.resp(200, stylesheet)
    end)

    for path <- ["/assets/real.png", "/assets/foo)bar.png"] do
      ReqTestSite.expect_once(site, "GET", path, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "image/png")
        |> Plug.Conn.resp(200, "IMAGE #{path}")
      end)
    end

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
      assert Store.find_processed({css, scope})
      assert Store.find_processed({image, scope})
      assert Store.find_processed({escaped_image, scope})
    end)

    assert File.read!(saved(root, css)) =~ literal
    assert_link_opens(root, page, css)
    assert_link_opens(root, css, image)
    assert_link_opens(root, css, escaped_image)
    assert File.read!(saved(root, escaped_image)) == "IMAGE /assets/foo)bar.png"

    for name <- ["hidden.png", "hidden.css", "hidden-set.png"] do
      refute Store.find({"#{url}/assets/#{name}", scope})
      refute File.exists?(saved(root, "#{url}/assets/#{name}"))
    end
  end
end
