defmodule Crawler.Fetcher.AliasSettlement do
  @moduledoc false

  require Logger

  alias Crawler.Diagnostics
  alias Crawler.Fetcher.Recorder
  alias Crawler.Store

  def run(ref, token, options, bytes) do
    result =
      try do
        Crawler.Store.Execution.run(options, fn owned ->
          Store.settlement_payload(ref, token, owned, bytes, &store/2)
        end)
      catch
        kind, reason ->
          Store.finish_claim(token)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    try do
      with {:ok, _} <- result, do: Store.complete_settlement(ref, token)
    after
      reason =
        case result do
          {:error, reason} -> Crawler.Store.RunStatus.limit_reason(reason)
          _ -> nil
        end

      Store.finish_claim(token, reason)
    end
  end

  defp store(body, opts) do
    Recorder.maybe_store_page(body, opts)
  catch
    kind, reason ->
      Logger.error(
        "Alias settlement failed for #{Diagnostics.url(opts[:url])}: " <>
          Diagnostics.failure(kind, reason, __STACKTRACE__)
      )

      {:error, {kind, reason}}
  end
end
