defmodule Crawler.CrawlDiscoveryTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.Store

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "discovers ordinary links and assets once", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    host = "#{site.host}:#{site.port}"

    ReqTestSite.expect_once(site, "GET", "/behavior/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "#{url}/behavior/dir/page")
      |> Plug.Conn.resp(302, "")
    end)

    body = """
    <html>
      <head>
        <base href="#{url}/behavior/other/">
        <script src="/behavior/app.js"></script>
        <script type="module" src="/behavior/mod.js"></script>
        <script src="//#{host}/behavior/lib.js"></script>
      </head>
      <a href="next">next</a>
      <a href="#{url}/behavior/dir/page#a">a</a>
      <a href="#{url}/behavior/dir/page#b">b</a>
      <a href="mailto:a@b.c">mail</a>
      <a href="javascript:void(0)">js</a>
      <a href="/behavior/search?q=1">search</a>
    </html>
    """

    ReqTestSite.expect_once(site, "GET", "/behavior/dir/page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, body)
    end)

    for path <- [
          "/behavior/other/next",
          "/behavior/app.js",
          "/behavior/mod.js",
          "/behavior/lib.js",
          "/behavior/search"
        ] do
      ReqTestSite.expect_once(site, "GET", path, fn conn ->
        Plug.Conn.resp(conn, 200, path)
      end)
    end

    {:ok, opts} =
      start_crawl("#{url}/behavior/old",
        scope: "links",
        assets: ["js"],
        max_depths: 2,
        workers: 2,
        save_to: tmp("behavior-links"),
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.ops_count("links") == 6
      root = tmp("behavior-links")
      page = "#{url}/behavior/old"
      search = "#{url}/behavior/search?q=1"
      assert File.read!(saved(root, page)) =~ "__q_q%3D1.html"
      assert_link_opens(root, page, search)
      assert File.read!(saved(root, search)) == @utf8_bom <> "/behavior/search"
    end)
  end

  test "a redirect fragment does not fetch the landing page again", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    page = "#{url}/behavior/frag/page"

    ReqTestSite.expect_once(site, "GET", "/behavior/frag/from", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "#{page}#a")
      |> Plug.Conn.resp(302, "")
    end)

    ReqTestSite.expect_once(site, "GET", "/behavior/frag/page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, ~s(<a href="#{page}#b">b</a>))
    end)

    {:ok, opts} =
      start_crawl("#{url}/behavior/frag/from",
        scope: "frag",
        store: Store,
        workers: 2,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)

      assert %Store.Page{body: body} = Store.find_processed({page, "frag"})
      assert body =~ "#{page}#b"
      assert Store.ops_count("frag") == 1
      assert Store.find({"#{page}#a", "frag"}).body == body
      assert Store.find({"#{page}#b", "frag"}).body == body
    end)
  end

  test "fetches media and style links and stores distinct offline files", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    sheet = """
    @import "other.css";
    @import url("nested.css");
    body { background: url( "spaced.png" ); }
    @font-face { src: url( 'font.woff2' ); }
    """

    entry = """
    <html>
      <img src="a.jpg" srcset="a.jpg 1x, b.jpg 2x">
      <picture><source srcset="c.webp" type="image/webp"><img src="c.jpg"></picture>
      <video src="d.mp4" poster="d.jpg"></video>
      <audio src="e.mp3"></audio>
      <link rel="preload" as="style" href="pre.css">
      <link rel="stylesheet alternate" href="alt.css">
      <link rel="stylesheet" href="sheet.css">
      <style>body { background: url(bg.png); }</style>
      <div style="background: url('bg2.png')"></div>
      <a href="/archive/search?q=1&amp;x=2">one</a>
      <a href="/archive/search?q=2">two</a>
      <a href="/archive/bare">bare</a>
      <a href="/archive/bare/index.html">index</a>
    </html>
    """

    ReqTestSite.expect_once(site, "GET", "/archive/entry", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, entry)
    end)

    ReqTestSite.expect_once(site, "GET", "/archive/sheet.css", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/css")
      |> Plug.Conn.resp(200, sheet)
    end)

    for {path, type, body} <- [
          {"/archive/a.jpg", "image/jpeg", "a"},
          {"/archive/b.jpg", "image/jpeg", "b"},
          {"/archive/c.webp", "image/webp", "c"},
          {"/archive/c.jpg", "image/jpeg", "c-jpg"},
          {"/archive/d.mp4", "video/mp4", "d"},
          {"/archive/d.jpg", "image/jpeg", "poster"},
          {"/archive/e.mp3", "audio/mpeg", "e"},
          {"/archive/pre.css", "text/css", "/* pre */"},
          {"/archive/alt.css", "text/css", "/* alt */"},
          {"/archive/bg.png", "image/png", "bg"},
          {"/archive/bg2.png", "image/png", "bg2"},
          {"/archive/other.css", "text/css", "/* other */"},
          {"/archive/nested.css", "text/css", "/* nested */"},
          {"/archive/spaced.png", "image/png", "spaced"},
          {"/archive/font.woff2", "font/woff2", "font"},
          {"/archive/bare", "text/html", "PAGE"},
          {"/archive/bare/index.html", "text/html", "INDEX"}
        ] do
      ReqTestSite.expect_once(site, "GET", path, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", type)
        |> Plug.Conn.resp(200, body)
      end)
    end

    ReqTestSite.stub(site, "GET", "/archive/search", fn conn ->
      label = if conn.query_string == "q=1&x=2", do: "1", else: "2"

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "results for " <> label)
    end)

    {:ok, opts} =
      start_crawl("#{url}/archive/entry",
        scope: "archive",
        assets: ["images", "css"],
        max_depths: 3,
        workers: 4,
        save_to: tmp("behavior-archive"),
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)

      root = tmp("behavior-archive/#{site.path}/archive")
      page = File.read!(Path.join(root, "entry/__index.html"))
      css = File.read!(Path.join(root, "sheet.css"))
      paths = Path.wildcard(Path.join(tmp("behavior-archive"), "**/*"))

      assert @utf8_bom <> "PAGE" == File.read!(Path.join(root, "bare/__index.html"))
      assert @utf8_bom <> "INDEX" == File.read!(Path.join(root, "bare/index.html"))

      for {query, body} <- [{"q=1&x=2", "results for 1"}, {"q=2", "results for 2"}] do
        target = "#{url}/archive/search?#{query}"
        assert_link_opens(tmp("behavior-archive"), "#{url}/archive/entry", target)
        assert File.read!(saved(tmp("behavior-archive"), target)) == @utf8_bom <> body
      end

      Enum.each(paths, fn path ->
        refute path =~ "?"
        refute path =~ "&"
      end)

      refute page =~ ~s|srcset="a.jpg 1x, b.jpg 2x"|
      refute page =~ ~s|src="d.mp4"|
      refute page =~ ~s|href="pre.css"|
      refute page =~ "url('bg2.png')"
      refute page =~ ~s|href="/archive/search?q=1&amp;x=2"|
      assert page =~ "b.jpg"
      assert page =~ "c.webp"
      assert page =~ "e.mp3"
      assert page =~ "__q_q%3D1%2526x%3D2.html"

      refute css =~ ~s|@import "other.css"|
      refute css =~ ~s|url( "spaced.png" )|
      refute css =~ "url( 'font.woff2' )"
      assert css =~ "other.css"
      assert css =~ "nested.css"
      assert css =~ "spaced.png"
      assert css =~ "font.woff2"
    end)
  end

  test "crawls embedded resources and skips them when assets are empty", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    page = "#{url}/embed/page"

    html = """
    <html>
      <area href="area.html">
      <iframe src="frame.html"></iframe>
      <link rel="icon" href="icon.png">
      <link rel="shortcut icon" href="shortcut.png">
      <link rel="preload" as="image" href="pre.png">
      <link rel="preload" as="script" href="pre.js">
      <link rel="preload" as="font" href="pre.woff2">
      <track src="cap.vtt">
      <svg><image href="svg.png"></image><use href="icons.svg#a"></use></svg>
    </html>
    """

    ReqTestSite.expect_once(site, "GET", "/embed/page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, html)
    end)

    for path <- ~w(
      /embed/area.html
      /embed/frame.html
      /embed/icon.png
      /embed/shortcut.png
      /embed/pre.png
      /embed/pre.js
      /embed/pre.woff2
      /embed/cap.vtt
      /embed/svg.png
      /embed/icons.svg
    ) do
      ReqTestSite.expect_once(site, "GET", path, fn conn ->
        type =
          if String.ends_with?(path, ".html"), do: "text/html", else: "application/octet-stream"

        conn
        |> Plug.Conn.put_resp_header("content-type", type)
        |> Plug.Conn.resp(200, path)
      end)
    end

    {:ok, opts} =
      start_crawl(page,
        scope: "embed",
        assets: ["images", "css", "js"],
        max_depths: 2,
        workers: 4,
        save_to: tmp("behavior-embed"),
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)

      for path <- ~w(
        /embed/area.html
        /embed/frame.html
        /embed/icon.png
        /embed/shortcut.png
        /embed/pre.png
        /embed/pre.js
        /embed/pre.woff2
        /embed/cap.vtt
        /embed/svg.png
        /embed/icons.svg
      ) do
        assert Store.find_processed({"#{url}#{path}", "embed"})
      end

      saved = File.read!(tmp("behavior-embed/#{site.path}/embed/page", "__index.html"))

      for raw <- ~w(
        area.html
        frame.html
        icon.png
        shortcut.png
        pre.png
        pre.js
        pre.woff2
        cap.vtt
        svg.png
      ) do
        refute saved =~ ~s|="#{raw}"|
      end

      refute saved =~ ~s|href="icons.svg#a"|
      assert saved =~ "icons.svg#a"
    end)

    bare = "#{url}/embed/bare"

    ReqTestSite.expect_once(site, "GET", "/embed/bare", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, """
      <link rel="icon" href="icon.png"><link rel="preload" as="script" href="pre.js">
      """)
    end)

    {:ok, skipped} =
      start_crawl(bare,
        scope: "embed-empty",
        assets: [],
        workers: 1,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(skipped)
      assert Store.find_processed({bare, "embed-empty"})
      refute Store.find({"#{url}/embed/icon.png", "embed-empty"})
      refute Store.find({"#{url}/embed/pre.js", "embed-empty"})
    end)
  end
end
