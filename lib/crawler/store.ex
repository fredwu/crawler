defmodule Crawler.Store do
  @moduledoc """
  An internal data store for information related to each crawl.

  Pages live in a registry owned by this process, so they remain available
  after the worker that fetched them has finished.
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
    {:ok, %{ops: %{}, inflight: %{}, generation: %{}}}
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
  Removes every page for `scope` and zeros that scope's counters.
  """
  def drop_scope(scope) do
    GenServer.call(__MODULE__, {:drop_scope, scope})
  end

  def generation(scope), do: GenServer.call(__MODULE__, {:generation, scope})

  def commit(scope, generation, fun) when is_function(fun, 0) do
    GenServer.call(__MODULE__, {:commit, scope, generation, fun})
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

  The reservation counts as in flight until `inflight_dec/1`. Processed pages
  keep occupying a slot via `ops_inc/1`.
  """
  def try_claim(scope, max_pages, generation \\ nil) do
    GenServer.call(__MODULE__, {:try_claim, scope, max_pages, generation})
  end

  def inflight_dec(scope, generation \\ nil) do
    GenServer.call(__MODULE__, {:inflight_dec, scope, generation})
  end

  def inflight_count(scope), do: GenServer.call(__MODULE__, {:inflight_count, scope})

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
    DB
    |> Registry.select([
      {{:"$1", :_, :_}, [{:==, {:element, 2, :"$1"}, scope}], [:"$1"]}
    ])
    |> Enum.each(&Registry.unregister(DB, &1))

    generation = Map.get(state.generation, scope, 0) + 1

    state = %{
      state
      | ops: Map.put(state.ops, scope, 0),
        inflight: Map.put(state.inflight, scope, 0),
        generation: Map.put(state.generation, scope, generation)
    }

    {:reply, generation, state}
  end

  def handle_call({:generation, scope}, _from, state) do
    {:reply, Map.get(state.generation, scope, 0), state}
  end

  def handle_call({:commit, scope, generation, fun}, _from, state) do
    reply =
      if current?(state, scope, generation) do
        try do
          fun.()
        rescue
          exception -> {:error, Exception.message(exception)}
        end
      else
        {:error, :stale}
      end

    {:reply, reply, state}
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
