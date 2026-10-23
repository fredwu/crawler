defmodule Crawler.CrawlOfflinePathsTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.RequestLog
  alias Crawler.Store

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "a trailing slash shares logical identity while preserving response artifacts", %{
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

    hits = RequestLog.new()

    for path <- ["/slash/foo", "/slash/foo/"] do
      ReqTestSite.expect_once(site, "GET", path, fn conn ->
        RequestLog.record(hits, conn.request_path)

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.resp(200, "FOO")
      end)
    end

    {:ok, opts} =
      start_crawl("#{url}/slash/entry",
        scope: "slash",
        workers: 2,
        save_to: Path.join(tmp(unique_scope("behavior-slash")), "archive"),
        req_options: req_options
      )

    export = ready_export(opts)
    assert RequestLog.frequencies(hits) == %{"/slash/foo" => 1, "/slash/foo/" => 1}
    assert Store.ops_count("slash") == 2
    source = resource_for_url(export, "#{url}/slash/entry")

    hrefs =
      read_resource(export, source) |> Floki.parse_document!() |> Floki.attribute("a", "href")

    assert length(hrefs) == 2

    for {href, index} <- Enum.with_index(hrefs) do
      target = edge_target(export, source, index)
      assert read_resource(export, target) == @utf8_bom <> "FOO"
      assert_opens(export, source, target, href)
    end

    assert leaf = Store.find_processed({"#{url}/slash/foo", "slash"})
    assert Store.find_processed({"#{url}/slash/foo/", "slash"}) == leaf
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

    key = make_ref()

    {:ok, parent} =
      start_crawl("#{url}/dot/about.me",
        scope: "dotted",
        workers: 2,
        save_to: Path.join(tmp(unique_scope("behavior-dotted")), "archive"),
        req_options: req_options,
        parser: Crawler.ManagedSnapshotHelpers.GateParser,
        managed_test_gates: [{"#{url}/dot/about.me", "a", self(), key}]
      )

    assert_receive {:managed_parser_held, ^key, held, _, _, _}, 2_000
    on_exit(fn -> send(held, {:managed_parser_release, key}) end)
    {:ok, child} = start_crawl("#{url}/dot/about.me/team", parent)
    send(held, {:managed_parser_release, key})
    export = ready_export(child)

    assert read_resource(export, resource_for_url(export, "#{url}/dot/about.me")) ==
             @utf8_bom <> "PARENT"

    assert read_resource(export, resource_for_url(export, "#{url}/dot/about.me/team")) ==
             @utf8_bom <> "CHILD"
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
        save_to: Path.join(tmp(unique_scope("behavior-xhtml")), "archive"),
        req_options: req_options
      )

    export = ready_export(opts)
    assert Store.find_processed({"#{url}/xhtml/dir/intro", opts.scope})
    source = resource_for_url(export, page)
    target = reference_target(export, source, "#{url}/xhtml/dir/intro")
    html = read_resource(export, source)
    refute html =~ ~r/<base[^>]+href=['"]https?:\/\//i
    assert [href] = html |> Floki.parse_document!() |> Floki.attribute("a", "href")
    assert_opens(export, source, target, href)
    assert target["content_type"] == "application/xhtml+xml"
    assert read_resource(export, target) == "INTRO"
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
        save_to: Path.join(tmp(unique_scope("behavior-base")), "archive"),
        req_options: req_options
      )

    export = ready_export(opts)
    assert Store.find_processed({"#{url}/base/dir/next", opts.scope})
    source = resource_for_url(export, page)
    target = reference_target(export, source, "#{url}/base/dir/next")
    html = read_resource(export, source)
    refute html =~ ~r/<base[^>]+href=['"]https?:\/\//i
    assert [href] = html |> Floki.parse_document!() |> Floki.attribute("a", "href")
    assert_opens(export, source, target, href)
    assert target["content_type"] == "text/html"
    assert read_resource(export, target) == @utf8_bom <> "NEXT"
  end
end
