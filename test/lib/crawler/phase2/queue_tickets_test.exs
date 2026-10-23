defmodule Crawler.QueueTicketsTest do
  use ExUnit.Case, async: true

  alias Crawler.QueueTickets
  alias Crawler.QueueTickets.Ticket

  defmodule Transport do
    @behaviour Crawler.QueueTickets.Transport
    @impl true
    def enqueue(queue, ticket) do
      send(queue, {:enqueue, ticket})
      :ok
    end
  end

  defmodule UncertainTransport do
    @behaviour Crawler.QueueTickets.Transport
    @impl true
    def enqueue(queue, ticket) do
      send(queue, {:enqueue, ticket})
      {:error, :unknown_delivery}
    end
  end

  setup do
    roster_key = {QueueTickets, make_ref()}

    on_exit(fn ->
      roster = :persistent_term.get(roster_key, %{})

      Enum.each(roster, fn {queue, _} ->
        if Process.alive?(queue), do: Process.exit(queue, :kill)
      end)

      :persistent_term.erase(roster_key)
    end)

    %{opts: [name: nil, roster_key: roster_key, transport: Transport], roster_key: roster_key}
  end

  test "actual submitted events stay capped until acknowledgement", %{opts: opts} do
    {:ok, server} = QueueTickets.start_link(opts)
    queue = queue()
    assert QueueTickets.attach(queue, 3, server) == :ok

    for _ <- 1..500 do
      assert {:ok, _issued} = QueueTickets.ensure(queue, 100, server)
    end

    tickets = queued(queue)
    assert length(tickets) == 3
    assert Enum.all?(tickets, &match?(%Ticket{}, &1))
    assert Enum.all?(tickets, &(Map.keys(&1) -- [:__struct__, :queue, :ref, :issuer] == []))
    [first | _] = tickets
    assert take(queue) == first
    assert QueueTickets.ack(first, server) == :ok
    assert QueueTickets.ack(first, server) == {:error, :stale_ticket}
    assert QueueTickets.ensure(queue, 100, server) == {:ok, 1}
    assert length(queued(queue)) == 3
    assert QueueTickets.status(queue, server).outstanding == 3
    stop(server)
  end

  test "authority restart quarantines a live borrowed queue and new queues progress", %{
    opts: opts
  } do
    queue = queue()
    {:ok, server} = QueueTickets.start_link(opts)
    :ok = QueueTickets.attach(queue, 2, server)
    assert QueueTickets.ensure(queue, 2, server) == {:ok, 2}
    tickets = queued(queue)
    stop(server)

    for _ <- 1..5 do
      {:ok, restarted} = QueueTickets.start_link(opts)
      expected = {:error, {:queue_unusable, :ticket_authority_lost}}
      assert QueueTickets.attach(queue, 2, restarted) == expected
      assert QueueTickets.ensure(queue, 2, restarted) == expected
      assert QueueTickets.status(queue, restarted).outstanding == :unknown
      assert QueueTickets.ack(hd(tickets), restarted) == {:error, :stale_ticket}
      assert queued(queue) == tickets
      assert Process.alive?(queue)

      fresh_queue = queue()
      assert QueueTickets.attach(fresh_queue, 2, restarted) == :ok
      assert QueueTickets.ensure(fresh_queue, 2, restarted) == {:ok, 2}
      assert length(queued(fresh_queue)) == 2
      kill(fresh_queue)

      assert {:error, {:queue_unavailable, ^fresh_queue}} =
               QueueTickets.attach(fresh_queue, 2, restarted)

      stop(restarted)
    end
  end

  test "deaths while authority is down free the bounded persistent roster", %{
    opts: opts,
    roster_key: key
  } do
    opts = Keyword.put(opts, :max_tracked_queues, 2)
    {:ok, server} = QueueTickets.start_link(opts)
    first = queue()
    second = queue()
    spare = queue()
    assert QueueTickets.attach(first, 1, server) == :ok
    assert QueueTickets.attach(second, 1, server) == :ok
    assert QueueTickets.attach(spare, 1, server) == {:error, {:limit, :max_tracked_queues}}
    assert map_size(:persistent_term.get(key)) == 2
    stop(server)
    kill(first)
    kill(second)
    {:ok, restarted} = QueueTickets.start_link(opts)
    assert QueueTickets.sweep(restarted) == :ok
    assert QueueTickets.stats(restarted).tracked == 0
    assert :persistent_term.get(key, :absent) == :absent
    assert QueueTickets.attach(spare, 1, restarted) == :ok
    assert QueueTickets.ensure(spare, 1, restarted) == {:ok, 1}
    stop(restarted)
  end

  test "uncertain delivery keeps credits and quarantines only that queue", %{opts: opts} do
    opts = Keyword.put(opts, :transport, UncertainTransport)
    {:ok, server} = QueueTickets.start_link(opts)
    queue = queue()
    assert QueueTickets.attach(queue, 2, server) == :ok

    assert {:error, {:queue_unusable, :transport_delivery_unknown}} =
             QueueTickets.ensure(queue, 2, server)

    assert QueueTickets.status(queue, server) == %{
             status: :quarantined,
             reason: :transport_delivery_unknown,
             cap: 2,
             outstanding: 2
           }

    assert length(queued(queue)) == 1
    assert {:error, {:queue_unusable, _}} = QueueTickets.ensure(queue, 2, server)
    assert length(queued(queue)) == 1
    stop(server)
  end

  test "queue limits cannot be raised by reenrollment and forged credits are rejected", %{
    opts: opts
  } do
    {:ok, server} = QueueTickets.start_link(opts)
    queue = queue()
    assert QueueTickets.attach(queue, 2, server) == :ok
    assert QueueTickets.attach(queue, 3, server) == {:error, {:queue_capacity_conflict, 2}}
    assert QueueTickets.attach(queue, 33, server) == {:error, {:limit, :max_queue_tickets}}
    assert QueueTickets.ensure(queue, 2, server) == {:ok, 2}
    [ticket | _] = queued(queue)
    assert QueueTickets.ack(%{ticket | ref: make_ref()}, server) == {:error, :stale_ticket}
    assert QueueTickets.status(queue, server).outstanding == 2
    stop(server)
  end

  test "abrupt issuer death cannot recreate credit and other authorities remain active", %{
    opts: opts
  } do
    queue = queue()
    {:ok, server} = QueueTickets.start_link(opts)
    Process.unlink(server)
    :ok = QueueTickets.attach(queue, 2, server)
    assert QueueTickets.ensure(queue, 2, server) == {:ok, 2}

    other_opts = Keyword.put(opts, :roster_key, {QueueTickets, make_ref()})
    {:ok, other} = QueueTickets.start_link(other_opts)
    other_queue = queue()
    :ok = QueueTickets.attach(other_queue, 1, other)
    kill(server)

    {:ok, restarted} = QueueTickets.start_link(opts)

    assert {:error, {:queue_unusable, :ticket_authority_lost}} =
             QueueTickets.ensure(queue, 2, restarted)

    assert length(queued(queue)) == 2
    assert QueueTickets.ensure(other_queue, 1, other) == {:ok, 1}
    assert length(queued(other_queue)) == 1
    kill(other_queue)

    assert {:error, {:queue_unavailable, ^other_queue}} =
             QueueTickets.attach(other_queue, 1, other)

    stop(other)
    stop(restarted)
  end

  test "multi-batch recovery removes dead enrollments without retaining tombstones", %{
    opts: opts,
    roster_key: key
  } do
    {:ok, server} = QueueTickets.start_link(Keyword.put(opts, :max_tracked_queues, 130))
    queues = for _ <- 1..130, do: queue()
    Enum.each(queues, &assert(QueueTickets.attach(&1, 1, server) == :ok))
    assert map_size(:persistent_term.get(key)) == 130
    stop(server)
    Enum.each(queues, &kill/1)

    {:ok, restarted} = QueueTickets.start_link(Keyword.put(opts, :max_tracked_queues, 130))
    Enum.each(1..3, fn _ -> assert QueueTickets.sweep(restarted) == :ok end)
    assert QueueTickets.stats(restarted).tracked == 0
    assert :persistent_term.get(key, :absent) == :absent
    stop(restarted)
  end

  test "acknowledgement emits one coalesced credit signal until scheduling checks again", %{
    opts: opts
  } do
    {:ok, server} = QueueTickets.start_link(Keyword.put(opts, :credit_target, self()))
    queue = queue()
    assert QueueTickets.attach(queue, 3, server) == :ok
    assert QueueTickets.ensure(queue, 3, server) == {:ok, 3}
    assert QueueTickets.ack(take(queue), server) == :ok
    assert QueueTickets.ack(take(queue), server) == :ok
    assert_receive {:crawler_queue_credit, ^queue}
    refute_received {:crawler_queue_credit, ^queue}
    assert QueueTickets.ensure(queue, 3, server) == {:ok, 2}
    assert QueueTickets.ack(take(queue), server) == :ok
    assert_receive {:crawler_queue_credit, ^queue}
    assert length(queued(queue)) == 2
    stop(server)
  end

  defp queue do
    spawn(fn -> queue_loop([]) end)
  end

  defp queue_loop(events) do
    receive do
      {:enqueue, event} ->
        queue_loop([event | events])

      {:snapshot, from, ref} ->
        send(from, {ref, Enum.reverse(events)})
        queue_loop(events)

      {:take, from, ref} ->
        [first | rest] = Enum.reverse(events)
        send(from, {ref, first})
        queue_loop(Enum.reverse(rest))
    end
  end

  defp queued(queue) do
    ref = make_ref()
    send(queue, {:snapshot, self(), ref})
    assert_receive {^ref, events}
    events
  end

  defp take(queue) do
    ref = make_ref()
    send(queue, {:take, self(), ref})
    assert_receive {^ref, ticket}
    ticket
  end

  defp stop(server) do
    Process.unlink(server)
    GenServer.stop(server)
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end
end
