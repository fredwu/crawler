defmodule Crawler do
  @moduledoc """
  A high performance web crawler in Elixir.
  """

  alias Crawler.Options
  alias Crawler.Queue
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

    opts = stamp_generation(opts)

    if page_allowed?(opts) do
      QueueHandler.enqueue(opts)
    else
      {:ok, opts}
    end
  end

  defp stamp_generation(%{force: true, depth: 0, scope: scope} = opts) do
    Map.put(opts, :generation, Store.drop_scope(scope))
  end

  defp stamp_generation(%{generation: generation} = opts) when is_integer(generation), do: opts

  defp stamp_generation(%{scope: scope} = opts) do
    Map.put(opts, :generation, Store.generation(scope))
  end

  @doc """
  Stops a crawl.

  Pass the options returned by `Crawler.crawl/2`. This drops that scope's
  URLs, counters, and in-flight page slots. When the crawl started the queue,
  the queue and the processes it started are shut down. A queue created
  outside Crawler keeps running. Stopping the scope that started a queue
  shuts that queue down, even when these options only contain `queue:`.
  This does not change the caller's exit trapping.

  Stopping the crawl that created a shared queue shuts that queue down. Other
  scopes using it stop making progress. Pages they have already stored stay
  readable.
  """
  def stop(opts) do
    opts = Enum.into(opts, %{})
    scope = opts[:scope]
    owner = owning_queue(opts)

    if not is_nil(scope), do: Store.drop_scope(scope)

    if is_pid(owner), do: Queue.stop(owner)

    :ok
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

  A stopped scope reports `false` even when its queue still holds another
  crawl's work. Pages this scope has queued still count until their workers
  finish.
  """
  def running?(opts) do
    Process.sleep(10)

    opts = Enum.into(opts, %{})

    cond do
      paused?(opts) -> false
      closed?(opts[:scope], opts[:generation], opts[:queue]) -> false
      Store.inflight_count(opts[:scope]) > 0 -> true
      Store.pending_count(opts[:scope]) > 0 -> true
      queued?(opts) -> true
      true -> false
    end
  end

  @doc """
  Crawls immediately, this is used by `Crawler.Dispatcher.Worker.start_link/1`.

  For general purpose use cases, always use `Crawler.crawl/2` instead.
  """
  def crawl_now(opts), do: Worker.run(opts)

  defp page_allowed?(%{max_pages: :infinity}), do: true

  defp page_allowed?(%{max_pages: max_pages, scope: scope}) when is_integer(max_pages) do
    Store.ops_count(scope) < max_pages
  end

  defp page_allowed?(_opts), do: true

  defp owning_queue(%{queue: queue, scope: scope}) when is_pid(queue) do
    case Store.queue_record(queue) do
      %{owner: owner, scope: ^scope} when is_pid(owner) -> owner
      _ -> nil
    end
  end

  defp owning_queue(_opts), do: nil

  defp closed?(_scope, generation, _queue) when not is_integer(generation), do: false

  defp closed?(scope, generation, queue) do
    not Store.current?(scope, generation, queue)
  end

  defp queue_reference(opts) do
    queue = opts[:queue]
    name = opts[:queue_name]

    if is_atom(name) and not is_nil(name) and Process.whereis(name) == queue,
      do: name,
      else: queue
  end

  defp paused?(opts), do: match?({:paused, _, _}, queue_info(opts))

  defp queued?(opts) do
    case queue_info(opts) do
      {_status, %{data: data}, _workers} -> not :queue.is_empty(data)
      _ -> false
    end
  end

  defp queue_info(opts) do
    case queue_reference(opts) do
      nil -> nil
      queue when is_pid(queue) -> GenStage.call(queue, :info)
      name -> OPQ.info(name)
    end
  catch
    :exit, _ -> nil
  end
end
