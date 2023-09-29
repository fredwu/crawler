defmodule Crawler.QueueHandler do
  @moduledoc """
  Handles the queueing of crawl requests.
  """

  alias Crawler.Dispatcher.Worker

  @doc """
  Enqueues a crawl request.

  Also initialises the queue if it's not already initialised, this is necessary
  so that consumer apps don't have to manually handle the queue initialisation.
  """
  def enqueue(opts) do
    opts = init_queue(opts[:queue], opts)

    OPQ.enqueue(opts[:queue], opts)

    {:ok, opts}
  end

  defp init_queue(nil, opts) do
    {:ok, _} =
      DynamicSupervisor.start_child(
        Crawler.QueueSupervisor,
        {OPQ,
         [
           worker: Worker,
           workers: opts[:workers],
           interval: opts[:interval],
           timeout: opts[:timeout]
         ]}
      )

    pid =
      Crawler.QueueSupervisor
      |> Supervisor.which_children()
      |> List.last()
      |> elem(1)

    Map.merge(opts, %{queue: pid})
  end

  defp init_queue(_queue, opts), do: opts
end
