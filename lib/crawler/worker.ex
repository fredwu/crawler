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
        fetch =
          try do
            fetch = Fetcher.fetch(opts)

            fetch
            |> opts[:parser].parse()
            |> mark_processed()

            fetch
          after
            Store.inflight_dec(opts[:scope], opts[:generation])
          end

        forget_unprocessed(opts, fetch)

      :full ->
        :full

      :stale ->
        :stale
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

  defp forget_unprocessed(_opts, {:warn, "Fetch failed check " <> _}), do: :ok
  defp forget_unprocessed(_opts, {:error, {:already_registered, _}}), do: :ok

  defp forget_unprocessed(opts, _fetch) do
    key = {opts[:url], opts[:scope]}

    case Store.find(key) do
      %Page{processed: true} -> :ok
      nil -> :ok
      _page -> Store.delete(key, opts[:generation])
    end
  end
end
