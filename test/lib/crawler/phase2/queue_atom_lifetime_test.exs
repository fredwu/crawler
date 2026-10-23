defmodule Crawler.QueueAtomLifetimeTest do
  use ExUnit.Case, async: false

  alias Crawler.QueueTickets
  alias Crawler.Store

  defmodule HeldFilter do
    @behaviour Crawler.Fetcher.UrlFilter.Spec

    @impl true
    def filter(_url, opts) do
      send(opts.test_owner, {:queue_filter, opts.queue, self()})

      receive do
        :release -> {:ok, false}
      after
        10_000 -> {:error, :filter_barrier_timeout}
      end
    end
  end

  @tag timeout: 120_000
  test "warmed crawl queue lifetimes do not allocate atoms or retain queue processes" do
    [{_, partition, _, _}] = Supervisor.which_children(OPQ.Registry)
    services = [Process.whereis(Store), partition]

    Enum.each(services, fn pid ->
      assert :erlang.trace_info(pid, :tracer) == {:tracer, []}
      assert :erlang.trace(pid, true, [:receive]) == 1
    end)

    on_exit(fn ->
      Enum.each(services, fn pid ->
        if Process.alive?(pid), do: :erlang.trace(pid, false, [:receive])
      end)
    end)

    baseline = resources()
    repeat(8, services)
    warmed = resources()
    repeat(8, services)
    stable = resources()
    assert stable.atoms == warmed.atoms
    assert stable.registry == baseline.registry
    assert stable.queues == baseline.queues
    assert stable.tickets == baseline.tickets

    for count <- [16, 64, 128] do
      repeat(count, services)
      measured = resources()
      assert measured.atoms == stable.atoms
      assert measured.processes <= stable.processes
      assert measured.registry == baseline.registry
      assert measured.queues == baseline.queues
      assert measured.tickets == baseline.tickets
    end
  end

  defp repeat(count, services) do
    for _ <- 1..count do
      concurrent_crawls(services)
      borrowed_crawl(services)
      external_crawl(services)
      flush_traces()
    end
  end

  defp concurrent_crawls(services) do
    parent = self()

    tasks =
      for _ <- 1..4 do
        Task.async(fn ->
          opts = crawl(test_owner: parent)

          try do
            send(parent, {:crawl_created, self(), opts})

            receive do
              :stop -> :ok
            end
          after
            Crawler.stop(opts)
          end
        end)
      end

    try do
      crawls =
        Enum.map(tasks, fn %{pid: pid} ->
          assert_receive {:crawl_created, ^pid, opts}, 5_000
          opts
        end)

      queues = Enum.map(crawls, & &1.queue)
      owners = Enum.map(crawls, & &1.queue_owner)
      assert length(Enum.uniq(queues)) == 4
      assert length(Enum.uniq(owners)) == 4

      Enum.each(crawls, fn opts ->
        assert Process.info(opts.queue, :registered_name) == {:registered_name, []}
        assert %{owner: owner, scope: scope} = Store.queue_record(opts.queue)
        assert owner == opts.queue_owner
        assert scope == opts.scope
      end)

      Enum.reduce(1..4, Map.new(crawls, &{&1.queue, &1}), fn _, remaining ->
        assert_receive {:queue_filter, queue, worker}, 5_000
        {opts, remaining} = Map.pop!(remaining, queue)
        stop_owned(opts, worker, services)
        remaining
      end)
    after
      Enum.each(tasks, &send(&1.pid, :stop))
      Enum.each(tasks, &Task.await(&1, 5_000))
    end
  end

  defp borrowed_crawl(services) do
    creator = crawl(test_owner: self())

    try do
      worker = held_worker(creator)
      children = owned_processes(creator)
      borrower = crawl(queue: creator.queue, test_owner: self())

      try do
        assert borrower.queue == creator.queue
        assert borrower[:queue_owner] == nil
        assert :ok = Crawler.stop(borrower)
        assert Enum.all?([worker | children], &Process.alive?/1)
        assert %{owner: owner, scope: scope} = Store.queue_record(creator.queue)
        assert owner == creator.queue_owner
        assert scope == creator.scope
      after
        Crawler.stop(borrower)
      end

      stop_owned(creator, worker, services)
    after
      Crawler.stop(creator)
    end
  end

  defp external_crawl(services) do
    {:links, before} = Process.info(self(), :links)

    {:ok, queue} =
      OPQ.start_link(worker: Crawler.Dispatcher.Worker, workers: 1, interval: 1, timeout: 5_000)

    {:links, after_start} = Process.info(self(), :links)
    children = after_start -- before
    Enum.each(children, &Process.unlink/1)

    try do
      OPQ.pause(queue)
      assert {:paused, _, _} = OPQ.info(queue)
      opts = crawl(queue: queue, test_owner: self())

      try do
        assert opts[:queue_owner] == nil
        assert :ok = Crawler.stop(opts)
        assert Enum.all?(children, &Process.alive?/1)
        assert {:paused, _, _} = OPQ.info(queue)
        assert [{^queue, _options}] = Registry.lookup(OPQ.Registry, queue)
      after
        Crawler.stop(opts)
      end
    after
      monitors = monitors(children)
      {supervisors, rest} = Enum.split_with(children, &supervisor?/1)
      Enum.each(supervisors ++ List.delete(rest, queue) ++ [queue], &stop_process/1)
      await_down(monitors)
      retired(queue, services)
    end
  end

  defp crawl(options) do
    options =
      Keyword.merge(
        [
          workers: 1,
          interval: 1,
          retries: 0,
          respect_robots: false,
          url_filter: HeldFilter,
          store: nil
        ],
        options
      )

    {:ok, opts} = Crawler.crawl("http://queue-atom.invalid/", options)
    opts
  end

  defp held_worker(%{queue: queue}) do
    assert_receive {:queue_filter, ^queue, worker}, 5_000
    worker
  end

  defp owned_processes(opts) do
    {:links, links} = Process.info(opts.queue_owner, :links)
    Enum.uniq([opts.queue_owner | links -- [Process.whereis(Crawler.QueueSupervisor)]])
  end

  defp stop_owned(opts, worker, services) do
    monitors = monitors([worker | owned_processes(opts)])
    assert :ok = Crawler.stop(opts)
    await_down(monitors)
    retired(opts.queue, services)
  end

  defp monitors(pids), do: Enum.map(pids, &{&1, Process.monitor(&1)})

  defp await_down(monitors) do
    Enum.each(monitors, fn {pid, ref} ->
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      refute Process.alive?(pid)
    end)
  end

  defp retired(queue, [store, partition]) do
    assert_receive {:trace, ^store, :receive, {:DOWN, _, :process, ^queue, _}}, 5_000
    assert_receive {:trace, ^partition, :receive, {:EXIT, ^queue, _}}, 5_000

    # A receive trace precedes its callback; these calls wait for callback completion.
    Enum.each([store, partition, Process.whereis(QueueTickets)], &:sys.get_state/1)
    assert QueueTickets.status(queue) == :untracked
    assert Store.queue_record(queue) == nil
    assert Registry.lookup(OPQ.Registry, queue) == []
  end

  defp resources do
    %{
      atoms: :erlang.system_info(:atom_count),
      processes: :erlang.system_info(:process_count),
      registry: Registry.count(OPQ.Registry),
      queues: DynamicSupervisor.which_children(Crawler.QueueSupervisor) |> Enum.sort(),
      tickets: QueueTickets.stats().tracked
    }
  end

  defp supervisor?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> match?({:supervisor, _, _}, dictionary[:"$initial_call"])
      nil -> false
    end
  end

  defp stop_process(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :shutdown, 5_000)
  end

  defp flush_traces do
    receive do
      {:trace, _, :receive, _} -> flush_traces()
    after
      0 -> :ok
    end
  end
end
