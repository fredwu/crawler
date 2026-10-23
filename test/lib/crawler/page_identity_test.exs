defmodule Crawler.PageIdentityTest do
  use Crawler.TestCase, async: false

  alias Crawler.RequestLog
  alias Crawler.Store

  import Crawler.RedirectHelpers
  import Crawler.ManagedSnapshotHelpers

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "http, https, userinfo, an empty query, and path case do not share a file" do
    root = Path.join(tmp("page-identity-distinct"), "archive")
    scope = "page-identity-distinct"
    hub = "http://ex.com/id/hub"

    leaves = [
      "http://ex.com/id/scheme",
      "https://ex.com/id/scheme",
      "http://a:b@ex.com/id/secret",
      "http://A:B@ex.com/id/secret",
      "http://ex.com/id/secret",
      "http://ex.com/id/search",
      "http://ex.com/id/search?",
      "http://ex.com/id/search?q=1",
      "http://ex.com/id/search?Q=1",
      "http://ex.com/id/docs",
      "http://ex.com/id/Docs"
    ]

    seen = RequestLog.new()

    adapter = fn request ->
      uri = request.url
      RequestLog.record(seen, {uri.scheme, uri.userinfo, uri.path, uri.query})

      body =
        if uri.path == "/id/hub" do
          Enum.map_join(leaves, "", fn leaf -> ~s(<a href="#{leaf}"></a>) end)
        else
          "body:#{uri.scheme}:#{uri.userinfo}:#{uri.path}:#{inspect(uri.query)}"
        end

      {request,
       Req.Response.new(status: 200, headers: [{"content-type", "text/html"}], body: body)}
    end

    opts =
      crawl(hub,
        scope: scope,
        workers: 1,
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        max_depths: 2,
        save_to: root,
        max_manifest_bytes: 16_777_216,
        req_options: [adapter: adapter, retry: false]
      )

    export = ready_export(opts)

    assert Store.ops_count(scope) == length(leaves) + 1
    requests = RequestLog.entries(seen)
    assert length(requests) == length(leaves) + 1

    source = resource_for_url(export, hub)
    hrefs = Floki.attribute(Floki.parse_document!(read_resource(export, source)), "a", "href")
    assert length(hrefs) == length(leaves)

    targets =
      for {{leaf, href}, index} <- Enum.with_index(Enum.zip(leaves, hrefs)) do
        uri = URI.parse(leaf)
        expected = "body:#{uri.scheme}:#{uri.userinfo}:#{uri.path}:#{inspect(uri.query)}"
        page = Store.find_processed({leaf, scope})
        assert page.body == expected
        target = edge_target(export, source, index)
        assert_opens(export, source, target, href)
        assert read_resource(export, target) == @utf8_bom <> expected
        target
      end

    paths = Enum.map(targets, &String.downcase(&1["path"]))
    assert paths == Enum.uniq(paths)

    for resource <- export.manifest["resources"] do
      refute resource["path"] =~ "a:b"
      refute resource["path"] =~ "A:B"
      assert is_nil(URI.parse(resource["url"]).userinfo)
    end

    assert {"https", nil, "/id/scheme", nil} in requests
    assert {"http", "a:b", "/id/secret", nil} in requests
    assert {"http", "A:B", "/id/secret", nil} in requests
    assert {"http", nil, "/id/search", nil} in requests
    assert {"http", nil, "/id/search", ""} in requests
  end

  test "a redirect to a bare question mark stays a different page" do
    root = Path.join(tmp("page-identity-empty-query"), "archive")
    scope = "page-identity-empty-query"
    old = "http://ex.com/id/old"
    empty = "http://ex.com/id/search?"
    bare = "http://ex.com/id/search"
    queries = RequestLog.new()

    adapter = fn request ->
      uri = request.url
      RequestLog.record(queries, {uri.path, uri.query})

      cond do
        uri.path == "/id/old" ->
          redirect(request, empty)

        uri.path == "/id/search" and uri.query == "" ->
          html_response(request, ~s(<p>EMPTY</p><a href="#{bare}">bare</a>))

        uri.path == "/id/search" and uri.query == nil ->
          text_response(request, "BARE")

        true ->
          text_response(request, "UNEXPECTED")
      end
    end

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
        max_manifest_bytes: 16_777_216,
        req_options: [adapter: adapter, retry: false]
      )

    export = ready_export(opts)

    assert queries |> RequestLog.entries() |> Enum.frequencies() == %{
             {"/id/old", nil} => 1,
             {"/id/search", ""} => 1,
             {"/id/search", nil} => 1
           }

    assert read_resource(export, resource_for_url(export, empty)) =~ "EMPTY"
    assert read_resource(export, resource_for_url(export, bare)) == "BARE"
    refute resource_for_url(export, empty)["id"] == resource_for_url(export, bare)["id"]
    source = resource_for_url(export, empty)
    target = reference_target(export, source, bare)

    assert [href] =
             Floki.attribute(Floki.parse_document!(read_resource(export, source)), "a", "href")

    assert_opens(export, source, target, href)
    assert read_resource(export, target) == "BARE"
    assert Store.find_processed({old, scope}).body =~ "EMPTY"
    assert Store.find_processed({empty, scope})
    assert Store.find_processed({bare, scope})
    assert Store.ops_count(scope) == 2
  end

  test "an allowed redirect to https is saved under both addresses" do
    root = Path.join(tmp("page-identity-https-redirect"), "archive")
    scope = "page-identity-https-redirect"
    old = "http://ex.com/id/old"
    new = "https://ex.com/id/dir/new"
    nxt = "https://ex.com/id/dir/next"
    hits = RequestLog.new()

    adapter = fn request ->
      uri = request.url
      RequestLog.record(hits, {uri.scheme, uri.path})

      cond do
        uri.scheme == "http" and uri.path == "/id/old" ->
          redirect(request, new)

        uri.scheme == "https" and uri.path == "/id/dir/new" ->
          html_response(request, ~s(<p>LANDED</p><a href="next">next</a>))

        uri.scheme == "https" and uri.path == "/id/dir/next" ->
          text_response(request, "NEXT")

        true ->
          text_response(request, "UNEXPECTED")
      end
    end

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
        max_manifest_bytes: 16_777_216,
        req_options: [adapter: adapter, retry: false]
      )

    export = ready_export(opts)

    assert hits |> RequestLog.entries() |> Enum.frequencies() == %{
             {"http", "/id/old"} => 1,
             {"https", "/id/dir/new"} => 1,
             {"https", "/id/dir/next"} => 1
           }

    assert read_resource(export, resource_for_url(export, new)) =~ "LANDED"
    source = resource_for_url(export, new)
    target = reference_target(export, source, nxt)

    assert [href] =
             Floki.attribute(Floki.parse_document!(read_resource(export, source)), "a", "href")

    assert_opens(export, source, target, href)
    assert read_resource(export, target) == "NEXT"
    assert Store.find_processed({old, scope}).body =~ "LANDED"
    assert Store.find_processed({new, scope})
    assert Store.ops_count(scope) == 2
  end
end
