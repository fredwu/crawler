defmodule Crawler do
  @moduledoc """
  A high performance web crawler in Elixir.
  """

  alias Crawler.Options
  alias Crawler.Parser.CssSheets
  alias Crawler.Queue
  alias Crawler.QueueHandler
  alias Crawler.Store
  alias Crawler.Worker

  use Application

  @doc """
  Crawler is an application that gets started automatically with:

  - a `Crawler.Store` that owns a `Registry` for keeping internal data
  - a supervisor for queues started by the crawler

  Queues started by Crawler stop when the Store restarts.
  """
  def start(_type, _args) do
    children = [
      {Crawler.QueueTickets, Crawler.QueueTickets.application_options()},
      Store,
      {DynamicSupervisor, name: Crawler.QueueSupervisor, strategy: :one_for_one},
      CssSheets
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Crawler)
  end

  @doc """
  Enqueues a crawl, via `Crawler.QueueHandler.enqueue/1`.

  This is the default crawl behaviour as the queue determines when an actual
  crawl should happen based on the available workers and the rate limit. The
  queue kicks off `Crawler.Dispatcher.Worker` which in turn calls
  `Crawler.crawl_now/1`.

  Copying crawl options into a different scope acquires authority for that
  scope. A stale token for the same scope stays stale unless `:force` resets it.
  """
  def crawl(url, opts \\ []) do
    opts =
      url
      |> prepare_options(opts)
      |> Options.assign_scope()
      |> select_scope()

    enqueue_allowed(opts, :root)
  end

  @doc false
  def crawl_reference(url, opts) do
    opts = prepare_options(url, Map.put(Enum.into(opts, %{}), :force, false))
    opts = if is_nil(opts[:generation]), do: Options.assign_scope(opts), else: opts

    enqueue_allowed(opts, :reference)
  end

  defp prepare_options(url, opts) do
    opts
    |> Enum.into(%{})
    |> Options.assign_defaults()
    |> Options.assign_url(url)
    |> assign_site()
  end

  defp select_scope(%{scope: scope, generation: {_incarnation, selected, _revision}} = opts)
       when scope !== selected,
       do: Map.drop(opts, [:generation, :run_deadline])

  defp select_scope(opts), do: opts

  defp enqueue_allowed(opts, ingress) do
    QueueHandler.enqueue(opts, ingress)
  end

  defp assign_site(%{site: site} = opts) when is_binary(site), do: opts
  defp assign_site(opts), do: Map.put(opts, :site, opts[:url])

  @doc """
  Stops a crawl.

  Pass the options returned by `Crawler.crawl/2`. This drops that scope's
  URLs, counters, and in-flight page slots. When the crawl started the queue,
  the queue and the processes it started are shut down. A queue created
  outside Crawler keeps running. Stopping the scope that started a queue
  shuts that queue down when these options contain its `queue:` and `scope:`.
  This does not change the caller's exit trapping. Direct fetch options with
  a generation can also stop their run when the scope is `nil`.
  Options from an older generation leave the current run and queue unchanged.

  Stopping the crawl that created a shared queue shuts that queue down. Other
  scopes using it stop making progress. Pages they have already stored stay
  readable.
  """
  def stop(opts) do
    opts = Enum.into(opts, %{})
    scope = opts[:scope]
    owner = owning_queue(opts)

    disposal =
      cond do
        not is_nil(opts[:generation]) -> Store.dispose_scope(scope, opts.generation)
        not is_nil(scope) -> Store.dispose_scope(scope)
        true -> :ok
      end

    if disposal == :ok and is_pid(owner), do: Queue.stop(owner)

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
  Returns the redacted outcome of the run's latest cookie save, or `nil`.

  This is the latest save result, not a cumulative report. A retired generation
  or queue returns `{:error, :stale}`.
  """
  def cookie_outcome(opts) do
    opts = Map.new(opts)
    Store.cookie_outcome(opts[:scope], opts[:generation], opts[:queue])
  end

  @doc """
  Checks whether the crawler is still crawling.

  A scope with no remaining work reports `false` even when its queue still
  holds another scope's work. Pages this scope has queued still count until
  their workers finish. A paused or stopped crawl reports `false`.
  """
  def running?(opts) do
    opts = Enum.into(opts, %{})

    cond do
      paused?(opts) -> false
      closed?(opts[:scope], opts[:generation], opts[:queue]) -> published_cleanup?(opts)
      Store.inflight_count(opts[:scope]) > 0 -> true
      Store.pending_count(opts[:scope]) > 0 -> true
      true -> false
    end
  end

  defp published_cleanup?(opts),
    do: match?({:ok, %{state: :finalizing, running?: true}}, Store.export_status(opts))

  @doc """
  Returns the current run's bounded status for options returned by `crawl/2`.

  `:root_status` is the canonical root target's outcome, not an assertion that
  every descendant succeeded. `:reported_limit` exposes the first recorded run
  limit even when the root succeeded. Active work is `:running` or `:paused`;
  after quiescence a recorded limit takes precedence over the root outcome.
  A run deadline reports `:limited` immediately, while `:terminal?` remains
  false until owned work settles. Failure reasons contain no callback payloads.

  Paused work is not terminal and reports `:running?` as false. A disposed or
  replaced generation, or a target from another run, returns `{:error, :stale}`.
  Use `export_status/1` separately to distinguish archive publication states.
  """
  def run_status(opts) do
    opts = Map.new(opts)
    Store.run_status(opts, paused?(opts))
  end

  @doc """
  Crawls immediately, this is used by `Crawler.Dispatcher.Worker.start_link/1`.

  For general purpose use cases, always use `Crawler.crawl/2` instead.
  """
  def crawl_now(opts), do: Worker.run(opts)

  @doc """
  Returns bounded export status without private source or request data.

  Cancellation remains readable while the export owner cleans up. A previous
  failure or limit stays visible. After promotion, publication success is final;
  status stays `:finalizing` and counts as running until cleanup succeeds and its
  actors exit. Cleanup failure reports `{:snapshot, :cleanup_failed}` without
  removing the promoted archive. Published status remains readable for the exact
  generation after its deadline and cleanup. Disposal or replacement makes it
  stale. An unproved cleanup keeps a bounded failed recovery record after disposal
  while no replacement scope exists. Its receipt and credit remain owned until
  cleanup is proved; other retired status ends when cleanup removes its record.
  """
  def export_status(opts), do: Store.export_status(opts, paused?(Map.new(opts)))

  defp owning_queue(%{queue: queue} = opts) when is_pid(queue) do
    scope = opts[:scope]

    case Store.queue_record(queue) do
      %{owner: owner, scope: ^scope} when is_pid(owner) -> owner
      _ -> nil
    end
  end

  defp owning_queue(_opts), do: nil

  defp closed?(_scope, nil, _queue), do: false

  defp closed?(scope, generation, queue) do
    not Store.current?(scope, generation, queue)
  end

  defp paused?(opts), do: match?({:paused, _, _}, queue_info(opts))

  defp queue_info(opts) do
    case opts[:queue] do
      queue when is_pid(queue) -> GenStage.call(queue, :info)
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end
end
