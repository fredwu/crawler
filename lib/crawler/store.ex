defmodule Crawler.Store do
  @moduledoc """
  An internal data store for information related to each crawl.
  """

  alias Crawler.Store.Counter
  alias Crawler.Store.DB
  alias Crawler.Store.Page

  use GenServer

  def start_link(opts) do
    children = [
      {Registry, keys: :unique, name: DB},
      Counter
    ]

    Supervisor.start_link(
      children,
      [strategy: :one_for_one, name: __MODULE__] ++ opts
    )
  end

  @doc """
  Initialises a new `Registry` named `Crawler.Store.DB`.
  """
  def init(args) do
    {:ok, args}
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
  def add({url, scope}) do
    Registry.register(DB, {url, scope}, %Page{url: url})
  end

  @doc """
  Adds the page data for a URL to the registry.
  """
  def add_page_data({url, scope}, body, opts) do
    {_new, _old} = Registry.update_value(DB, {url, scope}, &%{&1 | body: body, opts: opts})
  end

  @doc """
  Marks a URL as processed in the registry.
  """
  def processed({url, scope}) do
    {_new, _old} = Registry.update_value(DB, {url, scope}, &%{&1 | processed: true})
  end

  def all_urls do
    Registry.select(DB, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  def ops_inc do
    Counter.inc()
  end

  def ops_count do
    Counter.value()
  end

  def ops_reset do
    Counter.reset()
  end
end
