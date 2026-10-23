defmodule Crawler.Store.PageCandidatesTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store
  alias Crawler.Store.ResourceManager

  defmodule GatedParser do
    @behaviour Crawler.Parser.Spec

    def parse(%{opts: %{candidate_hold: true} = opts} = page) do
      retain_for_holder(page, opts[:candidate_holder])
      send(opts.candidate_observer, {:candidate_held, self(), page})
      await_result(page)
    end

    def parse(other), do: Crawler.Parser.parse(other)

    defp await_result(page) do
      receive do
        :candidate_failure ->
          {:error, :bad_variant}

        :candidate_success ->
          Crawler.Parser.parse(page)

        :process_candidate ->
          opts = page.opts

          :ok =
            Store.complete_page(
              {page.url, opts.scope},
              opts.generation,
              opts.queue,
              opts[:alias_url],
              false
            )

          send(opts.candidate_observer, {:candidate_processed, self()})
          await_result(page)
      end
    end

    defp retain_for_holder(_page, nil), do: :ok

    defp retain_for_holder(page, holder) do
      receipt = page.opts.page_resource
      :ok = Store.retain_resource(receipt, holder)
      {:ok, _} = Store.deliver_resource(receipt, holder, page.body)
    end
  end

  test "a failing queued interpretation preserves the accepted Page and paid references",
       context do
    rig = accepted_page(context)
    variant = start_variant(rig)
    assert_accepted(rig)
    assert_candidate_retained(variant)

    fixed_page = %Store.Page{
      processed: true,
      target_handle: make_ref(),
      storage_revision: make_ref()
    }

    fixed_candidate = %{key: {nil, nil}, expected: make_ref(), page: fixed_page}

    assert {:ok, fixed_bytes} =
             Crawler.Store.Retained.bytes(
               %{source_page: fixed_candidate, alias_page: fixed_candidate},
               8_192
             )

    assert fixed_bytes <= 8_192
    state = :sys.get_state(Store)
    assert state.scheduler.frontier.jobs[variant.opts.target_handle].charge.metadata >= 8_192
    finish_variant(variant, :failure)
    await_idle(rig.opts)
    assert_accepted(rig)
    assert_counts_restored(rig)
    assert_candidate_released(variant)
    assert :counters.get(rig.hits, 1) == 1
  end

  test "a failing direct interpretation preserves the accepted Page", context do
    rig = accepted_page(context)
    observer = self()
    options = Map.merge(rig.opts, %{queue: nil, style_group: make_ref()})

    assert {:error, :bad_direct_variant} =
             Crawler.Store.Execution.run_job(options, fn owned ->
               assert %Store.Page{} = page = Crawler.Fetcher.fetch(owned)
               assert_accepted(rig)
               receipt = page.opts.page_resource
               assert :sys.get_state(Store).persistent_counts[receipt] == {0, 1}
               send(observer, {:direct_candidate_failed, owned.target_handle, receipt})
               {:error, :bad_direct_variant}
             end)

    assert_receive {:direct_candidate_failed, target, receipt}, 2_000
    assert %{status: :failed, reason: :bad_direct_variant} = Store.target_outcome(target)

    wait(fn ->
      state = :sys.get_state(Store)
      assert_accepted(rig)
      assert_counts_restored(rig)
      refute Map.has_key?(state.persistent_counts, receipt)
      refute Map.has_key?(state.resources.receipts, receipt)
    end)

    assert :counters.get(rig.hits, 1) == 1
  end

  test "a successful queued interpretation promotes only after canonical acceptance", context do
    rig = accepted_page(context)
    variant = start_variant(rig)
    assert_accepted(rig)
    send(variant.worker, :process_candidate)
    worker = variant.worker
    assert_receive {:candidate_processed, ^worker}, 2_000
    assert Store.target_outcome(variant.opts.target_handle) == nil
    assert_accepted(rig)
    assert_candidate_retained(variant)
    finish_variant(variant, :success)
    await_idle(rig.opts)
    promoted = Store.find_processed(rig.key)
    assert promoted.body == rig.page.body
    assert promoted.target_handle === variant.opts.target_handle
    assert promoted.opts.style_group === variant.opts.style_group
    refute promoted.storage_revision === rig.page.storage_revision
    assert Store.ops_count(rig.opts.scope) == 1
    assert :counters.get(rig.hits, 1) == 1
    assert_persistent(promoted)
  end

  for first_result <- [:failure, :success] do
    test "concurrent candidates preserve the accepted revision after first #{first_result}",
         context do
      rig = accepted_page(context)
      first = start_variant(rig)
      second = start_variant(rig)
      assert_accepted(rig)
      finish_variant(first, unquote(first_result))
      before_second = Store.find_processed(rig.key)
      finish_variant(second, :success)
      await_idle(rig.opts)
      after_second = Store.find_processed(rig.key)

      if unquote(first_result) == :failure do
        assert before_second === rig.page
        assert after_second.target_handle === second.opts.target_handle
        assert after_second.opts.style_group === second.opts.style_group
      else
        assert before_second.target_handle === first.opts.target_handle
        assert after_second === before_second
        assert_candidate_released(second)
      end

      assert Store.ops_count(rig.opts.scope) == 1
      assert :counters.get(rig.hits, 1) == 1
      assert_persistent(after_second)
    end
  end

  for mutation <- [:delete, :replace, :recreate] do
    test "public #{mutation} prevents promotion of an older queued candidate", context do
      rig = accepted_page(context)
      variant = start_variant(rig)
      replacement = mutate_page(rig, unquote(mutation))
      finish_variant(variant, :success)
      await_idle(rig.opts)
      assert Store.find(rig.key) === replacement
      assert Store.find_processed(rig.key) === replacement
      assert_candidate_released(variant)
      assert Store.ops_count(rig.opts.scope) == 1
      assert :counters.get(rig.hits, 1) == 1
    end
  end

  test "reset retires a held candidate without changing the fresh generation's accepted Page",
       context do
    rig = accepted_page(context)
    variant = start_variant(rig)
    assert_accepted(rig)
    assert_candidate_retained(variant)
    assert :counters.get(rig.hits, 1) == 1
    worker = variant.worker
    monitor = Process.monitor(worker)

    ReqTestSite.expect_once(context.site, "GET", URI.parse(rig.opts.url).path, fn conn ->
      :counters.add(rig.hits, 1, 1)

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "<p>FRESH GENERATION</p>")
    end)

    assert {:ok, fresh} =
             start_crawl(
               rig.opts.url,
               Map.merge(rig.opts, %{
                 force: true,
                 style_group: make_ref(),
                 candidate_hold: false
               })
             )

    on_exit(fn -> Crawler.stop(fresh) end)
    refute fresh.generation === rig.opts.generation
    await_idle(fresh)
    assert %{status: :succeeded} = Store.target_outcome(fresh.target_handle)
    accepted = Store.find_processed(rig.key)
    assert accepted.body == "<p>FRESH GENERATION</p>"
    assert accepted.target_handle === fresh.target_handle
    assert accepted.opts.generation === fresh.generation
    refute accepted.storage_revision === rig.page.storage_revision
    refs = ResourceManager.page_receipts(accepted.opts)
    counts = Map.take(:sys.get_state(Store).persistent_counts, MapSet.to_list(refs))
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000

    wait(fn ->
      state = :sys.get_state(Store)
      refute Map.has_key?(state.scheduler_workers, variant.page.opts.scheduler_claim)
      assert_candidate_released(variant)
      assert Store.find_processed(rig.key) === accepted
      assert Map.take(state.persistent_counts, Map.keys(counts)) === counts
      assert Store.ops_count(fresh.scope) == 1
      assert_persistent(accepted)
    end)

    assert :counters.get(rig.hits, 1) == 2
  end

  for retirement <- [:queue, :deadline] do
    test "#{retirement} retirement keeps the accepted Page while reclaiming its candidate",
         context do
      rig =
        accepted_page(context,
          run_timeout: if(unquote(retirement) == :deadline, do: 2_000, else: 30_000)
        )

      variant = start_variant(rig)
      assert_accepted(rig)
      assert_candidate_retained(variant)
      monitor = Process.monitor(variant.worker)

      if unquote(retirement) == :queue do
        assert :ok = Crawler.Queue.stop(rig.opts.queue_owner)
      end

      worker = variant.worker
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000

      wait(fn ->
        assert_accepted(rig)
        assert_counts_restored(rig)
        assert_candidate_released(variant)

        if unquote(retirement) == :deadline do
          scope = :sys.get_state(Store).scopes[rig.opts.scope]
          assert scope.run_deadline === rig.opts.run_deadline
          assert {:error, {:deadline, :run}} = Crawler.Deadline.check(rig.opts.run_deadline)
          assert scope.outcome == {:limited, {:deadline, :run}}

          assert %{status: :limited, reason: {:deadline, :run}} =
                   Store.target_outcome(variant.opts.target_handle)
        end
      end)
    end
  end

  test "failed candidate cleanup preserves an independent funded receipt holder", context do
    rig = accepted_page(context)
    observer = self()
    holder = spawn(fn -> hold_receipt(observer) end)
    on_exit(fn -> Process.exit(holder, :kill) end)
    variant = start_variant(rig, candidate_holder: holder)
    receipt = variant.page.opts.page_resource
    assert_receive {:candidate_receipt_held, ^holder, ^receipt}, 2_000
    assert_candidate_retained(variant)
    finish_variant(variant, :failure)
    await_idle(rig.opts)
    assert_accepted(rig)

    wait(fn ->
      state = :sys.get_state(Store)
      assert_candidate_unindexed(state, variant)
      record = state.resources.receipts[receipt]
      assert Map.keys(record.holders) == [holder]
      assert record.holders[holder].status == :adopted
      assert state.resources.used >= record.actual
      assert record.actual > 0
      assert :ets.lookup(Crawler.Store.Resources, {:grant, receipt, Process.whereis(Store)}) == []
    end)

    monitor = Process.monitor(holder)
    send(holder, :drop)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}, 2_000
    wait(fn -> assert_candidate_released(variant) end)
    assert_counts_restored(rig)
  end

  defp accepted_page(context, extra \\ []) do
    path = "/page-candidates"
    url = context.url <> path
    hits = :counters.new(1, [:atomics])

    ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
      :counters.add(hits, 1, 1)

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "<p>SHARED SOURCE</p>")
    end)

    assert {:ok, opts} =
             start_crawl(
               url,
               Keyword.merge(
                 [
                   scope: unique_scope("page-candidates"),
                   workers: 3,
                   max_body: 1_024,
                   max_analysis_bytes: 2_097_152,
                   respect_robots: false,
                   retries: 0,
                   parser: GatedParser,
                   store: Store,
                   style_group: make_ref(),
                   candidate_hold: false,
                   candidate_observer: self(),
                   req_options: context.req_options
                 ],
                 extra
               )
             )

    on_exit(fn -> Crawler.stop(opts) end)
    await_idle(opts)
    assert %{status: :succeeded} = Store.target_outcome(opts.target_handle)
    key = {url, opts.scope}
    page = Store.find_processed(key)
    assert page.body == "<p>SHARED SOURCE</p>"
    assert is_reference(page.storage_revision)
    assert Store.ops_count(opts.scope) == 1
    refs = ResourceManager.page_receipts(page.opts)
    counts = Map.take(:sys.get_state(Store).persistent_counts, MapSet.to_list(refs))
    assert map_size(counts) == MapSet.size(refs)
    %{key: key, opts: opts, page: page, refs: refs, counts: counts, hits: hits}
  end

  defp start_variant(rig, extra \\ []) do
    options =
      rig.opts
      |> Map.merge(%{style_group: make_ref(), candidate_hold: true})
      |> Map.merge(Map.new(extra))

    assert {:ok, opts} = start_crawl(rig.opts.url, options)
    assert_receive {:candidate_held, worker, page}, 2_000
    on_exit(fn -> send(worker, :candidate_failure) end)
    assert opts.target_handle === page.target_handle
    refute opts.target_handle === rig.opts.target_handle
    refute page.opts.page_resource === rig.page.opts.page_resource
    %{opts: opts, worker: worker, page: page}
  end

  defp finish_variant(variant, result) do
    worker = variant.worker
    monitor = Process.monitor(worker)
    send(worker, if(result == :success, do: :candidate_success, else: :candidate_failure))
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    expected = if result == :success, do: :succeeded, else: :failed

    wait(fn ->
      assert %{status: ^expected} = Store.target_outcome(variant.opts.target_handle)

      refute Map.has_key?(
               :sys.get_state(Store).scheduler_workers,
               variant.page.opts.scheduler_claim
             )
    end)
  end

  defp assert_accepted(rig) do
    assert Store.find_processed(rig.key) === rig.page
    assert Store.ops_count(rig.opts.scope) == 1
    state = :sys.get_state(Store)

    for receipt <- rig.refs do
      {ordinary, issued} = state.persistent_counts[receipt]
      {accepted_ordinary, accepted_issued} = rig.counts[receipt]
      assert ordinary == accepted_ordinary
      assert issued >= accepted_issued
      assert MapSet.member?(state.persistent_resources, receipt)
      assert Map.has_key?(state.resources.receipts[receipt].holders, Process.whereis(Store))
    end
  end

  defp assert_counts_restored(rig) do
    assert Map.take(:sys.get_state(Store).persistent_counts, Map.keys(rig.counts)) === rig.counts
  end

  defp assert_candidate_retained(variant) do
    state = :sys.get_state(Store)
    receipt = variant.page.opts.page_resource
    assert state.persistent_counts[receipt] == {0, 1}
    assert MapSet.member?(state.persistent_resources, receipt)
    assert Map.has_key?(state.resources.receipts[receipt].holders, Process.whereis(Store))
    ring = Map.get(state.retained_pages, variant.opts.scope, Crawler.Frontier.Ring.new())
    refute Map.has_key?(ring.members, receipt)
  end

  defp assert_candidate_unindexed(state, variant) do
    receipt = variant.page.opts.page_resource
    refute Map.has_key?(state.persistent_counts, receipt)
    refute MapSet.member?(state.persistent_resources, receipt)
    ring = Map.get(state.retained_pages, variant.opts.scope, Crawler.Frontier.Ring.new())
    refute Map.has_key?(ring.members, receipt)
  end

  defp assert_candidate_released(variant) do
    state = :sys.get_state(Store)
    assert_candidate_unindexed(state, variant)
    receipt = variant.page.opts.page_resource
    refute Map.has_key?(state.resources.receipts, receipt)
    assert :ets.lookup(Crawler.Store.Resources, {:grant, receipt, Process.whereis(Store)}) == []
  end

  defp assert_persistent(page) do
    state = :sys.get_state(Store)

    for receipt <- ResourceManager.page_receipts(page.opts) do
      {ordinary, _issued} = state.persistent_counts[receipt]
      assert ordinary > 0
      assert MapSet.member?(state.persistent_resources, receipt)
      assert Map.has_key?(state.resources.receipts[receipt].holders, Process.whereis(Store))
    end
  end

  defp mutate_page(rig, :delete) do
    assert :ok = Store.delete(rig.key, rig.opts.generation, rig.opts.queue)
    refute Store.find(rig.key)
    nil
  end

  defp mutate_page(rig, :replace) do
    public_opts = %{generation: rig.opts.generation, queue: rig.opts.queue}
    assert {replacement, previous} = Store.add_page_data(rig.key, "PUBLIC", public_opts)
    assert previous === rig.page
    assert replacement.body == "PUBLIC"
    assert replacement.opts === public_opts
    refute replacement.storage_revision === previous.storage_revision
    assert Store.find_processed(rig.key) === replacement
    replacement
  end

  defp mutate_page(rig, :recreate) do
    assert :ok = Store.delete(rig.key, rig.opts.generation, rig.opts.queue)
    assert {:ok, _} = Store.add(rig.key, rig.opts.generation, rig.opts.queue)
    inserted = Store.find(rig.key)
    assert is_reference(inserted.storage_revision)
    refute inserted.storage_revision === rig.page.storage_revision
    public_opts = %{generation: rig.opts.generation, queue: rig.opts.queue}
    assert {written, ^inserted} = Store.add_page_data(rig.key, "RECREATED", public_opts)
    refute written.storage_revision === inserted.storage_revision
    assert {_, _} = Store.processed(rig.key, rig.opts.generation, rig.opts.queue)
    recreated = Store.find_processed(rig.key)
    assert recreated.body == "RECREATED"
    assert recreated.storage_revision === written.storage_revision
    recreated
  end

  defp hold_receipt(observer) do
    receive do
      {:crawler_resource_delivery, receipt, _lease, _reply, _ref, body} ->
        send(Store, {:crawler_resource_adopted, receipt, self()})
        _ = :sys.get_state(Store)
        send(observer, {:candidate_receipt_held, self(), receipt})

        receive do
          :drop -> byte_size(body)
        end
    end
  end
end
