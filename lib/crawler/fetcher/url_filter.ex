defmodule Crawler.Fetcher.UrlFilter do
  @moduledoc """
  A placeholder module that lets all URLs pass through.
  """

  defmodule Spec do
    @moduledoc """
    Defines a URL filter.

    Return `{:ok, true}` to allow a URL or `{:ok, false}` to reject it with a
    policy warning. Return `{:error, reason}` when filtering fails. The initial
    URL's error is returned unchanged by the policer, fetcher, and worker.
    The default parser logs a fixed error message without the reason.
    """

    @type url :: String.t()
    @type opts :: map

    @callback filter(url, opts) :: {:ok, boolean} | {:error, term}
  end

  @behaviour __MODULE__.Spec

  @doc """
  Whether to pass through a given URL.

  - `true` for letting the url through
  - `false` for rejecting the url
  """
  def filter(_url, _opts), do: {:ok, true}
end
