defmodule Crawler.Store do
  @moduledoc """
  An internal data store for information related to each crawl.

  Pages live in a registry owned by this process, so they remain available
  after the worker that fetched them has finished.
  """

  alias Crawler.Store.DB
  alias Crawler.Store.Page

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, _} = Registry.start_link(keys: :unique, name: DB)
    {:ok, %{ops: %{}, inflight: %{}}}
  end

  @doc """
  Finds a stored URL and returns its page data.
  """
  def find({url, scope}) do
    case Registry.lookup(DB, {url, scope}) do
      [{_, page}] -> page
      _ -> nil
    end
  end

  @doc """
  Finds a stored URL and returns its page data only if it's processed.
  """
  def find_processed({url, scope}) do
    case Registry.match(DB, {url, scope}, %{processed: true}) do
      [{_, page}] -> page
      _ -> nil
    end
  end

  @doc """
  Adds a URL to the registry.
  """
  def add({_url, _scope} = key) do
    GenServer.call(__MODULE__, {:add, key})
  end

  @doc """
  Adds the page data for a URL to the registry.
  """
  def add_page_data({_url, _scope} = key, body, opts) do
    GenServer.call(__MODULE__, {:add_page_data, key, body, opts})
  end

  @doc """
  Marks a URL as processed in the registry.
  """
  def processed({_url, _scope} = key) do
    GenServer.call(__MODULE__, {:processed, key})
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

  def ops_inc(scope \\ nil), do: GenServer.call(__MODULE__, {:ops_inc, scope})

  def ops_reset, do: GenServer.call(__MODULE__, :ops_reset)

  @doc """
  Reserves a page slot for `scope` when the crawl is still under `max_pages`.

  The reservation counts as in flight until `inflight_dec/1`. Processed pages
  keep occupying a slot via `ops_inc/1`.
  """
  def try_claim(scope, max_pages) do
    GenServer.call(__MODULE__, {:try_claim, scope, max_pages})
  end

  def inflight_dec(scope), do: GenServer.call(__MODULE__, {:inflight_dec, scope})

  def inflight_count(scope), do: GenServer.call(__MODULE__, {:inflight_count, scope})

  @impl true
  def handle_call({:add, {url, _scope} = key}, _from, state) do
    result =
      case Registry.lookup(DB, key) do
        [{pid, _page}] -> {:error, {:already_registered, pid}}
        [] -> Registry.register(DB, key, %Page{url: url})
      end

    {:reply, result, state}
  end

  def handle_call({:add_page_data, key, body, opts}, _from, state) do
    result = Registry.update_value(DB, key, &%{&1 | body: body, opts: opts})
    {:reply, result, state}
  end

  def handle_call({:processed, key}, _from, state) do
    result = Registry.update_value(DB, key, &%{&1 | processed: true})
    {:reply, result, state}
  end

  def handle_call({:ops_inc, scope}, _from, state) do
    {:reply, :ok, update_in(state.ops, &Map.update(&1, scope, 1, fn count -> count + 1 end))}
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

  def handle_call({:try_claim, scope, max_pages}, _from, state) do
    used = Map.get(state.ops, scope, 0) + Map.get(state.inflight, scope, 0)

    if under_limit?(used, max_pages) do
      state = update_in(state.inflight, &Map.update(&1, scope, 1, fn count -> count + 1 end))
      {:reply, :ok, state}
    else
      {:reply, :full, state}
    end
  end

  def handle_call({:inflight_dec, scope}, _from, state) do
    inflight =
      Map.update(state.inflight, scope, 0, fn count ->
        max(count - 1, 0)
      end)

    {:reply, :ok, %{state | inflight: inflight}}
  end

  def handle_call({:inflight_count, scope}, _from, state) do
    {:reply, Map.get(state.inflight, scope, 0), state}
  end

  defp under_limit?(_used, :infinity), do: true
  defp under_limit?(used, max_pages) when is_integer(max_pages), do: used < max_pages
  defp under_limit?(_used, _max_pages), do: true
end
