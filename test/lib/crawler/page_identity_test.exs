defmodule Crawler.PageIdentityTest do
  use Crawler.TestCase, async: false

  alias Crawler.RequestLog
  alias Crawler.Store

  import Crawler.RedirectHelpers
  import Crawler.SnapshotHelpers
  alias Crawler.Linker.Snapshot

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "http, https, userinfo, an empty query, and path case do not share a file" do
    root = tmp("page-identity-distinct")
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
          "body:#{uri.scheme}:#{uri.userinfo}:#{uri.path}:#{inspect(uri.query)}:#{System.unique_integer([:positive])}"
        end

      {request,
       Req.Response.new(status: 200, headers: [{"content-type", "text/html"}], body: body)}
    end

    opts =
      crawl(hub,
        scope: scope,
        workers: 1,
        max_depths: 2,
        save_to: root,
        req_options: [adapter: adapter, retry: false]
      )

    await_idle(opts)

    assert Store.ops_count(scope) == length(leaves) + 1
    requests = RequestLog.entries(seen)
    assert length(requests) == length(leaves) + 1

    Enum.each(leaves, fn leaf ->
      page = Store.find_processed({leaf, scope})
      assert @utf8_bom <> page.body == File.read!(saved(root, leaf))
      assert_link_opens(root, hub, leaf)
    end)

    refute File.read!(saved(root, "http://ex.com/id/scheme")) ==
             File.read!(saved(root, "https://ex.com/id/scheme"))

    refute File.read!(saved(root, "http://a:b@ex.com/id/secret")) ==
             File.read!(saved(root, "http://ex.com/id/secret"))

    refute File.read!(saved(root, "http://ex.com/id/search")) ==
             File.read!(saved(root, "http://ex.com/id/search?"))

    refute File.read!(saved(root, "http://ex.com/id/docs")) ==
             File.read!(saved(root, "http://ex.com/id/Docs"))

    paths = Enum.map(leaves, &String.downcase(Snapshot.path(&1)))
    assert paths == Enum.uniq(paths)

    assert {"https", nil, "/id/scheme", nil} in requests
    assert {"http", "a:b", "/id/secret", nil} in requests
    assert {"http", "A:B", "/id/secret", nil} in requests
    assert {"http", nil, "/id/search", nil} in requests
    assert {"http", nil, "/id/search", ""} in requests
  end

  test "a redirect to a bare question mark stays a different page" do
    root = tmp("page-identity-empty-query")
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
        max_depths: 2,
        save_to: root,
        req_options: [adapter: adapter, retry: false]
      )

    await_idle(opts)

    assert queries |> RequestLog.entries() |> Enum.frequencies() == %{
             {"/id/old", nil} => 1,
             {"/id/search", ""} => 1,
             {"/id/search", nil} => 1
           }

    assert File.read!(saved(root, old)) =~ "EMPTY"
    assert File.read!(saved(root, empty)) =~ "EMPTY"
    assert File.read!(saved(root, bare)) == "BARE"
    assert Snapshot.path(empty) != Snapshot.path(bare)
    assert_link_opens(root, old, bare)
    assert_link_opens(root, empty, bare)
    assert Store.find_processed({empty, scope})
    assert Store.find_processed({bare, scope})
    assert Store.ops_count(scope) == 2
  end

  test "an allowed redirect to https is saved under both addresses" do
    root = tmp("page-identity-https-redirect")
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
        max_depths: 2,
        save_to: root,
        req_options: [adapter: adapter, retry: false]
      )

    await_idle(opts)

    assert hits |> RequestLog.entries() |> Enum.frequencies() == %{
             {"http", "/id/old"} => 1,
             {"https", "/id/dir/new"} => 1,
             {"https", "/id/dir/next"} => 1
           }

    assert Snapshot.path(new) =~ "__scheme_https"
    assert File.read!(saved(root, old)) =~ "LANDED"
    assert File.read!(saved(root, new)) =~ "LANDED"
    refute File.read!(saved(root, old)) == File.read!(saved(root, new))
    assert_link_opens(root, old, nxt)
    assert_link_opens(root, new, nxt)
    assert Store.find_processed({new, scope})
    assert Store.ops_count(scope) == 2
  end
end
