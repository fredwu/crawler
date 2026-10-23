defmodule Crawler.Phase2.AdmissionIntegrationTest do
  use ExUnit.Case, async: false

  alias Crawler.Store

  test "failed automatic admission retains no scope, authority or cookie metadata" do
    before = :sys.get_state(Store)

    for opts <- [
          [queue: :crawler_missing_admission_queue],
          [queue: self(), max_frontier_bytes: 1],
          [queue: self(), max_retained_bytes: 1]
        ] do
      for _ <- 1..10 do
        assert {:error, _} =
                 Crawler.crawl("http://admission.test/", [respect_robots: false] ++ opts)
      end
    end

    after_state = :sys.get_state(Store)
    assert after_state.scopes == before.scopes
    assert after_state.cookies == before.cookies
    assert after_state.cookie_outcomes == before.cookie_outcomes
    assert after_state.scheduler.frontier.jobs == before.scheduler.frontier.jobs
  end

  test "a fresh explicit scope token can prepare cookies before its borrowed queue is bound" do
    scope = make_ref()
    generation = Store.generation(scope)
    url = "https://manual-generation.test/root"
    on_exit(fn -> Store.dispose_scope(scope) end)

    assert :ok =
             Store.save_cookies(
               scope,
               url,
               ["id=one; Path=/; Secure"],
               generation
             )

    opts =
      Crawler.Options.assign_defaults(%{
        scope: scope,
        generation: generation,
        queue: self(),
        url: url,
        respect_robots: false,
        cookie_site: url,
        credentials: :include
      })

    assert Store.current?(scope, generation)
    refute Store.current?(scope, generation, self())
    before = :sys.get_state(Store)
    assert {:ok, prepared} = Crawler.Fetcher.Requester.prepare(opts)
    assert prepared.request.headers["cookie"] == ["id=one"]
    assert :sys.get_state(Store) == before
    refute Store.current?(scope, generation, self())
    assert {:ok, admitted} = Crawler.crawl(url, opts)
    assert admitted.generation == generation
    assert Store.current?(scope, generation, self())
    assert Store.pending_count(scope) == 1
    Store.drop_scope(scope)

    await(fn ->
      refute Map.has_key?(:sys.get_state(Store).scheduler.frontier.runs, {scope, generation})
    end)

    retired = :sys.get_state(Store)
    assert {:error, :stale} = Crawler.Fetcher.Requester.prepare(opts)
    assert :sys.get_state(Store) == retired
  end

  test "duplicate frozen admissions return one canonical target" do
    scope = make_ref()
    opts = [scope: scope, queue: self(), respect_robots: false]
    on_exit(fn -> Store.dispose_scope(scope) end)
    assert {:ok, first} = Crawler.crawl("http://admission.test/same", opts)

    for _ <- 1..100 do
      assert {:ok, duplicate} = Crawler.crawl("http://admission.test/same", opts)
      assert duplicate.target_handle == first.target_handle
    end

    assert Store.pending_count(scope) == 1

    assert MapSet.size(
             :sys.get_state(Store).scheduler.frontier.runs[{scope, first.generation}].jobs
           ) == 1
  end

  test "repeated reset on an actual paused borrowed queue bounds transport tickets" do
    scope = make_ref()
    parent = self()
    {:links, previous} = Process.info(self(), :links)
    {:ok, queue} = OPQ.init(worker: Crawler.Dispatcher.Worker, workers: 1, timeout: 5_000)
    {:links, current} = Process.info(self(), :links)
    children = current -- previous
    Enum.each(children, &Process.unlink/1)

    on_exit(fn ->
      Store.dispose_scope(scope)
      Enum.each(children, &stop_process/1)
    end)

    OPQ.pause(queue)
    assert {:paused, _, _} = OPQ.info(queue)

    adapter = fn request ->
      send(parent, :transport_sent)

      {request,
       Req.Response.new(status: 200, body: "ok", headers: [{"content-type", "text/plain"}])}
    end

    :sys.suspend(queue)

    latest =
      try do
        Enum.reduce(1..100, nil, fn index, _ ->
          assert {:ok, opts} =
                   Crawler.crawl("http://admission.test/#{index}",
                     scope: scope,
                     queue: queue,
                     force: true,
                     respect_robots: false,
                     retries: 0,
                     req_options: [adapter: adapter]
                   )

          {:messages, queued} = Process.info(queue, :messages)

          assert Enum.count(
                   queued,
                   &match?({:"$gen_cast", {:enqueue, %Crawler.QueueTickets.Ticket{}}}, &1)
                 ) <= 1

          {:messages, notifications} = Process.info(Process.whereis(Store), :messages)
          assert Enum.count(notifications, &(&1 == :frontier_transition)) <= 1
          assert Enum.count(notifications, &match?({:crawler_queue_credit, ^queue}, &1)) <= 1
          assert %{outstanding: outstanding} = Crawler.QueueTickets.status(queue)
          assert outstanding <= 1
          opts
        end)
      after
        :sys.resume(queue)
      end

    assert {:paused, %OPQ.Queue{data: data}, _} = OPQ.info(queue)
    assert :queue.len(data) <= 1
    refute_received :transport_sent
    OPQ.resume(queue)
    assert_receive :transport_sent, 2_000

    await(fn ->
      assert %{status: :succeeded} = Store.target_outcome(latest.target_handle)
      assert Store.ops_count(scope) == 1
      assert Store.pending_count(scope) == 0
    end)

    assert Process.alive?(queue)
  end

  defmodule PassParser do
    def parse(page), do: {:ok, page}
  end

  test "a failure-heavy bounded frontier does not block another scope transport" do
    scope = make_ref()
    sibling = make_ref()
    queue = borrowed_queue()
    other_queue = borrowed_queue()
    parent = self()

    on_exit(fn ->
      Store.dispose_scope(scope)
      Store.dispose_scope(sibling)
    end)

    adapter = fn request ->
      send(parent, {:held_failure, self()})
      receive do: (:release -> :ok)
      {request, Req.Response.new(status: 503, body: "failed")}
    end

    opts = [
      scope: scope,
      queue: queue,
      respect_robots: false,
      retries: 0,
      max_pending: 4,
      max_body: 1_048_576,
      max_analysis_bytes: 16_000_000,
      max_frontier_bytes: 100_000,
      parser: PassParser,
      req_options: [adapter: adapter]
    ]

    assert {:ok, first} = Crawler.crawl("https://failures.test/first", opts)
    assert_receive {:held_failure, executor}
    results = for index <- 1..100, do: Crawler.crawl("https://failures.test/#{index}", opts)
    assert Enum.any?(results, &match?({:error, {:limit, _}}, &1))
    assert Store.pending_count(scope) <= 4

    assert {:ok, other} =
             Crawler.crawl("https://sibling.test/",
               scope: sibling,
               queue: other_queue,
               respect_robots: false,
               retries: 0,
               max_body: 1_048_576,
               max_analysis_bytes: 16_000_000,
               parser: PassParser,
               req_options: [
                 adapter: fn request ->
                   send(parent, :sibling_progress)

                   {request,
                    Req.Response.new(
                      status: 200,
                      body: "ok",
                      headers: [{"content-type", "text/plain"}]
                    )}
                 end
               ]
             )

    assert_receive :sibling_progress, 1_000
    await(fn -> assert %{status: :succeeded} = Store.target_outcome(other.target_handle) end)
    send(executor, :release)

    for _ <- 1..3 do
      receive do
        {:held_failure, worker} -> send(worker, :release)
      after
        100 -> :ok
      end
    end

    await(fn ->
      assert %{status: :failed} = Store.target_outcome(first.target_handle)
      assert Store.pending_count(scope) == 0
      assert :sys.get_state(Store).scheduler.claims == %{}
    end)
  end

  test "dead queue cancellation settles its owner and lets a live queue's waiter fetch" do
    scope = make_ref()
    queue = borrowed_queue()
    other_queue = borrowed_queue()
    on_exit(fn -> Store.dispose_scope(scope) end)
    OPQ.pause(queue)
    assert {:paused, _, _} = OPQ.info(queue)

    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
    name = {__MODULE__, make_ref()}
    parent = self()

    Req.Test.stub(name, fn conn ->
      send(parent, {:surviving_queue_transport, conn.request_path})

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.send_resp(200, "ok")
    end)

    opts = [
      scope: scope,
      respect_robots: false,
      retries: 0,
      parser: PassParser,
      req_options: [plug: {Req.Test, name}]
    ]

    assert {:ok, owner} =
             Crawler.crawl(
               "https://queue-death.test/shared",
               opts ++ [queue: queue, javascript_goal: :classic]
             )

    assert {:ok, waiter} =
             Crawler.crawl(
               "https://queue-death.test/shared",
               opts ++ [queue: other_queue, javascript_goal: :module]
             )

    Process.exit(queue, :kill)

    await(fn ->
      assert %{status: :cancelled} = Store.target_outcome(owner.target_handle)
      assert %{status: :succeeded} = Store.target_outcome(waiter.target_handle)
      assert Store.pending_count(scope) == 0
    end)

    assert_receive {:surviving_queue_transport, "/shared"}
    refute_receive {:surviving_queue_transport, "/shared"}, 20
    assert Store.ops_count(scope) == 1

    assert {:ok, live} =
             Crawler.crawl("https://queue-death.test/live", opts ++ [queue: other_queue])

    await(fn -> assert %{status: :succeeded} = Store.target_outcome(live.target_handle) end)
    assert Process.alive?(other_queue)
  end

  defp borrowed_queue do
    {:links, before_links} = Process.info(self(), :links)
    {:ok, queue} = OPQ.init(worker: Crawler.Dispatcher.Worker, workers: 1, timeout: 5_000)
    {:links, after_links} = Process.info(self(), :links)
    children = after_links -- before_links
    Enum.each(children, &Process.unlink/1)

    on_exit(fn ->
      Enum.each(children, &stop_process/1)
    end)

    queue
  end

  defp stop_process(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  defp await(check, attempts \\ 200)

  defp await(check, attempts) when attempts > 0 do
    try do
      check.()
    rescue
      ExUnit.AssertionError ->
        receive do
        after
          5 -> :ok
        end

        await(check, attempts - 1)
    end
  end

  defp await(check, 0), do: check.()
end
