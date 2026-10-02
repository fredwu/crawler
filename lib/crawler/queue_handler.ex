defmodule Crawler.QueueHandler do
  @moduledoc """
  Handles the queueing of crawl requests.
  """

  alias Crawler.Queue
  alias Crawler.Store

  @doc """
  Enqueues a crawl request.

  Also initialises the queue if it's not already initialised, this is necessary
  so that consumer apps don't have to manually handle the queue initialisation.

  An unavailable named queue returns `{:error, {:queue_unavailable, name}}`.
  """
  def enqueue(opts) do
    with {:ok, opts, started?} <- init_queue(opts[:queue], opts) do
      opts = if started?, do: opts, else: assign_queue_owner(opts)

      if queue_alive?(opts[:queue]) do
        note_and_enqueue(opts, started?)
      else
        if started?, do: Queue.stop(opts[:queue_owner])
        {:ok, opts}
      end
    end
  end

  def requeue(%{queue: queue} = opts), do: OPQ.enqueue(queue, opts)

  defp note_and_enqueue(opts, started?) do
    case Store.note_enqueued(opts[:scope], opts[:generation], opts[:queue]) do
      :stale ->
        if started?, do: Queue.stop(opts[:queue_owner])
        {:ok, opts}

      :ok ->
        try do
          OPQ.enqueue(opts[:queue], opts)
          {:ok, opts}
        catch
          kind, reason ->
            Store.finish_work(opts[:scope], opts[:generation], false, opts[:queue])
            if started?, do: Queue.stop(opts[:queue_owner])
            :erlang.raise(kind, reason, __STACKTRACE__)
        end
    end
  end

  defp queue_alive?(queue) when is_pid(queue), do: Process.alive?(queue)

  defp queue_alive?(_queue), do: false

  defp assign_queue_owner(%{queue: queue, scope: scope} = opts) when is_pid(queue) do
    case Store.queue_record(queue) do
      %{owner: owner, scope: ^scope} when is_pid(owner) -> Map.put(opts, :queue_owner, owner)
      _ -> Map.delete(opts, :queue_owner)
    end
  end

  defp assign_queue_owner(opts), do: Map.delete(opts, :queue_owner)

  defp init_queue(nil, opts) do
    spec =
      Supervisor.child_spec({Queue, opts}, shutdown: 10_000, restart: :temporary)

    {:ok, owner} = DynamicSupervisor.start_child(Crawler.QueueSupervisor, spec)
    feeder = Queue.feeder(owner)

    opts =
      opts
      |> Map.put(:queue, feeder)
      |> Map.put(:queue_owner, owner)
      |> Map.delete(:queue_name)

    {:ok, opts, true}
  end

  defp init_queue(queue, opts) when is_atom(queue) do
    case Process.whereis(queue) do
      nil ->
        {:error, {:queue_unavailable, queue}}

      pid ->
        {:ok, opts |> Map.put(:queue, pid) |> Map.put(:queue_name, queue), false}
    end
  end

  defp init_queue(queue, %{queue_name: name} = opts) when is_pid(queue) and is_atom(name) do
    opts = if Process.whereis(name) == queue, do: opts, else: Map.delete(opts, :queue_name)
    {:ok, opts, false}
  end

  defp init_queue(_queue, opts), do: {:ok, Map.delete(opts, :queue_name), false}
end
