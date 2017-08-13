defmodule Crawler.QueueHandler do
  @moduledoc """
  Handles the queueing of crawl requests.
  """

  alias Crawler.Dispatcher.Worker

  def enqueue(opts) do
    opts = init_queue(opts, opts[:queue])

    OPQ.enqueue(opts[:queue], opts)

    {:ok, opts}
  end

  defp init_queue(opts, nil) do
    {:ok, pid} = OPQ.init(worker: Worker, workers: opts[:workers])

    Keyword.merge(opts, queue: pid)
  end

  defp init_queue(opts, _), do: opts
end
