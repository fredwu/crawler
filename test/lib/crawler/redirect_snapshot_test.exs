defmodule Crawler.RedirectSnapshotTest do
  use Crawler.TestCase, async: false

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  alias Crawler.Store

  import Crawler.RedirectHelpers
  import Crawler.ManagedSnapshotHelpers

  test "a redirect is saved at the requested address and the landing address", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = Path.join(tmp("page-identity-redirect"), "archive")
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

    landing_hits = :counters.new(1, [:atomics])

    ReqTestSite.expect(site, "GET", "/id/dir/new", fn conn ->
      :counters.add(landing_hits, 1, 1)
      assert :counters.get(landing_hits, 1) <= 2

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, ~s(<p>LANDED</p><a href="next">next</a>))
    end)

    text(site, "/id/dir/next", "NEXT")
    html(site, "/id/later", ~s(<a href="#{new}">landed</a>))

    opts =
      crawl(hub,
        scope: scope,
        workers: 1,
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        max_depths: 3,
        save_to: root,
        req_options: req_options
      )

    export = ready_export(opts)

    assert Store.ops_count(scope) == 4
    assert :counters.get(landing_hits, 1) == 2
    assert Store.find_processed({old, scope}).body =~ "LANDED"
    assert Store.find_processed({new, scope}).body =~ "LANDED"
    assert Store.find_processed({nxt, scope}).body == "NEXT"

    seed = resource_for_url(export, hub)
    landed = reference_target(export, seed, old)
    later_resource = reference_target(export, seed, later)

    assert [old_href, later_href] =
             Floki.attribute(Floki.parse_document!(read_resource(export, seed)), "a", "href")

    assert_opens(export, seed, landed, old_href)
    assert_opens(export, seed, later_resource, later_href)
    assert read_resource(export, landed) =~ "LANDED"

    assert [next_href] =
             Floki.attribute(Floki.parse_document!(read_resource(export, landed)), "a", "href")

    target = reference_target(export, landed, nxt)
    assert_opens(export, landed, target, next_href)
    assert read_resource(export, target) == "NEXT"

    assert [landed_href] =
             Floki.attribute(
               Floki.parse_document!(read_resource(export, later_resource)),
               "a",
               "href"
             )

    later_target = reference_target(export, later_resource, new)
    assert_opens(export, later_resource, later_target, landed_href)
    assert read_resource(export, later_target) =~ "LANDED"
  end

  test "a relative location is saved at both addresses", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = Path.join(tmp("page-identity-relative"), "archive")
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
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        max_depths: 2,
        save_to: root,
        req_options: req_options
      )

    export = ready_export(opts)

    assert Store.ops_count(scope) == 2
    assert Store.find_processed({old, scope}).body =~ "LANDED"
    assert Store.find_processed({new, scope}).body =~ "LANDED"
    source = resource_for_url(export, new)
    target = reference_target(export, source, nxt)

    assert [href] =
             Floki.attribute(Floki.parse_document!(read_resource(export, source)), "a", "href")

    assert_opens(export, source, target, href)
    assert read_resource(export, target) == "NEXT"
  end

  test "an absolute-path location is saved at both addresses", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = Path.join(tmp("page-identity-abs-location"), "archive")
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
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        max_depths: 2,
        save_to: root,
        req_options: req_options
      )

    export = ready_export(opts)

    assert Store.ops_count(scope) == 2
    assert Store.find_processed({old, scope}).body =~ "LANDED"
    assert Store.find_processed({new, scope}).body =~ "LANDED"
    source = resource_for_url(export, new)
    target = reference_target(export, source, nxt)

    assert [href] =
             Floki.attribute(Floki.parse_document!(read_resource(export, source)), "a", "href")

    assert_opens(export, source, target, href)
    assert read_resource(export, target) == "NEXT"
  end

  test "a plain redirect writes the same bytes to both files", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = Path.join(tmp("page-identity-plain"), "archive")
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

    opts =
      crawl(old,
        scope: scope,
        workers: 1,
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        save_to: root,
        req_options: req_options
      )

    export = ready_export(opts)

    assert read_resource(export, resource_for_url(export, new)) == "PLAIN"
    assert Store.find_processed({old, scope}).body == "PLAIN"
    assert Store.find_processed({new, scope}).body == "PLAIN"
  end

  test "a trailing slash redirect writes one file", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = Path.join(tmp("page-identity-slash"), "archive")
    scope = "page-identity-slash"
    page = "#{url}/id/slash"
    slashed = page <> "/"

    ReqTestSite.expect_once(site, "GET", "/id/slash", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", slashed)
      |> Plug.Conn.resp(302, "")
    end)

    ReqTestSite.expect_once(site, "GET", "/id/slash/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "SLASH")
    end)

    opts =
      crawl(page,
        scope: scope,
        workers: 1,
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        save_to: root,
        req_options: req_options
      )

    export = ready_export(opts)

    assert read_resource(export, resource_for_url(export, slashed)) == @utf8_bom <> "SLASH"
    assert Store.find_processed({page, scope}).body == "SLASH"
    assert Store.find_processed({slashed, scope}).body == "SLASH"
    assert Store.ops_count(scope) == 1
  end
end
