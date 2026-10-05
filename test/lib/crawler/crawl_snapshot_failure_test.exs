defmodule Crawler.CrawlSnapshotFailureTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers, only: [saved: 2]

  alias Crawler.Store

  test "a raised publication callback clears staged work and permits the first retry", context do
    scope = unique_scope("raised-publication")
    page = context.url <> "/publication/failure.bin"
    root = tmp(scope)
    file = saved(root, page)
    directory = Path.dirname(file)
    observer = self()
    store = Process.whereis(Store)
    requests = :counters.new(1, [:atomics])
    on_exit(fn -> File.rm_rf(root) end)

    ReqTestSite.expect(context.site, "GET", "/publication/failure.bin", fn conn ->
      :counters.add(requests, 1, 1)

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.resp(200, "COMPLETE BODY")
    end)

    before_publish = fn ->
      send(observer, {:staged, File.ls!(directory)})
      raise "publication callback failed"
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, failed} =
                 start_crawl(page,
                   scope: scope,
                   workers: 1,
                   retries: 2,
                   max_pages: 1,
                   store: Store,
                   save_to: root,
                   before_publish: before_publish,
                   req_options: context.req_options
                 )

        assert_receive {:staged, [temp]}, 2_000
        assert String.ends_with?(temp, ".tmp")
        await_idle(failed)
        assert Process.whereis(Store) == store
        assert Process.alive?(failed.queue)
        assert Process.alive?(failed.queue_owner)
        assert Store.generation(scope) == failed.generation
        assert Store.pending_count(scope) == 0
        assert Store.inflight_count(scope) == 0
        assert Store.ops_count(scope) == 0
        assert :counters.get(requests, 1) == 1
        refute Store.find({page, scope})
        refute File.exists?(file)
        assert File.ls!(directory) == []

        retry_opts = Map.delete(failed, :before_publish)
        assert {:ok, retry} = start_crawl(page, retry_opts)
        await_idle(retry)
        assert :counters.get(requests, 1) == 2
        assert Store.find_processed({page, scope}).body == "COMPLETE BODY"
        assert File.read!(file) == "COMPLETE BODY"
        assert File.ls!(directory) == [Path.basename(file)]
        assert Store.ops_count(scope) == 1
        assert Store.pending_count(scope) == 0
        assert Store.inflight_count(scope) == 0
      end)

    assert log =~ "Worker failed for #{page}: RuntimeError"
    assert log =~ "Crawler.Snapper.publish/3"
    refute log =~ "publication callback failed"
  end
end
