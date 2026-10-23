defmodule Crawler.Store.SettlementCleanupTest do
  use Crawler.TestCase, async: false

  alias Crawler.Queue
  alias Crawler.SettlementClaimHelpers
  alias Crawler.Store

  for resolution <- [:processed, :direct_registration] do
    test "discarding a fallback after #{resolution} clears failed source URLs before retry",
         context do
      exercise_discard(unquote(resolution), context)
    end
  end

  defp exercise_discard(resolution, context) do
    scope = unique_scope("settlement-cleanup")
    on_exit(fn -> Store.drop_scope(scope) end)
    source_queue = paused_queue(scope, :source)
    target_queue = paused_queue(scope, :target)
    generation = Store.generation(scope)
    source = context.url <> "/cleanup/source"
    landing = context.url <> "/cleanup/landing"
    failed = context.url <> "/cleanup/failed"

    opts = %{
      scope: scope,
      generation: generation,
      queue: source_queue,
      max_pages: :infinity,
      url: source,
      store: Store
    }

    target_opts = %{opts | queue: target_queue, url: landing}
    target = held_claim(target_opts, resolution)
    source_claim = SettlementClaimHelpers.start_source(context, opts, landing)
    candidate = source_claim.ref
    assert is_reference(candidate)

    failed_claim = start_claim(%{opts | url: failed})
    finish_worker(failed_claim)
    assert Store.find({failed, scope})
    SettlementClaimHelpers.finish_source(source_claim)
    assert Store.work_pending?(scope, generation, source_queue)

    finish_worker(target)
    refute Store.work_pending?(scope, generation, source_queue)
    refute Store.find({failed, scope})
    assert Store.find_processed({source, scope})

    case resolution do
      :processed -> assert Store.find_processed({landing, scope})
      :direct_registration -> assert Store.find({landing, scope}).body == "DIRECT"
    end

    observer = self()

    ReqTestSite.expect_once(context.site, "GET", "/cleanup/failed", fn conn ->
      send(observer, {:retried, self()})

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "RECOVERED")
    end)

    assert {:ok, retry} =
             start_crawl(failed,
               scope: scope,
               queue: source_queue,
               store: Store,
               retries: 0,
               req_options: context.req_options
             )

    assert :ok = Crawler.resume(retry)
    assert_receive {:retried, _handler}, 2_000
    await_idle(retry)
    assert Store.find_processed({failed, scope}).body == "RECOVERED"
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
  end

  defp paused_queue(scope, id) do
    owner =
      start_supervised!({Queue, %{scope: scope, workers: 1, interval: 0, timeout: 5_000}},
        id: id
      )

    queue = Queue.feeder(owner)
    OPQ.pause(queue)
    queue
  end

  defp start_claim(opts, resolution \\ nil) do
    opts =
      opts
      |> Map.merge(%{max_body: 1_024, max_analysis_bytes: 2_097_152, respect_robots: false})
      |> Crawler.Options.assign_defaults()

    assert {:ok, prepared} = Crawler.Fetcher.Requester.prepare(opts)
    assert {:ok, _admitted} = Store.admit_job(opts, prepared)
    observer = self()

    worker =
      spawn_link(fn ->
        {:ok, claim, :fetch, admitted} =
          wait(fn -> assert {:ok, _, :fetch, _} = Store.checkout_job(opts.queue) end)

        assert :ok =
                 Crawler.Store.Execution.run(admitted, fn owned ->
                   assert {:ok, _} =
                            Store.add({owned.url, owned.scope}, owned.generation, owned.queue)

                   :ok
                 end)

        send(observer, {:claimed, self()})

        receive do
          :finish ->
            if resolution, do: finish_landing(opts, resolution)
            Store.complete_job(claim, Crawler.Job.Outcome.new(:failed, :fixture_finished))
            send(observer, {:finished, self(), claim})
        end
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive {:claimed, ^worker}, 2_000
    worker
  end

  defp held_claim(opts, resolution), do: start_claim(opts, resolution)

  defp finish_worker(worker) do
    monitor = Process.monitor(worker)
    send(worker, :finish)
    assert_receive {:finished, ^worker, claim}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    wait(fn -> refute Map.has_key?(:sys.get_state(Store).scheduler_workers, claim) end)
  end

  defp finish_landing(opts, :processed) do
    Store.complete_page({opts.url, opts.scope}, opts.generation, opts.queue)
  end

  defp finish_landing(opts, :direct_registration) do
    key = {opts.url, opts.scope}
    Store.delete(key, opts.generation, opts.queue)
    Store.add(key, opts.generation)
    Store.add_page_data(key, "DIRECT", %{scope: opts.scope, generation: opts.generation})
  end
end
