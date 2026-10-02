defmodule Crawler.RedirectTraversalTest do
  use Crawler.TestCase, async: false

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  alias Crawler.Store

  import Crawler.RedirectHelpers
  import Crawler.SnapshotHelpers

  test "a redirect hop is not a second page", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-budget")
    scope = "page-identity-budget"
    old = "#{url}/id/budget/old"
    new = "#{url}/id/budget/new"

    ReqTestSite.expect_once(site, "GET", "/id/budget/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", new)
      |> Plug.Conn.resp(302, "")
    end)

    html(site, "/id/budget/new", ~s(<p>PAGE</p><a href="#{url}/id/budget/next">next</a>))

    opts =
      crawl(old,
        scope: scope,
        workers: 1,
        max_pages: 1,
        max_depths: 3,
        save_to: root,
        req_options: req_options
      )

    await_idle(opts)

    assert File.read!(saved(root, old)) =~ "PAGE"
    assert File.read!(saved(root, new)) =~ "PAGE"
    assert Store.ops_count(scope) == 1
    refute Store.find({"#{url}/id/budget/next", scope})
  end

  test "a redirect still fetches a landing page that was already stored", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-alias")
    scope = "page-identity-alias"
    old = "#{url}/id/alias/old"
    new = "#{url}/id/alias/new"
    hits = new_count()

    ReqTestSite.expect(site, "GET", "/id/alias/new", fn conn ->
      bump(hits)
      Plug.Conn.resp(conn, 200, "PAGE")
    end)

    first = crawl(new, scope: scope, workers: 1, save_to: root, req_options: req_options)
    await_idle(first)
    assert count(hits) == 1

    ReqTestSite.expect_once(site, "GET", "/id/alias/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", new)
      |> Plug.Conn.resp(302, "")
    end)

    second = crawl(old, scope: scope, workers: 1, save_to: root, req_options: req_options)
    await_idle(second)

    assert count(hits) == 2
    assert File.read!(saved(root, old)) == @utf8_bom <> "PAGE"
    assert File.read!(saved(root, new)) == @utf8_bom <> "PAGE"
    assert Store.find_processed({old, scope}).body == "PAGE"
    assert Store.ops_count(scope) == 2
  end

  test "a redirect past the link depth is saved and its links are not followed", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("page-identity-depth")
    scope = "page-identity-depth"
    old = "#{url}/id/depth/old"
    new = "#{url}/id/depth/new"

    ReqTestSite.expect_once(site, "GET", "/id/depth/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", new)
      |> Plug.Conn.resp(302, "")
    end)

    html(site, "/id/depth/new", ~s(<p>LANDED</p><a href="#{url}/id/depth/next">next</a>))

    opts =
      crawl(old,
        scope: scope,
        workers: 1,
        max_depths: 1,
        save_to: root,
        req_options: req_options
      )

    await_idle(opts)

    assert File.read!(saved(root, old)) =~ "LANDED"
    assert File.read!(saved(root, new)) =~ "LANDED"
    assert Store.ops_count(scope) == 1
    refute Store.find({"#{url}/id/depth/next", scope})
  end
end
