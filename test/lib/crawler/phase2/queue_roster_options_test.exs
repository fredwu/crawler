defmodule Crawler.QueueRosterOptionsTest do
  use ExUnit.Case, async: false

  alias Crawler.QueueTickets

  defmodule Transport do
    @behaviour Crawler.QueueTickets.Transport

    @impl true
    def enqueue(queue, ticket) do
      send(queue, {:ticket, ticket})
      :ok
    end
  end

  setup do
    previous =
      Map.new([:max_tracked_queues, :max_queue_tickets], fn key ->
        {key, Application.fetch_env(:crawler, key)}
      end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:crawler, key, value)
        {key, :error} -> Application.delete_env(:crawler, key)
      end)
    end)

    :ok
  end

  test "caller ceiling restricts only new enrollment and cannot change the service cap" do
    server = service(max_tracked_queues: 2)
    first = queue()
    second = queue()
    spare = queue()
    caller = Crawler.Options.assign_defaults(%{max_queue_tickets: 1, max_tracked_queues: 1})

    assert QueueTickets.attach(first, caller.max_queue_tickets, server, caller.max_tracked_queues) ==
             :ok

    assert QueueTickets.attach(
             second,
             caller.max_queue_tickets,
             server,
             caller.max_tracked_queues
           ) == {:error, {:limit, :max_tracked_queues}}

    assert QueueTickets.attach(second, 1, server, 100) == :ok
    assert QueueTickets.attach(first, 1, server, 1) == :ok
    assert QueueTickets.attach(spare, 1, server, 100) == {:error, {:limit, :max_tracked_queues}}
    assert QueueTickets.stats(server).tracked == 2
  end

  test "acknowledgement and reenrollment preserve the live physical roster until queue DOWN" do
    server = service(max_tracked_queues: 2)
    first = queue()
    spare = queue()

    assert QueueTickets.attach(first, 1, server, 1) == :ok
    assert QueueTickets.ensure(first, 1, server) == {:ok, 1}
    ref = make_ref()
    send(first, {:take, self(), ref})
    assert_receive {^ref, ticket}
    assert QueueTickets.ack(ticket, server) == :ok
    assert QueueTickets.status(first, server).outstanding == 0

    for _ <- 1..10 do
      assert QueueTickets.attach(first, 1, server, 1) == :ok
      assert QueueTickets.attach(spare, 1, server, 1) == {:error, {:limit, :max_tracked_queues}}
    end

    :erlang.trace(server, true, [:receive])
    monitor = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^first, :killed}
    assert_receive {:trace, ^server, :receive, {:DOWN, _, :process, ^first, :killed}}
    :erlang.trace(server, false, [:receive])
    assert QueueTickets.attach(spare, 1, server, 1) == :ok
    assert QueueTickets.stats(server).tracked == 1
  end

  test "existing queue ticket capacity conflicts and quarantines precede roster ceilings" do
    server = service(max_tracked_queues: 2, max_queue_tickets: 2)
    first = queue()
    assert QueueTickets.attach(first, 1, server, 1) == :ok
    assert QueueTickets.attach(first, 2, server, 1) == {:error, {:queue_capacity_conflict, 1}}
    assert QueueTickets.attach(first, 3, server, 1) == {:error, {:limit, :max_queue_tickets}}

    options = :sys.get_state(server)
    GenServer.stop(server)
    restarted = service(max_tracked_queues: 2, roster_key: options.roster_key)

    assert QueueTickets.attach(first, 1, restarted, 1) ==
             {:error, {:queue_unusable, :ticket_authority_lost}}
  end

  test "application startup options use canonical limits and remain fixed after startup" do
    Application.put_env(:crawler, :max_tracked_queues, 2)
    Application.put_env(:crawler, :max_queue_tickets, 3)
    options = QueueTickets.application_options()
    canonical = Crawler.Limits.validate!(%{})
    assert options[:max_tracked_queues] == canonical.max_tracked_queues
    assert options[:max_queue_tickets] == canonical.max_queue_tickets
    server = service(options)
    Application.put_env(:crawler, :max_tracked_queues, 1)
    Application.put_env(:crawler, :max_queue_tickets, 1)

    assert QueueTickets.attach(queue(), 3, server, 100) == :ok
    assert QueueTickets.attach(queue(), 3, server, 100) == :ok
    assert QueueTickets.attach(queue(), 3, server, 100) == {:error, {:limit, :max_tracked_queues}}
  end

  test "application startup rejects invalid canonical limits" do
    for key <- [:max_tracked_queues, :max_queue_tickets],
        invalid <- [0, -1, nil, :infinity, 1.5] do
      Application.put_env(:crawler, key, invalid)
      assert_raise ArgumentError, fn -> QueueTickets.application_options() end
      Application.delete_env(:crawler, key)
    end
  end

  defp service(options) do
    roster_key = Keyword.get(options, :roster_key, {__MODULE__, make_ref()})
    on_exit(fn -> :persistent_term.erase(roster_key) end)

    options =
      Keyword.merge(
        [name: nil, roster_key: roster_key, transport: Transport, credit_target: nil],
        options
      )

    start_supervised!(Supervisor.child_spec({QueueTickets, options}, restart: :temporary),
      id: make_ref()
    )
  end

  defp queue do
    queue = spawn(fn -> queue_loop() end)
    on_exit(fn -> Process.exit(queue, :kill) end)
    queue
  end

  defp queue_loop do
    receive do
      {:take, from, ref} ->
        receive do
          {:ticket, ticket} -> send(from, {ref, ticket})
        end

        queue_loop()
    end
  end
end
