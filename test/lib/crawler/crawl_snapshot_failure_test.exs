defmodule Crawler.CrawlSnapshotFailureTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  test "a raised finalizer clears staged work and permits a fresh retry", context do
    scope = unique_scope("raised-publication")
    page = context.url <> "/publication/failure.bin"
    parent = tmp(scope)
    root = Path.join(parent, "archive")
    observer = self()
    store = Process.whereis(Store)
    requests = :counters.new(1, [:atomics])
    on_exit(fn -> File.rm_rf(parent) end)

    ReqTestSite.expect(context.site, "GET", "/publication/failure.bin", fn conn ->
      :counters.add(requests, 1, 1)

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.resp(200, "COMPLETE BODY")
    end)

    assert {:ok, failed} =
             stage_copy(
               url: page,
               scope: scope,
               retries: 2,
               max_pages: 1,
               store: Store,
               save_to: root,
               req_options: context.req_options
             )

    on_exit(fn -> Crawler.stop(failed) end)

    before_commit = fn %{filesystem: filesystem} ->
      assert File.regular?(Path.join(filesystem.receipt.stage, "archive/manifest.json"))
      refute File.exists?(root)
      send(observer, {:prepared_failure, filesystem})
      raise "publication callback failed"
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert_raise RuntimeError, "publication callback failed", fn ->
          finalize_copy(failed, before_commit)
        end

        assert_receive {:prepared_failure, filesystem}

        wait(fn ->
          assert {:ok, %{state: :failed, ready?: false, reason: {:snapshot, :export_failed}}} =
                   Crawler.export_status(failed)

          refute Process.alive?(filesystem.filesystem)
          refute File.exists?(filesystem.receipt.stage)
          refute File.exists?(filesystem.receipt.claim)
        end)

        assert Process.whereis(Store) == store
        assert Process.alive?(store)
        assert Store.current?(scope, failed.generation, failed.queue)
        assert Store.generation(scope) == failed.generation
        assert Store.pending_count(scope) == 0
        assert Store.inflight_count(scope) == 0
        assert Store.ops_count(scope) == 1
        assert :counters.get(requests, 1) == 1
        assert Store.find_processed({page, scope}).body == "COMPLETE BODY"
        refute File.exists?(root)
        assert :ok = Crawler.stop(failed)

        assert {:ok, retry} =
                 start_crawl(page,
                   scope: scope,
                   workers: 1,
                   retries: 2,
                   max_pages: 1,
                   store: Store,
                   save_to: Path.join(parent, "retry"),
                   req_options: context.req_options
                 )

        refute retry.generation == failed.generation
        export = ready_export(retry)
        assert :counters.get(requests, 1) == 2
        assert Store.find_processed({page, scope}).body == "COMPLETE BODY"
        resource = resource_for_url(export, page)
        assert resource["content_type"] == "application/octet-stream"
        assert read_resource(export, resource) == "COMPLETE BODY"
        assert Store.ops_count(scope) == 1
        assert Store.pending_count(scope) == 0
        assert Store.inflight_count(scope) == 0
      end)

    refute log =~ "publication callback failed"
  end
end
