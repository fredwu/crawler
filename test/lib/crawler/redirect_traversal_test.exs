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

  for store <- [nil, Store] do
    test "a later redirect preserves a processed landing with #{inspect(store)}", context do
      exercise_processed_landing(context, unquote(store))
    end
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

  defp exercise_processed_landing(%{site: site, url: url, req_options: req_options}, store) do
    scope = unique_scope("page-identity-alias")
    root = tmp(scope)
    old = "#{url}/id/alias/old"
    new = "#{url}/id/alias/new"
    next = "#{url}/id/alias/next"
    redirected_body = ~s(REDIRECT<a href="next">next</a>)
    hits = new_count()

    ReqTestSite.expect(site, "GET", "/id/alias/new", fn conn ->
      bump(hits)
      body = if count(hits) == 1, do: "DIRECT", else: redirected_body

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, body)
    end)

    opts = [scope: scope, workers: 1, store: store, save_to: root, req_options: req_options]
    first = crawl(new, opts)
    await_idle(first)
    assert count(hits) == 1
    landing = Store.find_processed({new, scope})

    ReqTestSite.expect_once(site, "GET", "/id/alias/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", new)
      |> Plug.Conn.resp(302, "")
    end)

    text(site, "/id/alias/next", "NEXT")
    second = crawl(old, opts)
    await_idle(second)

    assert count(hits) == 2
    assert Store.find_processed({new, scope}) == landing
    assert landing.body == if(store == Store, do: "DIRECT")
    assert Store.find_processed({old, scope}).body == if(store == Store, do: redirected_body)
    assert Store.find_processed({next, scope}).body == if(store == Store, do: "NEXT")
    assert File.read!(saved(root, old)) =~ "REDIRECT"
    assert File.read!(saved(root, new)) == @utf8_bom <> "DIRECT"
    assert_link_opens(root, old, next)
    assert Store.ops_count(scope) == 3
  end
end
