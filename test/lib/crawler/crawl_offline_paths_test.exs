defmodule Crawler.CrawlOfflinePathsTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "a trailing slash is the same url and offline file", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    ReqTestSite.expect_once(site, "GET", "/slash/entry", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, """
      <html>
        <a href="#{url}/slash/foo">a</a>
        <a href="#{url}/slash/foo/">b</a>
      </html>
      """)
    end)

    hits = :counters.new(1, [:atomics])

    for path <- ["/slash/foo", "/slash/foo/"] do
      ReqTestSite.stub(site, "GET", path, fn conn ->
        :counters.add(hits, 1, 1)

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.resp(200, "FOO")
      end)
    end

    {:ok, opts} =
      start_crawl("#{url}/slash/entry",
        scope: "slash",
        workers: 2,
        save_to: tmp("behavior-slash"),
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)
      assert :counters.get(hits, 1) == 1

      assert File.read!(tmp("behavior-slash/#{site.path}/slash/foo", "__index.html")) ==
               @utf8_bom <> "FOO"

      assert Store.find_processed({"#{url}/slash/foo", "slash"})
      assert Store.find_processed({"#{url}/slash/foo/", "slash"})
    end)
  end

  test "a directory url keeps relative links inside that directory", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    ReqTestSite.expect_once(site, "GET", "/dir/docs/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, ~s(<a href="intro">intro</a>))
    end)

    ReqTestSite.expect_once(site, "GET", "/dir/docs/intro", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "INTRO")
    end)

    {:ok, opts} =
      start_crawl("#{url}/dir/docs/",
        scope: "directory",
        workers: 2,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({"#{url}/dir/docs/intro", "directory"})
      refute Store.find({"#{url}/intro", "directory"})
      refute Store.find({"#{url}/dir/intro", "directory"})
    end)
  end

  test "a dotted directory does not block a child path", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    ReqTestSite.expect_once(site, "GET", "/dot/about.me", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "PARENT")
    end)

    ReqTestSite.expect_once(site, "GET", "/dot/about.me/team", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "CHILD")
    end)

    {:ok, parent} =
      start_crawl("#{url}/dot/about.me",
        scope: "dotted",
        workers: 1,
        save_to: tmp("behavior-dotted"),
        req_options: req_options
      )

    {:ok, child} =
      start_crawl("#{url}/dot/about.me/team",
        scope: "dotted",
        queue: parent[:queue],
        save_to: tmp("behavior-dotted"),
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(child)

      root = tmp("behavior-dotted/#{site.path}/dot")
      assert File.read!(Path.join(root, "about.me/__index.html")) == @utf8_bom <> "PARENT"
      assert File.read!(Path.join(root, "about.me/team/__index.html")) == @utf8_bom <> "CHILD"
    end)
  end

  test "saved xhtml resolves a directory base and drops the live tag", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    page = "#{url}/xhtml/page"

    ReqTestSite.expect_once(site, "GET", "/xhtml/page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/xhtml+xml")
      |> Plug.Conn.resp(200, """
      <html><head><base href="#{url}/xhtml/dir/" /></head>
      <a href="intro">intro</a></html>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/xhtml/dir/intro", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/xhtml+xml")
      |> Plug.Conn.resp(200, "INTRO")
    end)

    {:ok, opts} =
      start_crawl(page,
        scope: "xhtml",
        workers: 2,
        save_to: tmp("behavior-xhtml"),
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({"#{url}/xhtml/dir/intro", "xhtml"})

      html = File.read!(tmp("behavior-xhtml/#{site.path}/xhtml/page", "__index.html"))
      refute html =~ ~r/<base[^>]+href=['"]https?:\/\//i
      assert html =~ "intro"
      refute html =~ ~s|href="intro"|
    end)
  end

  test "saved html drops a live base href", %{site: site, url: url, req_options: req_options} do
    page = "#{url}/base/page"

    ReqTestSite.expect_once(site, "GET", "/base/page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, """
      <html><head><base href="#{url}/base/dir/"></head>
      <a href="next">next</a></html>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/base/dir/next", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "NEXT")
    end)

    {:ok, opts} =
      start_crawl(page,
        scope: "base",
        workers: 2,
        save_to: tmp("behavior-base"),
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({"#{url}/base/dir/next", "base"})

      html = File.read!(tmp("behavior-base/#{site.path}/base/page", "__index.html"))
      refute html =~ ~r/<base[^>]+href=['"]https?:\/\//i
      refute html =~ ~s|href="next"|
      refute html =~ "#{url}/base/dir/next"
      assert html =~ "next/__index.html"
    end)
  end
end
