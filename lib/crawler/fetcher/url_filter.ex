defmodule Crawler.Fetcher.UrlFilter do
  @moduledoc """
  A placeholder module that let all URLs pass through.
  """

  defmodule Spec do
    @moduledoc """
    Spec for defining an url filter.
    """

    @type url :: String.t

    @callback filter(url) :: {:ok, boolean} | {:error, term}
  end

  @behaviour __MODULE__.Spec

  @doc """
  Whether to pass through a given URL.
    - `true` for letting the url through.
    - `false` for rejecting the url.
  """
  def filter(_url), do: {:ok, true}
end
