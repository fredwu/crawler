defmodule Crawler.Fetcher.UrlFilter do
  @moduledoc """
  A placeholder module that lets all URLs pass through.
  """

  defmodule Spec do
    @moduledoc """
    Spec for defining an url filter.
    """

    @type url  :: String.t
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
