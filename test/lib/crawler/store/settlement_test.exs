defmodule Crawler.Store.SettlementTest do
  use ExUnit.Case, async: false

  import Crawler.TestHelpers

  alias Crawler.Queue
  alias Crawler.Store

  setup do
    scope = unique_scope("settlement-transition")
    owner = start_supervised!({Queue, %{scope: scope, workers: 1, interval: 0, timeout: 5_000}})
    queue = Queue.feeder(owner)
    OPQ.pause(queue)
    on_exit(fn -> Store.drop_scope(scope) end)

    {:ok, %{scope: scope, queue: queue, generation: Store.generation(scope)}}
  end

  test "a queued fallback waits for an intervening landing claim without losing its body",
       context do
    rig = retain_fallback(context)
    finish_source(rig)
    finish_landing(rig)
    assert candidate(rig).status == :queued
    next = claim_worker(rig.target_opts)
    assert :skip = Store.start_settlement(rig.ref)
    assert candidate(rig).status == :waiting
    assert Store.pending_count(context.scope) == 2
    finish_worker(next)
    assert candidate(rig).status == :queued
    OPQ.resume(context.queue)
    await_idle(rig.source_opts)
    assert Store.find_processed({rig.landing, context.scope}).body == "FALLBACK"
    assert Store.ops_count(context.scope) == 1
    assert_idle(context.scope)
  end

  test "an intervening nil-owned registration stays intact", context do
    rig = retain_fallback(context)
    finish_source(rig)
    assert :ok = Store.delete({rig.landing, context.scope}, context.generation, context.queue)
    assert {:ok, _} = Store.add({rig.landing, context.scope}, context.generation)
    Store.add_page_data({rig.landing, context.scope}, "DIRECT", %{scope: context.scope})
    finish_landing(rig)
    assert Store.find({rig.landing, context.scope}).body == "DIRECT"
    refute Store.find_processed({rig.landing, context.scope})
    assert_idle(context.scope)
  end

  test "an unrelated queued registration is not reset before its work settles", context do
    rig = retain_fallback(context)
    finish_source(rig)
    finish_landing(rig)
    assert :ok = Store.delete({rig.landing, context.scope}, context.generation, context.queue)

    other_owner =
      start_supervised!({Queue, %{scope: context.scope, workers: 1, interval: 0, timeout: 5_000}},
        id: :other_settlement_queue
      )

    other = Queue.feeder(other_owner)
    assert :ok = Store.note_enqueued(context.scope, context.generation, other)
    assert {:ok, _} = Store.add({rig.landing, context.scope}, context.generation, other)

    Store.add_page_data({rig.landing, context.scope}, "OTHER", %{
      scope: context.scope,
      generation: context.generation,
      queue: other
    })

    assert :skip = Store.start_settlement(rig.ref)
    assert Store.find({rig.landing, context.scope}).body == "OTHER"
    assert candidate(rig).status == :waiting
    assert :ok = Store.finish_work(context.scope, context.generation, false, other)
    assert candidate(rig).status == :queued
    OPQ.resume(context.queue)
    await_idle(rig.source_opts)
    assert Store.find_processed({rig.landing, context.scope}).body == "FALLBACK"
    assert_idle(context.scope)
  end

  test "a queue-less synchronous source cannot retain asynchronous work", context do
    rig = retain_fallback(context, nil)
    assert rig.ref == nil
    finish_source(rig)
    finish_landing(rig)
    assert Process.alive?(Process.whereis(Store))
    assert_idle(context.scope)
  end

  test "retiring the landing queue promotes a completed fallback on its surviving source queue",
       context do
    queue = another_queue(context)
    rig = retain_fallback(context, queue)
    finish_source(rig)
    Process.exit(context.queue, :kill)
    wait(fn -> assert candidate(rig).status == :queued end)
    assert Store.generation(context.scope) == context.generation
    OPQ.resume(queue)
    await_idle(rig.source_opts)
    assert Store.find_processed({rig.landing, context.scope}).body == "FALLBACK"
    assert_idle(context.scope)
  end

  test "retiring the source queue discards its fallback and preserves the independent claim",
       context do
    queue = another_queue(context)
    rig = retain_fallback(context, queue)
    finish_source(rig)
    Process.exit(queue, :kill)
    wait(fn -> assert :sys.get_state(Store).settlements.candidates == %{} end)
    assert Store.inflight_count(context.scope) == 1
    assert Store.pending_count(context.scope) == 1
    assert Store.find({rig.landing, context.scope})
    finish_landing(rig)
    refute Store.find({rig.landing, context.scope})
    assert Store.find_processed({rig.source_opts.url, context.scope})
    assert_idle(context.scope)
  end

  defp another_queue(context) do
    owner =
      start_supervised!({Queue, %{scope: context.scope, workers: 1, interval: 0, timeout: 5_000}},
        id: :source_settlement_queue
      )

    queue = Queue.feeder(owner)
    OPQ.pause(queue)
    queue
  end

  defp retain_fallback(context, source_queue \\ :default) do
    source_queue = if source_queue == :default, do: context.queue, else: source_queue
    source = "http://example.com/settlement/source"
    landing = "http://example.com/settlement/landing"

    target_opts = %{
      url: landing,
      scope: context.scope,
      generation: context.generation,
      queue: context.queue,
      max_pages: :infinity,
      store: Store
    }

    source_opts = %{target_opts | url: source, queue: source_queue}
    assert :ok = Store.note_enqueued(context.scope, context.generation, context.queue)
    assert {:ok, _} = Store.add({landing, context.scope}, context.generation, context.queue)
    landing_worker = claim_worker(target_opts, false)
    assert :ok = Store.note_enqueued(context.scope, context.generation, source_queue)
    assert {:ok, _} = Store.add({source, context.scope}, context.generation, source_queue)
    assert {:ok, source_claim} = Store.start_work(source_opts)
    assert {:ok, ref} = Store.retain_alias({landing, context.scope}, "FALLBACK", source_opts)

    %{
      ref: ref,
      source_claim: source_claim,
      source_opts: source_opts,
      target_opts: target_opts,
      landing: landing,
      landing_worker: landing_worker
    }
  end

  defp finish_source(rig) do
    opts = rig.source_opts
    Store.complete_page({opts.url, opts.scope}, opts.generation, opts.queue)
    Store.finish_claim(rig.source_claim)
  end

  defp finish_landing(rig), do: finish_worker(rig.landing_worker)

  defp claim_worker(opts, note? \\ true) do
    if note?, do: Store.note_enqueued(opts.scope, opts.generation, opts.queue)
    observer = self()

    worker =
      spawn_link(fn ->
        assert {:ok, token} = Store.start_work(opts)
        send(observer, {:claimed, self()})

        receive do
          :finish ->
            Store.finish_claim(token)
            send(observer, {:finished, self()})
        end
      end)

    assert_receive {:claimed, ^worker}, 2_000
    on_exit(fn -> send(worker, :finish) end)
    worker
  end

  defp finish_worker(worker) do
    send(worker, :finish)
    assert_receive {:finished, ^worker}, 2_000
  end

  defp candidate(rig), do: :sys.get_state(Store).settlements.candidates[rig.ref]

  defp assert_idle(scope) do
    assert Store.inflight_count(scope) == 0
    assert Store.pending_count(scope) == 0
    assert :sys.get_state(Store).settlements.candidates == %{}
  end
end
