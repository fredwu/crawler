defmodule Crawler.Fetcher.Retrier do
  @moduledoc """
  Retries failed fetch results. Callback exceptions propagate to the worker.
  """

  defmodule Spec do
    @moduledoc """
    Spec for defining a fetch retrier.
    """

    @type fetch_url :: fun
    @type opts :: map

    @callback perform(fetch_url, opts) :: term
  end

  use Retry

  @behaviour __MODULE__.Spec

  @doc """
  More information: [https://github.com/safwank/ElixirRetry](https://github.com/safwank/ElixirRetry)
  """
  def perform(fetch_url, opts) do
    retry with: exponential_backoff() |> cap(1_000) |> Stream.take(retry_count(opts)),
          atoms: &retryable?/1,
          rescue_only: [] do
      fetch_url.()
    end
  end

  defp retryable?({:error, reason}), do: not terminal?(reason)
  defp retryable?(_result), do: false

  defp terminal?({kind, _detail}) when kind in [:limit, :deadline], do: true

  defp terminal?(reason)
       when reason in [
              :stale,
              :cancelled,
              :closed_export,
              :representation_deferred,
              :control_prepared
            ],
       do: true

  defp terminal?(%{reason: reason}), do: terminal?(reason)
  defp terminal?(_reason), do: false

  defp retry_count(%{retries: retries}) when is_integer(retries) and retries > 0, do: retries
  defp retry_count(_opts), do: 0
end
