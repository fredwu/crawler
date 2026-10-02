defmodule Crawler.RedirectSnapshotTest do
  use Crawler.TestCase, async: false

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  alias Crawler.Store

  import Crawler.RedirectHelpers
  import Crawler.SnapshotHelpers
  alias Crawler.Linker
  alias Crawler.Linker.Snapshot

  test "a redirect is saved at the requested address and the landing address", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-redirect")
    scope = "page-identity-redirect"
    hub = "#{url}/id/hub"
    old = "#{url}/id/old"
    new = "#{url}/id/dir/new"
    nxt = "#{url}/id/dir/next"
    later = "#{url}/id/later"

    html(site, "/id/hub", ~s(<a href="#{old}">old</a><a href="#{later}">later</a>))

    ReqTestSite.expect_once(site, "GET", "/id/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", new)
      |> Plug.Conn.resp(302, "")
    end)

    html(site, "/id/dir/new", ~s(<p>LANDED</p><a href="next">next</a>))
    text(site, "/id/dir/next", "NEXT")
    html(site, "/id/later", ~s(<a href="#{new}">landed</a>))

    opts =
      crawl(hub,
        scope: scope,
        workers: 1,
        max_depths: 3,
        save_to: root,
        req_options: req_options
      )

    await_idle(opts)

    assert Store.ops_count(scope) == 4
    assert Store.find_processed({old, scope}).body =~ "LANDED"
    assert Store.find_processed({new, scope}).body =~ "LANDED"
    assert Store.find_processed({nxt, scope}).body == "NEXT"

    old_href = Linker.offline_link(old, nxt)
    new_href = Linker.offline_link(new, nxt)
    refute old_href == new_href
    assert File.read!(saved(root, old)) =~ "LANDED"
    assert File.read!(saved(root, new)) =~ "LANDED"
    assert_link_opens(root, old, nxt)
    assert_link_opens(root, new, nxt)
    assert_link_opens(root, later, new)
  end

  test "a relative location is saved at both addresses", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-relative")
    scope = "page-identity-relative"
    old = "#{url}/id/rel/old"
    new = "#{url}/id/rel/dir/new"
    nxt = "#{url}/id/rel/dir/next"

    ReqTestSite.expect_once(site, "GET", "/id/rel/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "dir/new")
      |> Plug.Conn.resp(302, "")
    end)

    html(site, "/id/rel/dir/new", ~s(<p>LANDED</p><a href="next">next</a>))
    text(site, "/id/rel/dir/next", "NEXT")

    opts =
      crawl(old,
        scope: scope,
        workers: 1,
        max_depths: 2,
        save_to: root,
        req_options: req_options
      )

    await_idle(opts)

    assert Store.ops_count(scope) == 2
    assert Store.find_processed({old, scope}).body =~ "LANDED"
    assert Store.find_processed({new, scope}).body =~ "LANDED"
    refute File.read!(saved(root, old)) == File.read!(saved(root, new))
    assert_link_opens(root, old, nxt)
    assert_link_opens(root, new, nxt)
  end

  test "an absolute-path location is saved at both addresses", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-abs-location")
    scope = "page-identity-abs-location"
    old = "#{url}/id/abs/old"
    new = "#{url}/id/dir/nested/new"
    nxt = "#{url}/id/dir/nested/next"

    ReqTestSite.expect_once(site, "GET", "/id/abs/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "/id/dir/nested/new")
      |> Plug.Conn.resp(302, "")
    end)

    html(site, "/id/dir/nested/new", ~s(<p>LANDED</p><a href="next">next</a>))
    text(site, "/id/dir/nested/next", "NEXT")

    opts =
      crawl(old,
        scope: scope,
        workers: 1,
        max_depths: 2,
        save_to: root,
        req_options: req_options
      )

    await_idle(opts)

    assert Store.ops_count(scope) == 2
    assert Store.find_processed({old, scope}).body =~ "LANDED"
    assert Store.find_processed({new, scope}).body =~ "LANDED"
    refute File.read!(saved(root, old)) == File.read!(saved(root, new))
    assert_link_opens(root, old, nxt)
    assert_link_opens(root, new, nxt)
  end

  test "a plain redirect writes the same bytes to both files", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-plain")
    scope = "page-identity-plain"
    old = "#{url}/id/plain/old"
    new = "#{url}/id/plain/dir/new"

    ReqTestSite.expect_once(site, "GET", "/id/plain/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", new)
      |> Plug.Conn.resp(302, "")
    end)

    ReqTestSite.expect_once(site, "GET", "/id/plain/dir/new", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.resp(200, "PLAIN")
    end)

    opts = crawl(old, scope: scope, workers: 1, save_to: root, req_options: req_options)
    await_idle(opts)

    assert File.read!(saved(root, old)) == "PLAIN"
    assert File.read!(saved(root, new)) == "PLAIN"
    assert Snapshot.path(old) != Snapshot.path(new)
  end

  test "a trailing slash redirect writes one file", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-slash")
    scope = "page-identity-slash"
    page = "#{url}/id/slash"
    slashed = page <> "/"

    ReqTestSite.expect_once(site, "GET", "/id/slash", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", slashed)
      |> Plug.Conn.resp(302, "")
    end)

    ReqTestSite.expect_once(site, "GET", "/id/slash/", fn conn ->
      Plug.Conn.resp(conn, 200, "SLASH")
    end)

    opts = crawl(page, scope: scope, workers: 1, save_to: root, req_options: req_options)
    await_idle(opts)

    assert Snapshot.path(page) == Snapshot.path(slashed)
    assert File.read!(saved(root, page)) == @utf8_bom <> "SLASH"
    assert Store.find_processed({page, scope}).body == "SLASH"
    assert Store.find_processed({slashed, scope}).body == "SLASH"
    assert Store.ops_count(scope) == 1
  end
end
