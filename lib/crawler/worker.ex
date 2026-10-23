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
  def run(%Crawler.QueueTickets.Ticket{} = ticket) do
    with :ok <- Crawler.QueueTickets.ack(ticket),
         do: run_checked_out(Store.checkout_job(ticket.queue))
  end

  def run(opts),
    do:
      run_safely(opts, fn ->
        Crawler.Store.Execution.run_job(opts, &run_admitted(:fetch, &1))
      end)

  defp run_checked_out({:alias_settlement, ref, token, options, bytes}),
    do: AliasSettlement.run(ref, token, options, bytes)

  defp run_checked_out({:ok, claim, kind, opts}) do
    {result, origin} =
      try do
        {Crawler.Store.Execution.run(opts, fn owned -> run_admitted(kind, owned) end),
         :completion}
      catch
        caught, reason ->
          {worker_failed(opts, caught, reason, __STACKTRACE__), :local}
      end

    Store.complete_job(claim, Crawler.Store.Execution.outcome(result), origin)
    result
  end

  defp run_checked_out(other), do: other

  defp run_safely(opts, callback) do
    callback.()
  catch
    kind, reason ->
      worker_failed(opts, kind, reason, __STACKTRACE__)
  end

  defp worker_failed(opts, kind, reason, stacktrace) do
    Logger.error(
      "Worker failed for #{Diagnostics.url(opts[:url])}: " <>
        Diagnostics.failure(kind, reason, stacktrace)
    )

    {:error, {kind, reason}}
  end

  defp run_admitted(:fetch, opts) do
    case Fetcher.fetch(opts) do
      %Page{} = page ->
        parse_page(page, opts)

      other ->
        opts.parser.parse(other)
        other
    end
  end

  defp run_admitted(:sitemap, %{prepared_request: nil} = opts) do
    with {:ok, receipt} <- Store.reserve_resource(opts, :source, opts.max_frontier_bytes),
         {:ok, prepared} <- Crawler.Fetcher.Requester.prepare(opts),
         {:ok, bytes} <- Crawler.Store.Retained.bytes({opts, prepared}, opts.max_frontier_bytes),
         :ok <- Store.commit_resource(receipt, bytes),
         :ok <- Store.retain_resource(receipt, Process.whereis(Store)),
         :ok <- Store.prepare_control(opts, prepared, receipt) do
      {:error, :control_prepared}
    end
  end

  defp run_admitted(:sitemap, opts) do
    with {:ok, true} <- Crawler.Robots.permitted_result(opts),
         :ok <- Store.account_control_document(opts) do
      Crawler.Sitemap.execute(opts, opts.prepared_request)
    else
      {:ok, false} -> {:warn, :robots_blocked}
      error -> error
    end
  end

  defp run_admitted(:css_settlement, opts) do
    with {:ok, revision} <-
           Crawler.Parser.CssSheets.run_settlement(opts, opts.css_group, opts.css_revision),
         :ok <- Crawler.Export.Producer.refresh(opts),
         do: {:ok, revision}
  end

  defp parse_page(page, opts) do
    case opts.parser.parse(page) do
      {:error, _} = error ->
        error

      result ->
        parsed =
          case result do
            {:ok, %Page{} = parsed} -> parsed
            %Page{} = parsed -> parsed
            _ -> page
          end

        case Store.complete_page(
               {page.url, opts.scope},
               opts.generation,
               opts.queue,
               page.opts[:alias_url],
               false
             ) do
          :stale -> {:warn, :stale}
          {:error, _} = error -> error
          _ -> parsed
        end
    end
  end
end
