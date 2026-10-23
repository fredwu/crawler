defmodule Crawler.FetcherTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Fetcher
  alias Crawler.Fetcher.Modifier
  alias Crawler.Fetcher.Retrier
  alias Crawler.Fetcher.UrlFilter
  alias Crawler.Store

  doctest Fetcher

  defmodule DummyRetrier do
    @behaviour Retrier.Spec

    def perform(fetch_url, _opts), do: fetch_url.()
  end

  @defaults %{
    depth: 0,
    retries: 2,
    url_filter: UrlFilter,
    modifier: Modifier,
    retrier: DummyRetrier,
    store: Store,
    save_to: nil,
    html_tag: "a"
  }

  test "success", %{site: site, url: url, req_options: req_options} do
    url = "#{url}/fetcher/200"

    ReqTestSite.expect_once(site, "GET", "/fetcher/200", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "<html>200</html>")
    end)

    page =
      @defaults
      |> Map.merge(%{url: url, req_options: req_options})
      |> Fetcher.fetch()

    assert %Crawler.Store.Page{} = page
    assert page.url == url
    assert page.body == "<html>200</html>"
    assert Store.find({url, nil}).body == page.body
  end

  test "success: 301", %{site: site, url: url, req_options: req_options} do
    ReqTestSite.expect_once(site, "GET", "/fetcher/301", fn conn ->
      conn
      |> Plug.Conn.merge_resp_headers([{"location", "#{url}/fetcher/301_200"}])
      |> Plug.Conn.resp(301, "")
    end)

    ReqTestSite.expect_once(site, "GET", "/fetcher/301_200", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "<html>301_200</html>")
    end)

    url = "#{url}/fetcher/301"

    page =
      @defaults
      |> Map.merge(%{url: url, req_options: req_options})
      |> Fetcher.fetch()

    assert %Crawler.Store.Page{} = page
    assert page.url == url
    assert page.body == "<html>301_200</html>"
    assert Store.find({url, nil}).body == page.body
  end

  test "failure: 500", %{site: site, url: url, req_options: req_options} do
    url = "#{url}/fetcher/500"

    ReqTestSite.expect_once(site, "GET", "/fetcher/500", fn conn ->
      Plug.Conn.resp(conn, 500, "<html>500</html>")
    end)

    fetcher =
      @defaults
      |> Map.merge(%{url: url, req_options: req_options})
      |> Fetcher.fetch()

    assert fetcher == {:error, "Failed to fetch #{url}, status code: 500"}
    refute Store.find({url, nil})
  end

  test "failure: timeout", %{site: site, url: url, req_options: req_options} do
    url = "#{url}/fetcher/timeout"

    ReqTestSite.expect_once(site, "GET", "/fetcher/timeout", fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    fetcher =
      @defaults
      |> Map.merge(%{url: url, timeout: 50, req_options: req_options})
      |> Fetcher.fetch()

    assert fetcher == {:error, "Failed to fetch #{url}, reason: :timeout"}
    refute Store.find({url, nil})
  end

  test "failure: too many redirects", %{site: site, url: url, req_options: req_options} do
    url = "#{url}/fetcher/too_many_redirects"

    ReqTestSite.expect_once(site, "GET", "/fetcher/too_many_redirects", fn conn ->
      Req.Test.redirect(conn, to: "/fetcher/too_many_redirects")
    end)

    fetcher =
      @defaults
      |> Map.merge(%{url: url, req_options: Keyword.merge(req_options, max_redirects: 0)})
      |> Fetcher.fetch()

    assert fetcher == {:error, "Failed to fetch #{url}, reason: too many redirects (0)"}
    refute Store.find({url, nil})
  end

  test "failure: retries", %{site: site, url: url, req_options: req_options} do
    url = "#{url}/fetcher/retries"
    requests = :counters.new(1, [:atomics])

    ReqTestSite.expect(site, "GET", "/fetcher/retries", fn conn ->
      :counters.add(requests, 1, 1)
      Plug.Conn.resp(conn, 500, "<html>500</html>")
    end)

    fetcher =
      @defaults
      |> Map.merge(%{url: url, timeout: 100, retrier: Retrier, req_options: req_options})
      |> Fetcher.fetch()

    assert fetcher == {:error, "Failed to fetch #{url}, status code: 500"}
    assert :counters.get(requests, 1) == @defaults.retries + 1
    refute Store.find({url, nil})
  end

  test "publication refuses a destination occupied after preparation and preserves its archive",
       %{site: site, url: url, req_options: req_options} do
    url = "#{url}/fetcher/fail.bin"
    scope = unique_scope("fetcher-publication-collision")
    parent = tmp(scope)
    root = Path.join(parent, "archive")
    previous_root = Path.join(parent, "previous")
    requests = :counters.new(1, [:atomics])
    observer = self()
    on_exit(fn -> File.rm_rf(parent) end)

    ReqTestSite.expect(site, "GET", "/fetcher/fail.bin", fn conn ->
      :counters.add(requests, 1, 1)
      body = if :counters.get(requests, 1) == 1, do: "PREVIOUS COMPLETE BODY", else: "NEW BODY"

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.resp(200, body)
    end)

    assert {:ok, previous} =
             stage_copy(
               Map.merge(@defaults, %{
                 url: url,
                 scope: unique_scope("fetcher-previous-archive"),
                 save_to: previous_root,
                 req_options: req_options
               })
             )

    on_exit(fn -> Crawler.stop(previous) end)
    assert {:ok, :committed} = finalize_copy(previous)
    previous_export = ready_export(previous)
    resource = resource_for_url(previous_export, url)
    previous_body = read_resource(previous_export, resource)
    previous_manifest = File.read!(Path.join(previous_root, "manifest.json"))
    assert previous_body == "PREVIOUS COMPLETE BODY"

    assert {:ok, failed} =
             stage_copy(
               Map.merge(@defaults, %{
                 url: url,
                 scope: scope,
                 save_to: root,
                 req_options: req_options
               })
             )

    on_exit(fn -> Crawler.stop(failed) end)

    assert {:error, :destination_exists} =
             finalize_copy(failed, fn %{filesystem: filesystem} ->
               assert File.regular?(Path.join(filesystem.receipt.stage, "archive/manifest.json"))
               refute File.exists?(root)
               File.rename!(previous_root, root)
               send(observer, {:prepared_collision, filesystem})
             end)

    assert_receive {:prepared_collision, filesystem}

    wait(fn ->
      assert {:ok, %{state: :failed, ready?: false, reason: {:snapshot, :destination_exists}}} =
               Crawler.export_status(failed)

      refute Process.alive?(filesystem.filesystem)
      refute File.exists?(filesystem.receipt.stage)
      refute File.exists?(filesystem.receipt.claim)
    end)

    assert File.read!(Path.join(root, "manifest.json")) == previous_manifest
    assert read_resource(%{previous_export | root: root}, resource) == previous_body
    assert :counters.get(requests, 1) == 2
    assert Store.find_processed({url, scope}).body == "NEW BODY"
    assert Store.ops_count(scope) == 1
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
  end

  test "snap /fetcher/page.html", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    url = "#{url}/fetcher/page.html"
    scope = unique_scope("fetcher-snapshot")
    parent = tmp(scope)
    root = Path.join(parent, "archive")
    on_exit(fn -> File.rm_rf(parent) end)

    ReqTestSite.expect_once(site, "GET", "/fetcher/page.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "<html>200</html>")
    end)

    assert {:ok, crawl} =
             start_crawl(url,
               scope: scope,
               workers: 1,
               max_pages: 1,
               store: Store,
               save_to: root,
               req_options: req_options
             )

    export = ready_export(crawl)
    resource = resource_for_url(export, url)
    assert resource["content_type"] == "text/html"
    assert read_resource(export, resource) == <<0xEF, 0xBB, 0xBF, "<html>200</html>">>
    assert Store.find_processed({url, scope}).body == "<html>200</html>"
  end
end
