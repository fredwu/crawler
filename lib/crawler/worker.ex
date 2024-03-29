defmodule Crawler.Worker do
  @moduledoc """
  Handles the crawl tasks.
  """

  require Logger

  alias Crawler.Fetcher
  alias Crawler.Store
  alias Crawler.Store.Page

  use GenServer

  def init(args) do
    :timer.send_after(args[:timeout], :stop)

    {:ok, args}
  end

  @doc """
  Runs the worker that casts data to itself to kick off the crawl workflow.
  """
  def run(opts) do
    Logger.debug("Running worker with opts: #{inspect(opts)}")

    {:ok, pid} = GenServer.start_link(__MODULE__, opts, hibernate_after: 0)

    GenServer.cast(pid, opts)
  end

  @doc """
  A crawl workflow that delegates responsibilities to:

  - `Crawler.Fetcher.fetch/1`
  - `Crawler.Parser.parse/1` (or a custom parser)
  """
  def handle_cast(_req, state) do
    Logger.debug("Running worker with opts: #{inspect(state)}")

    state
    |> Fetcher.fetch()
    |> state[:parser].parse()
    |> mark_processed()

    {:noreply, state, :hibernate}
  end

  def handle_info(:stop, state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp mark_processed({:ok, %Page{url: url, opts: opts}}) do
    Store.ops_inc()
    Store.processed({url, opts[:scope]})
  end

  defp mark_processed(_), do: nil
end
