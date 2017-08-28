defmodule Crawler.Worker do
  @moduledoc """
  Handles the crawl tasks.
  """

  alias Crawler.{Fetcher, Store, Store.Page}

  use GenServer

  @doc """
  Runs the worker that casts data to itself to kick off the crawl workflow.
  """
  def run(opts) do
    {:ok, pid} = GenServer.start_link(__MODULE__, opts)

    GenServer.cast(pid, opts)
  end

  @doc """
  A crawl workflow that delegates responsibilities to:

  - `Crawler.Fetcher.fetch/1`
  - `Crawler.Parser.parse/2` (or a custom parser)
  """
  def handle_cast(_req, state) do
    state
    |> Fetcher.fetch
    |> state[:parser].parse
    |> mark_processed

    {:noreply, state}
  end

  defp mark_processed(%Page{url: url}), do: Store.processed(url)
  defp mark_processed(_),               do: nil
end
