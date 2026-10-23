defmodule Crawler.WorkerClaimTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  defmodule LinkedExitScraper do
    @moduledoc false
    @behaviour Crawler.Scraper.Spec

    def scrape(%{body: "linked exit", opts: opts} = page) do
      child =
        spawn_link(fn ->
          receive do
            :crash -> exit(:linked_scraper_failure)
          end
        end)

      send(opts[:probe], {:scraper_waiting, self(), child})

      receive do
        :continue -> {:ok, page}
      end
    end

    def scrape(page), do: {:ok, page}
  end

  defmodule ProvisionalParser do
    @moduledoc false
    @behaviour Crawler.Parser.Spec

    def parse(%{opts: opts} = page) do
      :ok = Store.complete_page({page.url, opts.scope}, opts.generation, opts.queue, nil, false)
      send(opts.probe, {:provisional_page, self(), page.url})

      receive do
        :limit -> {:error, {:limit, :max_retained_bytes}}
        :release -> Crawler.Parser.parse(page)
      end
    end

    def parse(other), do: Crawler.Parser.parse(other)
  end

  for event <- [:linked_exit, :kill] do
    test "#{event} releases the worker claim while the feeder stays alive", context do
      ExUnit.CaptureLog.capture_log(fn -> exercise_worker_exit(unquote(event), context) end)
    end
  end

  for event <- [:limit, :kill] do
    test "a provisionally processed Page releases its cleanup custody after #{event}", context do
      ExUnit.CaptureLog.capture_log(fn ->
        exercise_provisional_failure(unquote(event), context)
      end)
    end
  end

  test "duplicate completion and late DOWN release one canonical claim only", context do
    scope = unique_scope("finished-claim")
    on_exit(fn -> Store.drop_scope(scope) end)
    generation = Store.generation(scope)
    finished = canonical_claim(context, scope, generation, self(), "/claim/finished")
    active = canonical_claim(context, scope, generation, self(), "/claim/active")

    finish_canonical_claim(finished)
    assert {:error, :stale} = Store.complete_job(finished.claim, Crawler.Job.Outcome.new(:failed))
    send(Store, {:DOWN, finished.monitor, :process, finished.worker, :normal})
    assert Store.pending_count(scope) == 1
    assert Store.inflight_count(scope) == 1
    assert Store.ops_count(scope) == 0

    outsider =
      Task.async(fn -> Store.complete_job(active.claim, Crawler.Job.Outcome.new(:failed)) end)

    assert {:error, :stale} = Task.await(outsider)
    assert Store.pending_count(scope) == 1
    assert Store.inflight_count(scope) == 1
    finish_canonical_claim(active)
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
  end

  for event <- [:drop_scope, :retire_queue] do
    test "#{event} cancels its claims without touching fresh work", context do
      exercise_retired_claim(unquote(event), context)
    end
  end

  defp exercise_worker_exit(event, %{site: site, url: url, req_options: req_options}) do
    scope = unique_scope("worker-#{event}")
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    failed_key = {url <> "/claim/failure", scope}
    sibling_key = {url <> "/claim/sibling", scope}
    direct_key = {url <> "/claim/direct", scope}

    ReqTestSite.expect(site, "GET", "/claim/failure", fn conn ->
      Agent.update(attempts, &(&1 + 1))

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "linked exit")
    end)

    ReqTestSite.expect_once(site, "GET", "/claim/sibling", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "sibling")
    end)

    {:ok, owner} =
      start_crawl(elem(failed_key, 0),
        scope: scope,
        workers: 2,
        max_pages: 1,
        scraper: LinkedExitScraper,
        probe: self(),
        store: Store,
        retries: 0,
        req_options: req_options
      )

    on_exit(fn -> Crawler.stop(owner) end)
    assert_receive {:scraper_waiting, worker, child}, 2_000
    on_exit(fn -> Process.exit(child, :kill) end)
    ref = Process.monitor(worker)
    failed = Store.find(failed_key)
    assert failed.body == "linked exit"
    failed_resources = page_resources(failed)
    assert is_reference(failed.opts.page_resource)

    for receipt <- failed_resources do
      assert MapSet.member?(:sys.get_state(Store).persistent_resources, receipt)
    end

    assert {:ok, _} = Store.add(direct_key, owner[:generation])

    assert {_, _} =
             Store.add_page_data(direct_key, "DIRECT", %{generation: owner[:generation]})

    direct = Store.find(direct_key)
    assert {:ok, sibling} = start_crawl(elem(sibling_key, 0), owner)

    wait(fn ->
      assert Store.pending_count(scope) == 2
      assert Store.inflight_count(scope) == 1
      assert {:normal, %OPQ.Queue{data: data}, _} = OPQ.info(owner[:queue])
      assert :queue.is_empty(data)
    end)

    reason = stop_worker(event, worker, child)
    assert_receive {:DOWN, ^ref, :process, ^worker, ^reason}, 2_000
    assert Process.alive?(owner[:queue])
    assert Process.alive?(owner[:queue_owner])
    await_idle(sibling)
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
    assert Store.ops_count(scope) == 1
    assert Store.find_processed(sibling_key)
    refute Store.find(failed_key)
    assert Store.find(direct_key) == direct

    wait(fn ->
      state = :sys.get_state(Store)
      assert_page_unindexed(state, scope, failed_resources)
      refute state.resources.receipts[failed.opts.page_resource]
      assert Store.find_processed(sibling_key)
      assert Store.find(direct_key) == direct
    end)

    retry_opts = owner |> Map.put(:max_pages, 2) |> Map.put(:scraper, Crawler.Scraper)
    assert {:ok, retry} = start_crawl(elem(failed_key, 0), retry_opts)
    await_idle(retry)
    assert Agent.get(attempts, & &1) == 1
    assert Store.find_processed(failed_key)
    assert Store.find_processed(sibling_key)
    assert Store.find(direct_key) == direct
    assert Store.ops_count(scope) == 2
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
  end

  defp stop_worker(:linked_exit, _worker, child) do
    send(child, :crash)
    :linked_scraper_failure
  end

  defp stop_worker(:kill, worker, _child) do
    Process.exit(worker, :kill)
    :killed
  end

  defp exercise_provisional_failure(event, context) do
    {owner, root_worker, sibling_worker, root_key, sibling_key} = provisional_pair(context)
    root = Store.find_processed(root_key)
    resources = page_resources(root)
    assert root.body == "PROVISIONAL ROOT"
    assert is_reference(root.opts.page_resource)
    assert Store.target_outcome(root.target_handle) == nil

    assert Crawler.Store.State.page_owner(:sys.get_state(Store), root_key) ==
             {:owned, owner.queue}

    assert_no_fallback(owner.scope)
    monitor = Process.monitor(root_worker)
    stop_provisional(event, root_worker)
    assert_receive {:DOWN, ^monitor, :process, ^root_worker, reason}, 2_000
    assert reason == if(event == :kill, do: :killed, else: :normal)

    wait(fn ->
      expected = if event == :kill, do: :failed, else: :limited
      assert %{status: ^expected} = Store.target_outcome(root.target_handle)
      assert Store.pending_count(owner.scope) == 1
      assert Store.inflight_count(owner.scope) == 1
    end)

    if event == :limit do
      assert %{reason: {:limit, :max_retained_bytes}} = Store.target_outcome(root.target_handle)
    end

    assert Store.find_processed(root_key) === root

    assert Crawler.Store.State.page_owner(:sys.get_state(Store), root_key) ==
             {:owned, owner.queue}

    assert Store.ops_count(owner.scope) == 0
    assert_no_fallback(owner.scope)
    assert_persistent_page(owner.scope, resources)
    send(sibling_worker, :release)
    await_idle(owner)
    assert Store.pending_count(owner.scope) == 0
    assert Store.inflight_count(owner.scope) == 0
    assert Store.ops_count(owner.scope) == 1
    assert %{body: "SUCCESSFUL SIBLING"} = sibling = Store.find_processed(sibling_key)
    assert %{status: :succeeded} = Store.target_outcome(sibling.target_handle)
    assert_persistent_page(owner.scope, page_resources(sibling))
    refute Store.find(root_key)
    refute Store.find_processed(root_key)
    assert_no_fallback(owner.scope)

    wait(fn ->
      state = :sys.get_state(Store)
      assert_page_unindexed(state, owner.scope, resources)
      refute state.resources.receipts[root.opts.page_resource]
      assert Store.find_processed(sibling_key) === sibling
    end)
  end

  defp provisional_pair(%{site: site, url: url, req_options: req_options}) do
    root_key = {url <> "/claim/provisional-root", unique_scope("provisional-claim")}
    sibling_key = {url <> "/claim/provisional-sibling", elem(root_key, 1)}

    for {key, body} <- [{root_key, "PROVISIONAL ROOT"}, {sibling_key, "SUCCESSFUL SIBLING"}] do
      ReqTestSite.expect_once(site, "GET", URI.parse(elem(key, 0)).path, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.resp(200, body)
      end)
    end

    assert {:ok, owner} =
             start_crawl(elem(root_key, 0),
               scope: elem(root_key, 1),
               workers: 2,
               max_pages: 3,
               max_body: 1_024,
               max_analysis_bytes: 2_097_152,
               parser: ProvisionalParser,
               probe: self(),
               store: Store,
               respect_robots: false,
               retries: 0,
               req_options: req_options
             )

    on_exit(fn -> Crawler.stop(owner) end)
    root_url = elem(root_key, 0)
    assert_receive {:provisional_page, root_worker, ^root_url}, 2_000
    assert {:ok, _sibling} = start_crawl(elem(sibling_key, 0), owner)
    sibling_url = elem(sibling_key, 0)
    assert_receive {:provisional_page, sibling_worker, ^sibling_url}, 2_000
    {owner, root_worker, sibling_worker, root_key, sibling_key}
  end

  defp stop_provisional(:kill, worker), do: Process.exit(worker, :kill)
  defp stop_provisional(:limit, worker), do: send(worker, :limit)

  defp assert_no_fallback(scope) do
    refute Enum.any?(:sys.get_state(Store).settlements.candidates, fn {_ref, candidate} ->
             elem(candidate.key, 1) === scope
           end)
  end

  defp assert_persistent_page(scope, resources) do
    state = :sys.get_state(Store)

    for receipt <- resources do
      assert state.persistent_counts[receipt] == {1, 0}
      assert MapSet.member?(state.persistent_resources, receipt)
      assert retained_resource?(state, scope, receipt)
      assert Map.has_key?(state.resources.receipts[receipt].holders, Process.whereis(Store))
    end
  end

  defp assert_page_unindexed(state, scope, resources) do
    for receipt <- resources do
      refute Map.has_key?(state.persistent_counts, receipt)
      refute MapSet.member?(state.persistent_resources, receipt)
      refute retained_resource?(state, scope, receipt)
    end
  end

  defp exercise_retired_claim(event, %{url: url} = context) do
    scope = unique_scope("retired-claim-#{event}")
    on_exit(fn -> Store.drop_scope(scope) end)
    generation = Store.generation(scope)
    old_queue = idle_queue()
    direct_key = {url <> "/claim/direct", scope}
    assert {:ok, _} = Store.add(direct_key, generation)
    stale = canonical_claim(context, scope, generation, old_queue, "/claim/retired")

    case event do
      :drop_scope -> refute Store.drop_scope(scope) == generation
      :retire_queue -> assert :ok = Store.release_queue(old_queue)
    end

    if event == :retire_queue do
      assert Store.generation(scope) == generation
      assert Store.find(direct_key)
    end

    queue = idle_queue()
    generation = Store.generation(scope)
    active = canonical_claim(context, scope, generation, queue, "/claim/fresh")
    send(Store, {:DOWN, stale.monitor, :process, stale.worker, :killed})
    assert {:error, :stale} = Store.complete_job(stale.claim, Crawler.Job.Outcome.new(:failed))
    assert Store.current?(scope, generation, queue)
    assert Store.pending_count(scope) == 1
    assert Store.inflight_count(scope) == 1
    assert Store.ops_count(scope) == 0

    finish_canonical_claim(active)
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
  end

  defp canonical_claim(context, scope, generation, queue, path) do
    opts =
      Crawler.Options.assign_defaults(%{
        url: context.url <> path,
        scope: scope,
        generation: generation,
        queue: queue,
        max_pages: 3,
        max_body: 1_024,
        max_analysis_bytes: 2_097_152,
        respect_robots: false,
        req_options: context.req_options
      })

    assert {:ok, prepared} = Crawler.Fetcher.Requester.prepare(opts)
    assert {:ok, _admitted} = Store.admit_job(opts, prepared)
    observer = self()

    worker =
      spawn(fn ->
        {:ok, claim, :fetch, admitted} =
          wait(fn -> assert {:ok, _, :fetch, _} = Store.checkout_job(queue) end)

        assert :ok = Crawler.Store.Execution.run(admitted, fn _owned -> :ok end)
        send(observer, {:canonical_claim, self(), claim})

        receive do
          :finish ->
            assert :ok = Store.complete_job(claim, Crawler.Job.Outcome.new(:failed))
            send(observer, {:canonical_finished, self()})
        end
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive {:canonical_claim, ^worker, claim}, 2_000
    monitor = :sys.get_state(Store).scheduler_workers[claim].monitor
    %{worker: worker, claim: claim, monitor: monitor}
  end

  defp finish_canonical_claim(claim) do
    monitor = Process.monitor(claim.worker)
    send(claim.worker, :finish)
    assert_receive {:canonical_finished, worker} when worker == claim.worker
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    wait(fn -> refute Map.has_key?(:sys.get_state(Store).scheduler_workers, claim.claim) end)
  end

  defp idle_queue do
    queue =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(queue, :kill) end)
    queue
  end

  defp page_resources(page) do
    [page.opts[:page_resource], page.opts[:body_resource]]
    |> Enum.filter(&is_reference/1)
    |> Enum.uniq()
  end

  defp retained_resource?(state, scope, receipt) do
    ring = Map.get(state.retained_pages, scope, Crawler.Frontier.Ring.new())
    Map.has_key?(ring.members, receipt)
  end
end
