defmodule Crawler do
  @moduledoc """
  A high performance web crawler in Elixir.
  """

  alias Crawler.{Options, Store, QueueHandler, Worker}

  use Application

  @doc """
  Crawler is an application that gets started automatically with:

  - a `Crawler.Store` that initiates a `Registry` for keeping internal data
  """
  def start(_type, _args) do
    {:ok, _pid} = Store.init()
  end

  @doc """
  Enqueues a crawl, via `Crawler.QueueHandler.enqueue/1`.

  This is the default crawl behaviour as the queue determines when an actual
  crawl should happen based on the available workers and the rate limit. The
  queue kicks off `Crawler.Dispatcher.Worker` which in turn calls
  `Crawler.crawl_now/1`.
  """
  def crawl(url, opts \\ []) do
    opts
    |> Enum.into(%{})
    |> Options.assign_defaults()
    |> Options.assign_url(url)
    |> QueueHandler.enqueue()
  end

  @doc """
  Stops the crawler.
  """
  def stop(opts) do
    Process.flag(:trap_exit, true)
    OPQ.stop(opts[:queue])
  end

  @doc """
  Pauses the crawler.
  """
  def pause(opts), do: OPQ.pause(opts[:queue])

  @doc """
  Resumes the crawler after it was paused.
  """
  def resume(opts), do: OPQ.resume(opts[:queue])

  @doc """
  Crawls immediately, this is used by `Crawler.Dispatcher.Worker.start_link/1`.

  For general purpose use cases, always use `Crawler.crawl/2` instead.
  """
  def crawl_now(opts) do
    Worker.run(opts)
  end
end
