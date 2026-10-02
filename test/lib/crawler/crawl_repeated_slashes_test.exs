defmodule Crawler.CrawlRepeatedSlashesTest do
  use Crawler.TestCase, async: false

  alias Crawler.Linker.Snapshot
  alias Crawler.RequestLog
  alias Crawler.Store

  import Crawler.SnapshotHelpers

  test "repeated trailing slashes keep their HTTP requests, stored pages, and files distinct", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = tmp("crawl-repeated-trailing-slashes")
    scope = unique_scope("repeated-trailing-slashes")
    hub = url <> "/trail/entry"
    requests = RequestLog.new()

    paths = [
      "/trail/a",
      "/trail/a/",
      "/trail/a//",
      "/trail/a///",
      "/trail/app.js",
      "/trail/app.js//"
    ]

    serve_pages(site, requests, paths)

    {:ok, opts} =
      start_crawl(hub,
        scope: scope,
        workers: 1,
        store: Store,
        max_depths: 2,
        save_to: root,
        req_options: req_options
      )

    on_exit(fn -> Crawler.stop(opts) end)
    await_idle(opts)
    hits = RequestLog.entries(requests)
    assert Enum.count(hits, &(&1 in ["/trail/a", "/trail/a/"])) == 1
    assert length(hits) == 6
    assert Store.ops_count(scope) == 6

    leaves = paths -- ["/trail/a/"]

    for path <- leaves do
      target = url <> path
      assert Enum.count(hits, &(&1 == path)) == 1 or path == "/trail/a"
      assert %{body: body} = Store.find_processed({target, scope})
      assert body == "BODY:" <> path
      assert File.read!(saved(root, target)) == body
      assert_link_opens(root, hub, target)
    end

    assert Store.find_processed({url <> "/trail/a", scope}) ==
             Store.find_processed({url <> "/trail/a/", scope})

    saved_paths = Enum.map(leaves, &Snapshot.path(url <> &1))
    assert length(Enum.uniq(saved_paths)) == length(leaves)
  end

  defp serve_pages(site, requests, paths) do
    ReqTestSite.expect_once(site, "GET", "/trail/entry", fn conn ->
      RequestLog.record(requests, conn.request_path)
      links = Enum.map_join(paths ++ ["/trail/a/x/..//"], "", &~s(<a href="#{&1}">page</a>))

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, links)
    end)

    for path <- paths do
      ReqTestSite.stub(site, "GET", path, fn conn ->
        RequestLog.record(requests, conn.request_path)
        body = if path == "/trail/a/", do: "BODY:/trail/a", else: "BODY:" <> path

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.resp(200, body)
      end)
    end
  end
end
