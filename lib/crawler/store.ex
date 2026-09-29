defmodule Crawler.Store do
  @moduledoc """
  An internal data store for information related to each crawl.

  Pages live in a registry owned by this process, so they remain available
  after the worker that fetched them has finished. `drop_scope/1` removes one
  scope's pages and counters. Other scopes stay.

  `Crawler.stop/1` drops the stopped scope. When that call also stops the
  queue, other scopes on that queue keep processed pages and their counters.
  Their in-flight URLs and page slots are dropped, and their generation changes.

  A URL that fails, or whose handler crashes, stays recorded until that scope
  is idle. It is then dropped so a later crawl can fetch it again. Pages that
  were processed stay until the scope is dropped.
  """

  alias Crawler.Store.DB
  alias Crawler.Store.Page
  alias Crawler.URL

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, _} = Registry.start_link(keys: :unique, name: DB)

    {:ok,
     %{
       ops: %{},
       inflight: %{},
       pending: %{},
       generation: %{},
       queues: %{},
       owners: %{}
     }}
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
  def add({url, scope}, generation \\ nil) do
    GenServer.call(__MODULE__, {:add, identity(url, scope), generation})
  end

  @doc """
  Adds the page data for a URL to the registry.
  """
  def add_page_data({url, scope}, body, opts) do
    GenServer.call(
      __MODULE__,
      {:add_page_data, identity(url, scope), body, opts, opts[:generation]}
    )
  end

  @doc """
  Marks a URL as processed in the registry.
  """
  def processed({url, scope}, generation \\ nil) do
    GenServer.call(__MODULE__, {:processed, identity(url, scope), generation})
  end

  @doc """
  Removes one URL from the registry.
  """
  def delete({url, scope}, generation \\ nil) do
    GenServer.call(__MODULE__, {:delete, identity(url, scope), generation})
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

  def ops_inc(scope \\ nil, generation \\ nil) do
    GenServer.call(__MODULE__, {:ops_inc, scope, generation})
  end

  def ops_reset, do: GenServer.call(__MODULE__, :ops_reset)

  @doc """
  Reserves a page slot for `scope` when the crawl is still under `max_pages`.

  The reservation counts as in flight until the worker finishes. Processed
  pages keep occupying a slot via `ops_inc/1`.
  """
  def try_claim(scope, max_pages, generation \\ nil) do
    GenServer.call(__MODULE__, {:try_claim, scope, max_pages, generation})
  end

  def inflight_dec(scope, generation \\ nil) do
    GenServer.call(__MODULE__, {:inflight_dec, scope, generation})
  end

  def inflight_count(scope), do: GenServer.call(__MODULE__, {:inflight_count, scope})

  def pending_count(scope), do: GenServer.call(__MODULE__, {:pending_count, scope})

  def note_enqueued(scope, generation, queue) do
    GenServer.call(__MODULE__, {:note_enqueued, scope, generation, queue})
  end

  def finish_work(scope, generation, claimed?) do
    GenServer.call(__MODULE__, {:finish_work, scope, generation, claimed?})
  end

  def publish_file(scope, generation, dest, temp) do
    GenServer.call(__MODULE__, {:publish_file, scope, generation, dest, temp})
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

  def abandon_inflight(scope) do
    GenServer.call(__MODULE__, {:abandon_inflight, scope})
  end

  def release_queue(queue) when is_pid(queue) do
    GenServer.call(__MODULE__, {:release_queue, queue})
  end

  def release_queue(_queue), do: :ok

  @impl true
  def handle_call({:add, {url, scope} = key, generation}, _from, state) do
    if current?(state, scope, generation) do
      result =
        case Registry.lookup(DB, key) do
          [{pid, _page}] -> {:error, {:already_registered, pid}}
          [] -> Registry.register(DB, key, %Page{url: url})
        end

      {:reply, result, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:add_page_data, {_url, scope} = key, body, opts, generation}, _from, state) do
    result =
      if current?(state, scope, generation) do
        Registry.update_value(DB, key, &%{&1 | body: body, opts: opts})
      else
        {:error, :stale}
      end

    {:reply, result, state}
  end

  def handle_call({:processed, {_url, scope} = key, generation}, _from, state) do
    result =
      if current?(state, scope, generation) do
        Registry.update_value(DB, key, &%{&1 | processed: true})
      else
        :stale
      end

    {:reply, result, state}
  end

  def handle_call({:delete, {_url, scope} = key, generation}, _from, state) do
    result =
      if current?(state, scope, generation) do
        Registry.unregister(DB, key)
      else
        :stale
      end

    {:reply, result, state}
  end

  def handle_call({:drop_scope, scope}, _from, state) do
    unregister_scope(scope)
    generation = Map.get(state.generation, scope, 0) + 1

    state = %{
      state
      | ops: Map.delete(state.ops, scope),
        inflight: Map.delete(state.inflight, scope),
        pending: Map.delete(state.pending, scope),
        generation: Map.put(state.generation, scope, generation),
        queues: drop_scope_from_queues(state.queues, scope)
    }

    {:reply, generation, state}
  end

  def handle_call({:generation, scope}, _from, state) do
    {:reply, Map.get(state.generation, scope, 0), state}
  end

  def handle_call({:ops_inc, scope, generation}, _from, state) do
    state =
      if current?(state, scope, generation) do
        update_in(state.ops, &Map.update(&1, scope, 1, fn count -> count + 1 end))
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:ops_count, scope}, _from, state) do
    {:reply, Map.get(state.ops, scope, 0), state}
  end

  def handle_call(:ops_count, _from, state) do
    {:reply, state.ops |> Map.values() |> Enum.sum(), state}
  end

  def handle_call(:ops_reset, _from, state) do
    {:reply, :ok, %{state | ops: %{}}}
  end

  def handle_call({:try_claim, scope, max_pages, generation}, _from, state) do
    used = Map.get(state.ops, scope, 0) + Map.get(state.inflight, scope, 0)

    cond do
      not current?(state, scope, generation) ->
        {:reply, :stale, state}

      under_limit?(used, max_pages) ->
        state = update_in(state.inflight, &Map.update(&1, scope, 1, fn count -> count + 1 end))
        {:reply, :ok, state}

      true ->
        {:reply, :full, state}
    end
  end

  def handle_call({:inflight_dec, scope, generation}, _from, state) do
    state =
      if current?(state, scope, generation) do
        inflight =
          Map.update(state.inflight, scope, 0, fn count ->
            max(count - 1, 0)
          end)

        %{state | inflight: inflight}
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call({:inflight_count, scope}, _from, state) do
    {:reply, Map.get(state.inflight, scope, 0), state}
  end

  def handle_call({:pending_count, scope}, _from, state) do
    {:reply, Map.get(state.pending, scope, 0), state}
  end

  def handle_call({:note_enqueued, scope, generation, queue}, _from, state) do
    if current?(state, scope, generation) do
      state = %{
        state
        | pending: Map.update(state.pending, scope, 1, &(&1 + 1)),
          queues: track_queue(state.queues, queue, scope)
      }

      {:reply, :ok, state}
    else
      {:reply, :stale, state}
    end
  end

  def handle_call({:finish_work, scope, generation, claimed?}, _from, state) do
    if current?(state, scope, generation) do
      inflight =
        if claimed? do
          Map.update(state.inflight, scope, 0, &max(&1 - 1, 0))
        else
          state.inflight
        end

      pending = Map.update(state.pending, scope, 0, &max(&1 - 1, 0))
      state = %{state | inflight: inflight, pending: pending}

      if Map.get(state.pending, scope, 0) == 0 and Map.get(state.inflight, scope, 0) == 0 do
        drop_unprocessed(scope)
      end

      {:reply, :ok, state}
    else
      {:reply, :stale, state}
    end
  end

  def handle_call({:publish_file, scope, generation, dest, temp}, _from, state) do
    reply =
      if current?(state, scope, generation) do
        case File.rename(temp, dest) do
          :ok -> :ok
          {:error, reason} -> {:error, "Cannot write to file #{dest}, reason: #{reason}"}
        end
      else
        File.rm(temp)
        {:error, :stale}
      end

    {:reply, reply, state}
  end

  def handle_call({:attach_owner, feeder, owner, scope}, _from, state) do
    owners = Map.put(state.owners, feeder, %{owner: owner, scope: scope})
    {:reply, :ok, %{state | owners: owners}}
  end

  def handle_call({:queue_record, queue}, _from, state) do
    {:reply, Map.get(state.owners, queue), state}
  end

  def handle_call({:queue_scopes, queue}, _from, state) do
    scopes =
      state.queues
      |> Map.get(queue, MapSet.new())
      |> MapSet.to_list()

    {:reply, scopes, state}
  end

  def handle_call({:abandon_inflight, scope}, _from, state) do
    {:reply, :ok, abandon_scope(state, scope)}
  end

  def handle_call({:release_queue, queue}, _from, state) do
    scopes = Map.get(state.queues, queue, MapSet.new())

    exclusive =
      Enum.filter(scopes, fn scope ->
        Enum.all?(state.queues, fn {other, set} ->
          other == queue or not MapSet.member?(set, scope)
        end)
      end)

    state = Enum.reduce(exclusive, state, &abandon_scope(&2, &1))

    state = %{
      state
      | queues: Map.delete(state.queues, queue),
        owners: Map.delete(state.owners, queue)
    }

    {:reply, :ok, state}
  end

  defp abandon_scope(state, scope) do
    drop_unprocessed(scope)
    generation = Map.get(state.generation, scope, 0) + 1

    %{
      state
      | inflight: Map.delete(state.inflight, scope),
        pending: Map.delete(state.pending, scope),
        generation: Map.put(state.generation, scope, generation),
        queues: drop_scope_from_queues(state.queues, scope)
    }
  end

  defp track_queue(queues, queue, scope) when is_pid(queue) do
    Map.update(queues, queue, MapSet.new([scope]), &MapSet.put(&1, scope))
  end

  defp track_queue(queues, _queue, _scope), do: queues

  defp drop_scope_from_queues(queues, scope) do
    Enum.reduce(queues, %{}, fn {queue, scopes}, acc ->
      scopes = MapSet.delete(scopes, scope)

      if MapSet.size(scopes) == 0 do
        acc
      else
        Map.put(acc, queue, scopes)
      end
    end)
  end

  defp unregister_scope(scope) do
    DB
    |> Registry.select([
      {{:"$1", :_, :_}, [{:==, {:element, 2, :"$1"}, scope}], [:"$1"]}
    ])
    |> Enum.each(&Registry.unregister(DB, &1))
  end

  defp drop_unprocessed(scope) do
    DB
    |> Registry.select([
      {{:"$1", :_, :"$2"}, [{:==, {:element, 2, :"$1"}, scope}], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.each(fn {key, page} ->
      if page.processed != true, do: Registry.unregister(DB, key)
    end)
  end

  defp scope_current?(_scope, nil), do: true

  defp scope_current?(scope, generation) when is_integer(generation) do
    generation(scope) == generation
  end

  defp scope_current?(_scope, _generation), do: false

  defp under_limit?(_used, :infinity), do: true
  defp under_limit?(used, max_pages) when is_integer(max_pages), do: used < max_pages
  defp under_limit?(_used, _max_pages), do: true

  defp identity(url, scope) when is_binary(url), do: {URL.canonical(url), scope}
  defp identity(url, scope), do: {url, scope}

  defp current?(_state, _scope, nil), do: true

  defp current?(state, scope, generation) do
    Map.get(state.generation, scope, 0) == generation
  end
end
