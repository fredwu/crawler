defmodule Crawler.CrawlRepeatedSlashesTest do
  use Crawler.TestCase, async: false

  alias Crawler.RequestLog
  alias Crawler.Store

  import Crawler.ManagedSnapshotHelpers

  test "repeated trailing slashes keep their HTTP requests, stored pages, and files distinct", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    root = Path.join(tmp(unique_scope("crawl-repeated-trailing-slashes")), "archive")
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
    export = ready_export(opts)
    source = resource_for_url(export, hub)
    assert RequestLog.frequencies(requests) == Map.new(["/trail/entry" | paths], &{&1, 1})
    assert Store.ops_count(scope) == 6

    hrefs =
      read_resource(export, source) |> Floki.parse_document!() |> Floki.attribute("a", "href")

    assert length(hrefs) == length(paths) + 1

    for {path, index} <- Enum.with_index(paths ++ ["/trail/a//"]) do
      target = url <> path
      expected = if path == "/trail/a/", do: "BODY:/trail/a", else: "BODY:" <> path
      assert %{body: body} = Store.find_processed({target, scope})
      assert body == expected
      resource = edge_target(export, source, index)
      assert read_resource(export, resource) == expected

      assert_opens(export, source, resource, Enum.at(hrefs, index))
    end

    assert Store.find_processed({url <> "/trail/a", scope}) ==
             Store.find_processed({url <> "/trail/a/", scope})

    saved_paths =
      for {_path, index} <- Enum.with_index(paths), do: edge_target(export, source, index)["path"]

    assert length(Enum.uniq(saved_paths)) == length(paths)
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
