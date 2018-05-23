defmodule Crawler.Worker do
  @moduledoc """
  Handles the crawl tasks.
  """

  alias Crawler.{Fetcher, Store, Store.Page}


  @doc """
  A crawl workflow that delegates responsibilities to:

  - `Crawler.Fetcher.fetch/1`
  - `Crawler.Parser.parse/1` (or a custom parser)
  """
  def run(opts) do
    opts
    |> Fetcher.fetch()
    |> opts[:parser].parse()
    |> mark_processed()

    {:noreply, opts}
  end

  defp mark_processed({:ok, %Page{url: url}}), do: Store.processed(url)
  defp mark_processed(_),                      do: nil
end
