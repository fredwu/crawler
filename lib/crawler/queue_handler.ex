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
  """
  def enqueue(opts) do
    {opts, started?} = init_queue(opts[:queue], opts)

    if queue_alive?(opts[:queue]) do
      note_and_enqueue(opts, started?)
    else
      if started?, do: Queue.stop(opts[:queue_owner])
      {:ok, opts}
    end
  end

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
            Store.finish_work(opts[:scope], opts[:generation], false)
            if started?, do: Queue.stop(opts[:queue_owner])
            :erlang.raise(kind, reason, __STACKTRACE__)
        end
    end
  end

  defp queue_alive?(queue) when is_pid(queue), do: Process.alive?(queue)

  defp queue_alive?(queue) when is_atom(queue) and queue != nil do
    is_pid(Process.whereis(queue))
  end

  defp queue_alive?(_queue), do: false

  defp init_queue(nil, opts) do
    spec =
      Supervisor.child_spec({Queue, opts}, shutdown: 10_000, restart: :temporary)

    {:ok, owner} = DynamicSupervisor.start_child(Crawler.QueueSupervisor, spec)
    feeder = Queue.feeder(owner)

    opts =
      opts
      |> Map.put(:queue, feeder)
      |> Map.put(:queue_owner, owner)

    {opts, true}
  end

  defp init_queue(_queue, opts), do: {opts, false}
end
