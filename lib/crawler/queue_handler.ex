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
    {:ok, opq} = OPQ.init(
      worker:   Worker,
      workers:  opts[:workers],
      interval: opts[:interval],
      timeout:  opts[:timeout]
    )

    Map.merge(opts, %{queue: opq})
  end

  defp init_queue(_queue, opts), do: opts
end
