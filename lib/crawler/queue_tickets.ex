defmodule Crawler.QueueTickets.Transport do
  @moduledoc false

  @callback enqueue(pid(), Crawler.QueueTickets.Ticket.t()) :: :ok | {:error, term()}
end

defmodule Crawler.QueueTickets.OPQ do
  @moduledoc false
  @behaviour Crawler.QueueTickets.Transport

  @impl true
  def enqueue(queue, ticket), do: apply(OPQ, :enqueue, [queue, ticket])
end

defmodule Crawler.QueueTickets do
  @moduledoc false

  use GenServer

  defmodule Ticket do
    @moduledoc false
    @enforce_keys [:queue, :ref, :issuer]
    defstruct [:queue, :ref, :issuer]

    @type t :: %__MODULE__{queue: pid(), ref: reference(), issuer: reference()}
  end

  @roster_key {__MODULE__, :enrollments}
  @recovery_batch 64

  def start_link(opts \\ []) do
    server_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  def application_options do
    %{}
    |> Crawler.Limits.validate!()
    |> Map.take([:max_tracked_queues, :max_queue_tickets])
    |> Map.to_list()
  end

  def attach(queue, cap, server \\ __MODULE__, tracked_limit \\ nil)
      when is_pid(queue) and is_integer(cap) and cap > 0 and
             (is_nil(tracked_limit) or (is_integer(tracked_limit) and tracked_limit > 0)),
      do: GenServer.call(server, {:attach, queue, cap, tracked_limit})

  def ensure(queue, desired, server \\ __MODULE__)
      when is_pid(queue) and is_integer(desired) and desired >= 0,
      do: GenServer.call(server, {:ensure, queue, desired})

  def ack(%Ticket{} = ticket, server \\ __MODULE__),
    do: GenServer.call(server, {:ack, ticket})

  def status(queue, server \\ __MODULE__), do: GenServer.call(server, {:status, queue})
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @doc false
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  @impl true
  def init(opts) do
    defaults = Crawler.Limits.defaults()
    max_queues = Keyword.get(opts, :max_tracked_queues, defaults.max_tracked_queues)
    max_tickets = Keyword.get(opts, :max_queue_tickets, defaults.max_queue_tickets)
    roster_key = Keyword.get(opts, :roster_key, @roster_key)
    roster = :persistent_term.get(roster_key, %{})

    cond do
      not is_integer(max_queues) or max_queues < 1 ->
        {:stop, {:invalid_limit, :max_tracked_queues}}

      not is_integer(max_tickets) or max_tickets < 1 ->
        {:stop, {:invalid_limit, :max_queue_tickets}}

      map_size(roster) > max_queues ->
        {:stop, {:queue_roster_limit_conflict, map_size(roster)}}

      true ->
        entries =
          Map.new(roster, fn {queue, enrollment} ->
            {queue,
             %{
               cap: enrollment.cap,
               issuer: enrollment.issuer,
               status: :quarantined,
               reason: :ticket_authority_lost,
               monitor: nil,
               credit_pending?: false,
               outstanding: MapSet.new()
             }}
          end)

        state = %{
          epoch: make_ref(),
          entries: entries,
          recovery: :queue.from_list(Map.keys(roster)),
          roster_key: roster_key,
          max_queues: max_queues,
          max_tickets: max_tickets,
          credit_target: Keyword.get(opts, :credit_target, Crawler.Store),
          transport: Keyword.get(opts, :transport, Crawler.QueueTickets.OPQ)
        }

        send(self(), :recover)
        {:ok, state}
    end
  end

  @impl true
  def handle_call({:attach, queue, cap, tracked_limit}, _from, state) do
    state = recover(state)

    cond do
      not Process.alive?(queue) ->
        {:reply, {:error, {:queue_unavailable, queue}}, retire(state, queue)}

      cap > state.max_tickets ->
        {:reply, {:error, {:limit, :max_queue_tickets}}, state}

      entry = state.entries[queue] ->
        reply =
          cond do
            entry.status == :quarantined -> unusable(entry.reason)
            entry.cap != cap -> {:error, {:queue_capacity_conflict, entry.cap}}
            true -> :ok
          end

        {:reply, reply, state}

      map_size(state.entries) >= min(tracked_limit || state.max_queues, state.max_queues) ->
        {:reply, {:error, {:limit, :max_tracked_queues}}, state}

      true ->
        entry = %{
          cap: cap,
          issuer: state.epoch,
          status: :active,
          reason: nil,
          monitor: Process.monitor(queue),
          credit_pending?: false,
          outstanding: MapSet.new()
        }

        state = put_entry(state, queue, entry)
        save_roster(state)
        {:reply, :ok, state}
    end
  end

  def handle_call({:ensure, queue, desired}, _from, state) do
    case state.entries[queue] do
      %{status: :active} = entry ->
        if Process.alive?(queue) do
          entry = %{entry | credit_pending?: false}
          state = put_entry(state, queue, entry)
          needed = max(min(desired, entry.cap) - MapSet.size(entry.outstanding), 0)
          {reply, state} = issue(state, queue, entry, needed)
          {:reply, reply, state}
        else
          {:reply, {:error, {:queue_unavailable, queue}}, retire(state, queue)}
        end

      %{status: :quarantined, reason: reason} ->
        {:reply, unusable(reason), state}

      nil ->
        {:reply, {:error, :queue_not_attached}, state}
    end
  end

  def handle_call({:ack, %Ticket{queue: queue, ref: ref, issuer: issuer}}, _from, state) do
    case state.entries[queue] do
      %{issuer: ^issuer} = entry ->
        if MapSet.member?(entry.outstanding, ref) do
          entry = %{entry | outstanding: MapSet.delete(entry.outstanding, ref)}
          entry = notify_credit(entry, queue, state.credit_target)
          {:reply, :ok, put_entry(state, queue, entry)}
        else
          {:reply, {:error, :stale_ticket}, state}
        end

      _ ->
        {:reply, {:error, :stale_ticket}, state}
    end
  end

  def handle_call({:status, queue}, _from, state) do
    reply =
      case state.entries[queue] do
        nil ->
          :untracked

        entry ->
          %{
            status: entry.status,
            reason: entry.reason,
            cap: entry.cap,
            outstanding: outstanding(entry)
          }
      end

    {:reply, reply, state}
  end

  def handle_call(:stats, _from, state) do
    counts =
      Enum.reduce(
        state.entries,
        %{active: 0, quarantined: 0, outstanding: 0, unknown_queues: 0},
        fn {_queue, entry}, acc ->
          acc = Map.update!(acc, entry.status, &(&1 + 1))

          case outstanding(entry) do
            :unknown -> Map.update!(acc, :unknown_queues, &(&1 + 1))
            count -> Map.update!(acc, :outstanding, &(&1 + count))
          end
        end
      )

    {:reply, Map.put(counts, :tracked, map_size(state.entries)), state}
  end

  def handle_call(:sweep, _from, state) do
    {:reply, :ok, recover(state)}
  end

  @impl true
  def handle_info(:recover, state) do
    state = recover(state)
    if not :queue.is_empty(state.recovery), do: send(self(), :recover)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, queue, _reason}, state) do
    case state.entries[queue] do
      %{monitor: ^monitor} -> {:noreply, retire(state, queue)}
      _ -> {:noreply, state}
    end
  end

  defp issue(state, _queue, _entry, 0), do: {{:ok, 0}, state}

  defp issue(state, queue, entry, needed) do
    tickets = for _ <- 1..needed, do: %Ticket{queue: queue, ref: make_ref(), issuer: entry.issuer}

    entry = %{
      entry
      | outstanding: Enum.reduce(tickets, entry.outstanding, &MapSet.put(&2, &1.ref))
    }

    state = put_entry(state, queue, entry)

    result =
      Enum.reduce_while(tickets, :ok, fn ticket, :ok ->
        case state.transport.enqueue(queue, ticket) do
          :ok -> {:cont, :ok}
          {:error, _reason} -> {:halt, :uncertain}
        end
      end)

    case result do
      :ok ->
        {{:ok, needed}, state}

      :uncertain ->
        reason = :transport_delivery_unknown

        {unusable(reason),
         put_entry(state, queue, %{entry | status: :quarantined, reason: reason})}
    end
  end

  defp recover(state) do
    next = recover(state, @recovery_batch)
    if map_size(next.entries) != map_size(state.entries), do: save_roster(next)
    next
  end

  defp recover(state, 0), do: state

  defp recover(state, remaining) do
    case :queue.out(state.recovery) do
      {:empty, _queue} ->
        state

      {{:value, queue}, rest} ->
        state = %{state | recovery: rest}

        state = recover_entry(state, queue)
        recover(state, remaining - 1)
    end
  end

  defp recover_entry(state, queue) do
    case state.entries[queue] do
      nil ->
        state

      %{monitor: nil} = entry ->
        if Process.alive?(queue),
          do: put_entry(state, queue, %{entry | monitor: Process.monitor(queue)}),
          else: retire(state, queue, false)

      _entry ->
        state
    end
  end

  defp retire(state, queue, persist? \\ true) do
    case Map.pop(state.entries, queue) do
      {nil, _entries} ->
        state

      {entry, entries} ->
        if entry.monitor, do: Process.demonitor(entry.monitor, [:flush])
        state = %{state | entries: entries}
        if persist?, do: save_roster(state)
        state
    end
  end

  defp save_roster(state) do
    roster =
      Map.new(state.entries, fn {queue, entry} -> {queue, Map.take(entry, [:issuer, :cap])} end)

    if map_size(roster) == 0,
      do: :persistent_term.erase(state.roster_key),
      else: :persistent_term.put(state.roster_key, roster)
  end

  defp put_entry(state, queue, entry),
    do: %{state | entries: Map.put(state.entries, queue, entry)}

  defp notify_credit(%{credit_pending?: true} = entry, _queue, _target), do: entry
  defp notify_credit(%{status: :quarantined} = entry, _queue, _target), do: entry

  defp notify_credit(entry, queue, target) do
    pid = if is_atom(target), do: Process.whereis(target), else: target

    if is_pid(pid) and Process.alive?(pid) do
      send(pid, {:crawler_queue_credit, queue})
      %{entry | credit_pending?: true}
    else
      entry
    end
  end

  defp outstanding(%{reason: :ticket_authority_lost}), do: :unknown
  defp outstanding(entry), do: MapSet.size(entry.outstanding)

  defp unusable(reason), do: {:error, {:queue_unusable, reason}}
end
