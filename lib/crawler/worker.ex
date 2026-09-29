defmodule Crawler.Worker do
  @moduledoc """
  Handles the crawl tasks.
  """

  require Logger

  alias Crawler.Fetcher
  alias Crawler.Store
  alias Crawler.Store.Page

  @doc """
  Runs one crawl task and returns when the fetch and parse have finished.
  """
  def run(opts) do
    Logger.debug("Running worker with opts: #{inspect(opts)}")

    case Store.try_claim(opts[:scope], opts[:max_pages], opts[:generation]) do
      :ok ->
        try do
          fetch = Fetcher.fetch(opts)

          fetch
          |> opts[:parser].parse()
          |> mark_processed()

          fetch
        catch
          kind, reason ->
            Logger.error(Exception.format(kind, reason, __STACKTRACE__))
            {:error, {kind, reason}}
        after
          Store.finish_work(opts[:scope], opts[:generation], true)
        end

      other ->
        Store.finish_work(opts[:scope], opts[:generation], false)
        other
    end
  end

  defp mark_processed({:ok, %Page{url: url, opts: opts}}) do
    Store.ops_inc(opts[:scope], opts[:generation])
    Store.processed({url, opts[:scope]}, opts[:generation])
    mark_alias(opts[:alias_url], opts)
  end

  defp mark_processed(_), do: nil

  defp mark_alias(alias_url, %{scope: scope, generation: generation}) when is_binary(alias_url) do
    Store.processed({alias_url, scope}, generation)
  end

  defp mark_alias(_alias_url, _opts), do: :ok
end
