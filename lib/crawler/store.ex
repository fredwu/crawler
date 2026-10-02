defmodule Crawler.Store do
  @moduledoc """
  An internal data store for information related to each crawl.

  Pages live in a registry owned by this process, so they remain available
  after the worker that fetched them has finished. `drop_scope/1` removes one
  scope's pages and counters. Other scopes stay.

  `Crawler.stop/1` drops the stopped scope. When that call also stops the
  queue, other scopes on that queue keep processed pages and their counters.
  Only that queue's in-flight URLs and page slots are dropped. Work on
  other queues in the same scope continues. Retirement preserves the scope's
  generation while other work contexts remain.

  A queued URL that fails, or whose handler crashes, stays recorded until that
  queue is idle in its scope. It is then dropped so a later crawl can fetch it
  again. Direct fetch registrations and processed pages stay until the scope
  is dropped.
  """

  alias Crawler.Store.DB
  alias Crawler.Store.Server
  alias Crawler.URL

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts \\ []) do
    GenServer.start_link(Server, opts, name: __MODULE__)
  end

  @doc """
  Finds a stored URL and returns its page data.
  """
  def find({url, scope}) do
    case Registry.lookup(DB, identity(url, scope)) do
      [{_, page}] -> page
      _ -> nil
    end
  end

  @doc """
  Finds a stored URL and returns its page data only if it's processed.
  """
  def find_processed({url, scope}) do
    case Registry.match(DB, identity(url, scope), %{processed: true}) do
      [{_, page}] -> page
      _ -> nil
    end
  end

  @doc """
  Adds a URL to the registry.
  """
  def add({url, scope}, generation \\ nil, queue \\ nil) do
    GenServer.call(__MODULE__, {:add, identity(url, scope), generation, queue})
  end

  def register_alias({url, scope}, generation, queue) do
    GenServer.call(__MODULE__, {:register_alias, identity(url, scope), generation, queue})
  end

  def rollback_alias({url, scope}, generation, queue, created?) do
    GenServer.call(
      __MODULE__,
      {:rollback_alias, identity(url, scope), generation, queue, created?}
    )
  end

  def retain_alias({url, scope}, body, opts) do
    GenServer.call(
      __MODULE__,
      {:retain_alias, identity(url, scope), identity(opts[:url], scope), body,
       Map.put(opts, :url, url)}
    )
  end

  def discard_retained_alias(ref), do: GenServer.call(__MODULE__, {:discard_retained_alias, ref})
  def start_settlement(ref), do: GenServer.call(__MODULE__, {:start_settlement, ref})

  def complete_settlement(ref, token),
    do: GenServer.call(__MODULE__, {:complete_settlement, ref, token})

  @doc """
  Adds the page data for a URL to the registry.
  """
  def add_page_data({url, scope}, body, opts) do
    GenServer.call(
      __MODULE__,
      {:add_page_data, identity(url, scope), body, opts, opts[:generation], opts[:queue]}
    )
  end

  @doc """
  Marks a URL as processed in the registry.
  """
  def processed({url, scope}, generation \\ nil, queue \\ nil) do
    GenServer.call(__MODULE__, {:processed, identity(url, scope), generation, queue})
  end

  def complete_page({url, scope}, generation, queue, alias_url \\ nil) do
    alias_key = if is_binary(alias_url), do: identity(alias_url, scope)

    GenServer.call(
      __MODULE__,
      {:complete_page, identity(url, scope), alias_key, generation, queue}
    )
  end

  @doc """
  Removes one URL from the registry.
  """
  def delete({url, scope}, generation \\ nil, queue \\ nil) do
    GenServer.call(__MODULE__, {:delete, identity(url, scope), generation, queue})
  end

  @doc """
  Removes every page and counter for `scope`.

  The scope's generation stays and increases, so a worker from the dropped
  crawl cannot write into the next crawl.
  """
  def drop_scope(scope) do
    GenServer.call(__MODULE__, {:drop_scope, scope})
  end

  def generation(scope), do: GenServer.call(__MODULE__, {:generation, scope})

  def current?(scope, generation, queue \\ nil) do
    GenServer.call(__MODULE__, {:current?, scope, generation, queue})
  end

  def commit(scope, generation, fun) when is_function(fun, 0) do
    if scope_current?(scope, generation) do
      try do
        fun.()
      rescue
        exception -> {:error, Exception.message(exception)}
      end
    else
      {:error, :stale}
    end
  end

  @doc """
  Returns the URLs of pages kept in the store.
  """
  def all_urls do
    DB
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.map(fn {url, _scope} -> url end)
    |> Enum.uniq()
  end

  @doc """
  Counts processed pages for one crawl scope.
  """
  def ops_count(scope), do: GenServer.call(__MODULE__, {:ops_count, scope})

  @doc """
  Counts processed pages across every crawl scope.
  """
  def ops_count, do: GenServer.call(__MODULE__, :ops_count)

  def ops_inc(scope \\ nil, generation \\ nil, queue \\ nil) do
    GenServer.call(__MODULE__, {:ops_inc, scope, generation, queue})
  end

  def ops_reset, do: GenServer.call(__MODULE__, :ops_reset)

  @doc """
  Reserves a page slot for `scope` when the crawl is still under `max_pages`.

  The reservation counts as in flight until the worker finishes. Processed
  pages keep occupying a slot via `ops_inc/1`.
  """
  def try_claim(scope, max_pages, generation \\ nil, queue \\ nil) do
    GenServer.call(__MODULE__, {:try_claim, scope, max_pages, generation, queue})
  end

  def start_work(opts) do
    opts = Map.put(opts, :page_key, identity(opts[:url], opts[:scope]))
    GenServer.call(__MODULE__, {:start_work, opts})
  end

  def finish_claim(token), do: GenServer.call(__MODULE__, {:finish_claim, token})

  def inflight_dec(scope, generation \\ nil, queue \\ nil) do
    GenServer.call(__MODULE__, {:inflight_dec, scope, generation, queue})
  end

  def inflight_count(scope), do: GenServer.call(__MODULE__, {:inflight_count, scope})

  def pending_count(scope), do: GenServer.call(__MODULE__, {:pending_count, scope})

  @doc """
  Checks pending and in-flight work for one queue in a scope's generation.

  A retired queue or generation has no remaining work.
  """
  def work_pending?(scope, generation, queue) do
    GenServer.call(__MODULE__, {:work_pending?, scope, generation, queue})
  end

  def note_enqueued(scope, generation, queue) do
    GenServer.call(__MODULE__, {:note_enqueued, scope, generation, queue})
  end

  def finish_work(scope, generation, claimed?, queue \\ nil) do
    GenServer.call(__MODULE__, {:finish_work, scope, generation, claimed?, queue})
  end

  def publish_file(scope, generation, dest, temp, queue \\ nil) do
    GenServer.call(__MODULE__, {:publish_file, scope, generation, dest, temp, queue})
  end

  def attach_owner(feeder, owner, scope) when is_pid(feeder) and is_pid(owner) do
    GenServer.call(__MODULE__, {:attach_owner, feeder, owner, scope})
  end

  def queue_record(queue) when is_pid(queue) do
    GenServer.call(__MODULE__, {:queue_record, queue})
  end

  def queue_record(_queue), do: nil

  def queue_scopes(queue) when is_pid(queue) do
    GenServer.call(__MODULE__, {:queue_scopes, queue})
  end

  def queue_scopes(_queue), do: []

  def release_queue(queue) when is_pid(queue) do
    GenServer.call(__MODULE__, {:release_queue, queue})
  end

  def release_queue(_queue), do: :ok

  defp scope_current?(_scope, nil), do: true

  defp scope_current?(scope, generation) when is_integer(generation) do
    generation(scope) == generation
  end

  defp scope_current?(_scope, _generation), do: false

  defp identity(url, scope) when is_binary(url), do: {URL.canonical(url), scope}
  defp identity(url, scope), do: {url, scope}
end
