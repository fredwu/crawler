defmodule Crawler.Fetcher.Retrier do
  @moduledoc """
  Handles retries for failed crawls.
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
    retry with: exponential_backoff() |> cap(1_000) |> Stream.take(retry_count(opts)) do
      fetch_url.()
    after
      result -> result
    else
      error -> error
    end
  end

  defp retry_count(%{retries: retries}) when is_integer(retries) and retries > 0, do: retries
  defp retry_count(_opts), do: 0
end
