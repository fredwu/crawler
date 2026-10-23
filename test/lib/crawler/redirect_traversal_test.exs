defmodule Crawler.RedirectTraversalTest do
  use Crawler.TestCase, async: false

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  alias Crawler.Store

  import Crawler.RedirectHelpers
  import Crawler.ManagedSnapshotHelpers

  test "a redirect hop is not a second page", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = Path.join(tmp("page-identity-budget"), "archive")
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
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        max_pages: 1,
        max_depths: 3,
        save_to: root,
        req_options: req_options
      )

    export = ready_export(opts)

    assert read_resource(export, resource_for_url(export, new)) =~ "PAGE"
    source = resource_for_url(export, new)

    assert [href] =
             Floki.attribute(Floki.parse_document!(read_resource(export, source)), "a", "href")

    assert href ==
             new
             |> URI.parse()
             |> Map.put(:path, String.replace(URI.parse(new).path, ~r/[^\/]+$/, "next"))
             |> URI.to_string()

    assert [%{"outcome" => outcome, "target" => nil}] =
             Enum.filter(export.manifest["references"], &(&1["from"] == source["id"]))

    assert outcome in ["limited", "rejected", "absent"]
    assert Store.find_processed({old, scope})
    assert Store.find_processed({new, scope})
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
    root = Path.join(tmp("page-identity-depth"), "archive")
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
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        max_depths: 1,
        save_to: root,
        req_options: req_options
      )

    export = ready_export(opts)

    assert read_resource(export, resource_for_url(export, new)) =~ "LANDED"
    source = resource_for_url(export, new)

    assert [href] =
             Floki.attribute(Floki.parse_document!(read_resource(export, source)), "a", "href")

    assert href ==
             new
             |> URI.parse()
             |> Map.put(:path, String.replace(URI.parse(new).path, ~r/[^\/]+$/, "next"))
             |> URI.to_string()

    assert [%{"outcome" => outcome, "target" => nil}] =
             Enum.filter(export.manifest["references"], &(&1["from"] == source["id"]))

    assert outcome in ["limited", "rejected", "absent"]
    assert Store.find_processed({old, scope})
    assert Store.find_processed({new, scope})
    assert Store.ops_count(scope) == 1
    refute Store.find({"#{url}/id/depth/next", scope})
  end

  defp exercise_processed_landing(%{site: site, url: url, req_options: req_options}, store) do
    scope = unique_scope("page-identity-alias")
    root = Path.join(tmp(scope), "archive")
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

    observer = self()
    hold = "#{url}/id/alias/hold"

    ReqTestSite.expect_once(site, "GET", "/id/alias/hold", fn conn ->
      send(observer, {:holding_export, self()})

      receive do
        :release_export -> Plug.Conn.resp(conn, 404, "HOLD")
      end
    end)

    seed = "#{url}/id/alias/seed"

    html(
      site,
      "/id/alias/seed",
      ~s(<a href="#{new}">direct</a><a href="#{hold}">hold</a><a href="#{old}">redirect</a>)
    )

    opts = [
      scope: scope,
      workers: 3,
      max_body: 1_048_576,
      max_analysis_bytes: 16_000_000,
      max_css_work: 5_000,
      max_css_pictures: 1_000,
      store: store,
      save_to: root,
      req_options: req_options
    ]

    # Hold the old response until the first landing has completed.
    ReqTestSite.expect_once(site, "GET", "/id/alias/old", fn conn ->
      send(observer, {:holding_redirect, self()})

      receive do
        :release_redirect ->
          conn |> Plug.Conn.put_resp_header("location", new) |> Plug.Conn.resp(302, "")
      end
    end)

    first = crawl(seed, opts)
    assert_receive {:holding_export, holder}, 2_000
    assert_receive {:holding_redirect, redirect_holder}, 2_000

    on_exit(fn ->
      send(holder, :release_export)
      send(redirect_holder, :release_redirect)
    end)

    wait(fn -> assert Store.find_processed({new, scope}) end)
    assert count(hits) == 1
    landing = Store.find_processed({new, scope})

    text(site, "/id/alias/next", "NEXT")
    send(redirect_holder, :release_redirect)
    wait(fn -> assert Store.find_processed({next, scope}) end)
    send(holder, :release_export)
    export = ready_export(first)

    assert count(hits) == 2
    assert Store.find_processed({new, scope}) == landing
    assert landing.body == if(store == Store, do: "DIRECT")
    assert Store.find_processed({old, scope}).body == if(store == Store, do: redirected_body)
    assert Store.find_processed({next, scope}).body == if(store == Store, do: "NEXT")
    source = resource_for_url(export, seed)
    direct = edge_target(export, source, 0)
    redirected = edge_target(export, source, 2)

    assert [direct_href, _hold_href, redirect_href] =
             Floki.attribute(Floki.parse_document!(read_resource(export, source)), "a", "href")

    assert_opens(export, source, direct, direct_href)
    assert_opens(export, source, redirected, redirect_href)
    assert read_resource(export, direct) == @utf8_bom <> "DIRECT"
    redirected_bytes = read_resource(export, redirected)
    assert redirected_bytes =~ "REDIRECT"
    target = reference_target(export, redirected, next)
    assert [next_href] = Floki.attribute(Floki.parse_document!(redirected_bytes), "a", "href")
    assert_opens(export, redirected, target, next_href)
    assert read_resource(export, target) == "NEXT"
    assert Store.ops_count(scope) - 1 == 3
  end
end
