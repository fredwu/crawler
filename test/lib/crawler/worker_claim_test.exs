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

  for event <- [:linked_exit, :kill] do
    test "#{event} releases the worker claim while the feeder stays alive", context do
      ExUnit.CaptureLog.capture_log(fn -> exercise_worker_exit(unquote(event), context) end)
    end
  end

  test "duplicate completion and late DOWN release one token only" do
    scope = unique_scope("finished-claim")
    on_exit(fn -> Store.drop_scope(scope) end)
    opts = %{scope: scope, generation: Store.generation(scope), queue: self(), max_pages: 3}
    assert :ok = Store.note_enqueued(scope, opts[:generation], self())
    assert :ok = Store.note_enqueued(scope, opts[:generation], self())
    assert {:ok, finished} = Store.start_work(opts)
    assert {:ok, active} = Store.start_work(opts)

    assert :ok = Store.finish_claim(finished)
    assert :ok = Store.finish_claim(finished)
    send(Store, {:DOWN, finished, :process, self(), :normal})
    assert Store.pending_count(scope) == 1
    assert Store.inflight_count(scope) == 1
    assert Store.ops_count(scope) == 0

    outsider = Task.async(fn -> Store.finish_claim(active) end)
    assert :ok = Task.await(outsider)
    assert Store.pending_count(scope) == 1
    assert Store.inflight_count(scope) == 1
    assert :ok = Store.finish_claim(active)
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
      Plug.Conn.resp(conn, 200, "linked exit")
    end)

    ReqTestSite.expect_once(site, "GET", "/claim/sibling", fn conn ->
      Plug.Conn.resp(conn, 200, "sibling")
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
    assert Store.find(failed_key).body == "linked exit"
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

    retry_opts = owner |> Map.put(:max_pages, 2) |> Map.put(:scraper, Crawler.Scraper)
    assert {:ok, retry} = start_crawl(elem(failed_key, 0), retry_opts)
    await_idle(retry)
    assert Agent.get(attempts, & &1) == 2
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

  defp exercise_retired_claim(event, %{url: url}) do
    scope = unique_scope("retired-claim-#{event}")
    on_exit(fn -> Store.drop_scope(scope) end)
    generation = Store.generation(scope)
    old_queue = idle_queue()
    opts = %{scope: scope, generation: generation, queue: old_queue, max_pages: 1}
    direct_key = {url <> "/claim/direct", scope}
    assert {:ok, _} = Store.add(direct_key, generation)
    assert :ok = Store.note_enqueued(scope, generation, old_queue)
    assert {:ok, stale} = Store.start_work(opts)

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
    opts = %{opts | generation: generation, queue: queue}
    assert :ok = Store.note_enqueued(scope, generation, queue)
    assert {:ok, active} = Store.start_work(opts)
    send(Store, {:DOWN, stale, :process, self(), :killed})
    assert :ok = Store.finish_claim(stale)
    assert Store.current?(scope, generation, queue)
    assert Store.pending_count(scope) == 1
    assert Store.inflight_count(scope) == 1
    assert Store.ops_count(scope) == 0

    assert :ok = Store.finish_claim(active)
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
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
end
