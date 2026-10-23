defmodule Crawler.StoreTest do
  use ExUnit.Case, async: false

  import Crawler.ManagedSnapshotHelpers
  import Crawler.TestHelpers, only: [wait: 1]

  alias Crawler.Store

  test "a dropped scope keeps its new generation token" do
    scope = scope("generation")

    stale = Store.generation(scope)
    generation = Store.drop_scope(scope)
    refute generation == stale
    assert Store.generation(scope) == generation
    assert Store.try_claim(scope, 1, stale) == :stale
    assert Store.try_claim(scope, 1, generation) == :ok
    assert :ok = Store.finish_work(scope, generation, true)
    assert Store.inflight_count(scope) == 0
  end

  test "a stale export leaves the newer archive and removes private staging" do
    scope = scope("publish")
    root = Path.join([File.cwd!(), "test", "tmp", unique_dir()])
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    old_options = copy_options(scope, "OLD", Path.join(root, "old"))
    assert {:ok, old} = stage_copy(old_options)
    parent = self()

    task =
      Task.async(fn ->
        finalize_copy(old, fn %{filesystem: %{receipt: receipt}} ->
          send(parent, {:staged, self(), receipt})

          receive do
            :release_save -> :ok
          after
            5_000 -> flunk("publication gate was not released")
          end
        end)
      end)

    assert_receive {:staged, holder, receipt}, 2_000
    on_exit(fn -> send(holder, :release_save) end)
    assert File.dir?(receipt.stage)
    generation = Store.drop_scope(scope)
    refute generation == old.generation
    assert {:ok, fresh} = stage_copy(copy_options(scope, "NEW", Path.join(root, "new")))
    assert {:ok, :committed} = finalize_copy(fresh)
    export = ready_export(fresh)
    resource = resource_for_url(export, fresh.url)
    assert read_resource(export, resource) == "NEW"
    send(holder, :release_save)
    assert {:error, _} = Task.await(task, 5_000)

    wait(fn -> refute File.exists?(receipt.stage) end)
    refute File.exists?(old.save_to)
    assert read_resource(export, resource) == "NEW"
    assert ready_export(fresh) == export
  end

  test "an idle queue drops its failed pages and keeps processed pages" do
    scope = scope("sweep")
    generation = Store.generation(scope)
    queue = self()

    assert :ok = Store.note_enqueued(scope, generation, queue)
    assert :ok = Store.note_enqueued(scope, generation, queue)
    assert {:ok, _} = Store.add({"http://kept.example", scope}, generation, queue)
    Store.processed({"http://kept.example", scope}, generation, queue)
    assert {:ok, _} = Store.add({"http://dropped.example", scope}, generation, queue)

    assert :ok = Store.finish_work(scope, generation, false, queue)
    assert Store.find({"http://dropped.example", scope})

    assert :ok = Store.finish_work(scope, generation, false, queue)
    refute Store.find({"http://dropped.example", scope})
    assert Store.find({"http://kept.example", scope})
  end

  test "counter reset and decrement preserve direct unprocessed registrations and bodies" do
    scope = scope("counter-only")
    generation = Store.generation(scope)
    key = {"http://open.example/counter-only", scope}
    opts = %{generation: generation, scope: scope}

    assert {:ok, _} = Store.add(key, generation)
    assert {_, _} = Store.add_page_data(key, "BODY", opts)
    page = Store.find(key)
    assert :ok = Store.ops_inc(scope, generation)
    assert :ok = Store.try_claim(scope, 2, generation)

    assert :ok = Store.inflight_dec(scope, generation)
    assert Store.inflight_count(scope) == 0
    assert Store.find(key) == page

    assert :ok = Store.ops_reset()
    assert Store.ops_count(scope) == 0
    assert Store.find(key) == page
    refute Store.find_processed(key)

    assert :ok = Store.finish_work(scope, generation, false)
    assert Store.find(key) == page
  end

  test "stale workers cannot change a newer scope's pages or counters" do
    scope = scope("stale-work")
    stale = Store.generation(scope)
    generation = Store.drop_scope(scope)
    key = {"http://kept.example/stale-work", scope}

    assert {:ok, _} = Store.add(key, generation)
    assert {_, _} = Store.add_page_data(key, "NEW", %{generation: generation})
    assert :ok = Store.note_enqueued(scope, generation, self())
    assert :ok = Store.try_claim(scope, 2, generation)
    assert :ok = Store.ops_inc(scope, generation)

    assert {:error, :stale} = Store.add(key, stale)
    assert {:error, :stale} = Store.add_page_data(key, "OLD", %{generation: stale})
    assert :stale = Store.processed(key, stale)
    assert :stale = Store.delete(key, stale)
    assert :stale = Store.note_enqueued(scope, stale, self())
    assert :stale = Store.finish_work(scope, stale, true)
    assert :ok = Store.ops_inc(scope, stale)
    assert :ok = Store.inflight_dec(scope, stale)

    assert Store.find(key).body == "NEW"
    refute Store.find_processed(key)
    assert Store.pending_count(scope) == 1
    assert Store.inflight_count(scope) == 1
    assert Store.ops_count(scope) == 1
  end

  test "concurrent claims include processed pages in the page limit" do
    scope = scope("concurrent-claims")
    generation = Store.generation(scope)
    assert :ok = Store.ops_inc(scope, generation)
    assert :ok = Store.ops_inc(scope, generation)

    replies =
      1..20
      |> Task.async_stream(fn _ -> Store.try_claim(scope, 5, generation) end,
        max_concurrency: 20
      )
      |> Enum.map(fn {:ok, reply} -> reply end)
      |> Enum.frequencies()

    assert replies == %{ok: 3, full: 17}
    assert Store.inflight_count(scope) == 3
    assert Store.ops_count(scope) == 2
  end

  test "releasing a queue abandons its exclusive scopes and removes its owner" do
    scope = scope("exclusive-queue")
    generation = Store.generation(scope)
    queue = self()
    kept = {"http://kept.example/exclusive-queue", scope}
    open = {"http://open.example/exclusive-queue", scope}

    assert :ok = Store.attach_owner(queue, self(), scope)
    assert Store.queue_record(queue) == %{owner: self(), scope: scope}
    assert :ok = Store.note_enqueued(scope, generation, queue)
    assert :ok = Store.try_claim(scope, 2, generation, queue)
    assert :ok = Store.ops_inc(scope, generation, queue)
    assert {:ok, _} = Store.add(kept, generation, queue)
    Store.processed(kept, generation, queue)
    assert {:ok, _} = Store.add(open, generation, queue)

    assert :ok = Store.release_queue(queue)

    assert Store.queue_record(queue) == nil
    assert Store.queue_scopes(queue) == []
    refute Store.generation(scope) == generation
    assert Store.inflight_count(scope) == 0
    assert Store.pending_count(scope) == 0
    assert Store.ops_count(scope) == 1
    assert Store.find_processed(kept)
    refute Store.find(open)

    retired_generation = Store.generation(scope)
    assert :ok = Store.release_queue(queue)
    assert Store.generation(scope) == retired_generation
  end

  test "releasing one queue retires only its work in a shared scope" do
    scope = scope("shared-queues")
    generation = Store.generation(scope)
    queue = self()

    other_queue =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(other_queue, :kill) end)
    lost = {"http://open.example/shared-queues-lost", scope}
    kept = {"http://open.example/shared-queues-kept", scope}

    assert :ok = Store.note_enqueued(scope, generation, queue)
    assert :ok = Store.note_enqueued(scope, generation, other_queue)
    assert :ok = Store.try_claim(scope, 2, generation, queue)
    assert :ok = Store.try_claim(scope, 2, generation, other_queue)
    assert {:ok, _} = Store.add(lost, generation, queue)
    assert {:ok, _} = Store.add(kept, generation, other_queue)

    assert :ok = Store.release_queue(queue)

    assert Store.queue_scopes(queue) == []
    assert Store.queue_scopes(other_queue) == [scope]
    assert Store.generation(scope) == generation
    assert Store.inflight_count(scope) == 1
    assert Store.pending_count(scope) == 1
    refute Store.find(lost)
    assert Store.find(kept)

    assert {:ok, _} = Store.add(lost, generation, other_queue)
    assert :stale = Store.delete(lost, generation, queue)
    assert :stale = Store.processed(lost, generation, queue)

    assert {:error, :stale} =
             Store.add_page_data(lost, "late", %{generation: generation, queue: queue})

    assert :stale = Store.try_claim(scope, 2, generation, queue)
    assert :stale = Store.note_enqueued(scope, generation, queue)
    assert :stale = Store.finish_work(scope, generation, true, queue)
    assert :ok = Store.ops_inc(scope, generation, queue)
    assert :ok = Store.inflight_dec(scope, generation, queue)
    assert Store.ops_count(scope) == 0
    assert Store.pending_count(scope) == 1
    assert Store.inflight_count(scope) == 1
    assert Store.find(lost)

    assert :ok = Store.release_queue(other_queue)
    refute Store.generation(scope) == generation
    assert Store.inflight_count(scope) == 0
    assert Store.pending_count(scope) == 0
    refute Store.find(lost)
    refute Store.find(kept)
  end

  test "a retired queue cannot commit an archive in the same generation" do
    scope = scope("queue-publication")
    generation = Store.generation(scope)
    queue = self()

    survivor =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(survivor, :kill) end)
    root = Path.join([File.cwd!(), "test", "tmp", unique_dir()])
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    assert :ok = Store.note_enqueued(scope, generation, queue)
    assert :ok = Store.note_enqueued(scope, generation, survivor)
    assert {:ok, opts} = stage_copy(copy_options(scope, "NEW", Path.join(root, "archive")))

    assert :ok = Store.finish_work(scope, generation, false, queue)
    assert :ok = Store.finish_work(scope, generation, false, survivor)

    assert {:ok, :committed} =
             finalize_copy(opts, fn context ->
               assert :ok = Store.release_queue(queue)
               assert Store.generation(scope) == generation
               refute Crawler.Store.Authority.current?(scope, generation, queue)
               assert Crawler.Store.Authority.current?(scope, generation, survivor)
               refute File.exists?(opts.save_to)

               assert {:error, :stale} =
                        Store.export_commit(
                          Map.put(context.owned, :queue, queue),
                          context.closed.epoch,
                          context.closed.close_token,
                          context.snapshot.seal_token,
                          context.prepared,
                          context.manifest_operation
                        )

               refute File.exists?(opts.save_to)
               assert File.dir?(context.filesystem.receipt.stage)
             end)

    export = ready_export(opts)
    resource = resource_for_url(export, opts.url)
    assert read_resource(export, resource) == "NEW"
    assert Store.generation(scope) == generation
    assert :ok = Store.release_queue(survivor)
  end

  test "completion keeps page counts and owned aliases atomic across queue retirement" do
    scope = scope("completion")
    generation = Store.generation(scope)
    retired = self()

    live =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(live, :kill) end)
    requested = {"http://kept.example/completion", scope}
    alias_url = "http://kept.example/completion-alias"
    alias_key = {alias_url, scope}
    lost = {"http://lost.example/completion", scope}

    assert :ok = Store.note_enqueued(scope, generation, retired)
    assert :ok = Store.note_enqueued(scope, generation, live)
    assert :ok = Store.try_claim(scope, 2, generation, retired)
    assert :ok = Store.try_claim(scope, 2, generation, live)
    assert {:ok, _} = Store.add(lost, generation, retired)
    assert {:ok, _} = Store.add(requested, generation, live)
    assert {:ok, _} = Store.add(alias_key, generation, live)

    assert :ok =
             Store.complete_page({"http://missing.example", scope}, generation, live, alias_url)

    assert Store.ops_count(scope) == 0
    refute Store.find_processed(alias_key)

    assert :ok = Store.complete_page(requested, generation, live, alias_url)
    assert :ok = Store.complete_page(requested, generation, live, alias_url)
    assert Store.ops_count(scope) == 1
    assert Store.find_processed(requested)
    assert Store.find_processed(alias_key)

    assert :ok = Store.release_queue(retired)
    assert {:error, :stale} = Store.complete_page(requested, generation, retired, alias_url)
    assert Store.generation(scope) == generation
    assert Store.ops_count(scope) == 1
    assert Store.find_processed(requested)
    assert Store.find_processed(alias_key)
    refute Store.find(lost)

    assert :ok = Store.finish_work(scope, generation, true, live)
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
    assert :ok = Store.try_claim(scope, 2, generation, live)
    assert :full = Store.try_claim(scope, 2, generation, live)
  end

  defp copy_options(scope, body, destination) do
    [
      url: "http://publication.example/resource",
      scope: scope,
      store: Store,
      save_to: destination,
      respect_robots: false,
      retries: 0,
      max_body: 1024,
      max_analysis_bytes: 2_097_152,
      max_manifest_bytes: 1_048_576,
      req_options: [
        retry: false,
        adapter: fn request ->
          {request,
           Req.Response.new(
             status: 200,
             headers: [{"content-type", "application/octet-stream"}],
             body: body
           )}
        end
      ]
    ]
  end

  defp unique_dir, do: "crawler-publish-#{System.unique_integer([:positive])}"

  defp scope(name) do
    scope = "store-#{name}-#{System.unique_integer([:positive])}"
    on_exit(fn -> Store.drop_scope(scope) end)
    scope
  end
end
