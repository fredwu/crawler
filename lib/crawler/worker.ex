defmodule Crawler.Worker do
  @moduledoc """
  Handles the crawl tasks.
  """

  require Logger

  alias Crawler.Diagnostics
  alias Crawler.Fetcher
  alias Crawler.Fetcher.AliasSettlement
  alias Crawler.Store
  alias Crawler.Store.Page

  @doc """
  Runs one crawl task and returns when the fetch and parse have finished.
  """
  def run(%AliasSettlement{} = job), do: AliasSettlement.run(job)

  def run(opts) do
    Logger.debug(fn -> "Running worker #{Diagnostics.crawl(opts)}" end)

    case Store.start_work(opts) do
      {:ok, claim} ->
        try do
          fetch = Fetcher.fetch(opts)

          fetch
          |> opts[:parser].parse()
          |> mark_processed()

          fetch
        catch
          kind, reason ->
            Logger.error(
              "Worker failed for #{Diagnostics.url(opts[:url])}: " <>
                Diagnostics.failure(kind, reason, __STACKTRACE__)
            )

            {:error, {kind, reason}}
        after
          Store.finish_claim(claim)
        end

      :deferred ->
        :deferred

      other ->
        Store.finish_work(opts[:scope], opts[:generation], false, opts[:queue])
        other
    end
  end

  defp mark_processed({:ok, %Page{url: url, opts: opts}}) do
    Store.complete_page({url, opts[:scope]}, opts[:generation], opts[:queue], opts[:alias_url])
  end

  defp mark_processed(_), do: nil
end
