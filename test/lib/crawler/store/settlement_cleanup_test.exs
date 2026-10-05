defmodule Crawler.Store.SettlementCleanupTest do
  use Crawler.TestCase, async: false

  alias Crawler.Queue
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
    source_claim = start_claim(opts)
    assert {:ok, candidate} = Store.retain_alias({landing, scope}, "FALLBACK", opts)
    assert is_reference(candidate)

    failed_claim = start_claim(%{opts | url: failed})
    assert :ok = Store.finish_claim(failed_claim)
    assert Store.find({failed, scope})
    assert :ok = Store.complete_page({source, scope}, generation, source_queue)
    assert :ok = Store.finish_claim(source_claim)
    assert Store.work_pending?(scope, generation, source_queue)

    send(target, :finish)
    assert_receive {:finished, ^target}, 2_000
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

  defp start_claim(opts) do
    assert :ok = Store.note_enqueued(opts.scope, opts.generation, opts.queue)
    assert {:ok, token} = Store.start_work(opts)
    assert {:ok, _} = Store.add({opts.url, opts.scope}, opts.generation, opts.queue)
    token
  end

  defp held_claim(opts, resolution) do
    observer = self()

    worker =
      spawn_link(fn ->
        token = start_claim(opts)
        send(observer, {:claimed, self()})

        receive do
          :finish ->
            finish_landing(opts, resolution)
            Store.finish_claim(token)
            send(observer, {:finished, self()})
        end
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive {:claimed, ^worker}, 2_000
    worker
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
