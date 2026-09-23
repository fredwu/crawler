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

    case Store.try_claim(opts[:scope], opts[:max_pages]) do
      :ok ->
        try do
          opts
          |> Fetcher.fetch()
          |> opts[:parser].parse()
          |> mark_processed()
        after
          Store.inflight_dec(opts[:scope])
        end

      :full ->
        :full
    end
  end

  defp mark_processed({:ok, %Page{url: url, opts: opts}}) do
    Store.ops_inc(opts[:scope])
    Store.processed({url, opts[:scope]})
    mark_alias(opts[:alias_url], opts[:scope])
  end

  defp mark_processed(_), do: nil

  defp mark_alias(alias_url, scope) when is_binary(alias_url) do
    Store.processed({alias_url, scope})
  end

  defp mark_alias(_alias_url, _scope), do: :ok
end
