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
    opts = Store.bind_run(opts)
    Logger.debug(fn -> "Running worker #{Diagnostics.crawl(opts)}" end)

    case Store.start_work(opts) do
      {:ok, claim} ->
        try do
          fetch = Fetcher.fetch(opts)

          finish_parse(fetch, opts)
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

  defp finish_parse(fetch, opts) do
    result = opts[:parser].parse(fetch)
    completed = mark_processed(result, opts)

    if completed == :stale or not Store.current?(opts[:scope], opts[:generation], opts[:queue]) do
      {:warn, :stale}
    else
      fetch
    end
  end

  defp mark_processed({:ok, %Page{url: url, opts: page_opts}}, opts) do
    Store.complete_page(
      {url, opts[:scope]},
      opts[:generation],
      opts[:queue],
      page_opts[:alias_url],
      page_opts[:count_page] != false
    )
  end

  defp mark_processed(_result, _opts), do: nil
end
