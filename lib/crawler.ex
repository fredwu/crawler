defmodule Crawler do
  @moduledoc """
  A high performance web crawler in Elixir.
  """

  alias Crawler.Options
  alias Crawler.QueueHandler
  alias Crawler.Store
  alias Crawler.Worker

  use Application

  @doc """
  Crawler is an application that gets started automatically with:

  - a `Crawler.Store` that initiates a `Registry` for keeping internal data
  """
  def start(_type, _args) do
    children = [
      Store,
      {DynamicSupervisor, name: Crawler.QueueSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Crawler)
  end

  @doc """
  Enqueues a crawl, via `Crawler.QueueHandler.enqueue/1`.

  This is the default crawl behaviour as the queue determines when an actual
  crawl should happen based on the available workers and the rate limit. The
  queue kicks off `Crawler.Dispatcher.Worker` which in turn calls
  `Crawler.crawl_now/1`.
  """
  def crawl(url, opts \\ []) do
    opts =
      opts
      |> Enum.into(%{})
      |> Options.assign_defaults()
      |> Options.assign_scope()
      |> Options.assign_url(url)

    if page_allowed?(opts) do
      QueueHandler.enqueue(opts)
    else
      {:ok, opts}
    end
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
  Checks whether the crawler is still crawling.
  """
  def running?(opts) do
    Process.sleep(10)

    cond do
      paused?(opts[:queue]) -> false
      Store.inflight_count(opts[:scope]) > 0 -> true
      queued?(opts[:queue]) -> true
      true -> false
    end
  end

  @doc """
  Crawls immediately, this is used by `Crawler.Dispatcher.Worker.start_link/1`.

  For general purpose use cases, always use `Crawler.crawl/2` instead.
  """
  def crawl_now(opts) do
    if page_allowed?(opts) do
      Worker.run(opts)
    end
  end

  defp page_allowed?(%{max_pages: :infinity}), do: true

  defp page_allowed?(%{max_pages: max_pages, scope: scope}) when is_integer(max_pages) do
    Store.ops_count(scope) + Store.inflight_count(scope) < max_pages
  end

  defp page_allowed?(_opts), do: true

  defp paused?(nil), do: false

  defp paused?(queue) do
    queue |> OPQ.info() |> elem(0) == :paused
  catch
    :exit, _ -> false
  end

  defp queued?(nil), do: false

  defp queued?(queue) do
    case OPQ.info(queue) do
      {_status, %{data: data}, _workers} -> not :queue.is_empty(data)
      _ -> false
    end
  catch
    :exit, _ -> false
  end
end
