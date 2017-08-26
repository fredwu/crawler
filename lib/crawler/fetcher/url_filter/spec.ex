defmodule Crawler.Fetcher.UrlFilter.Spec do
  @moduledoc """
  Spec for defining an url filter.
  """

  @type url :: String.t

  @callback filter(url) :: {:ok, boolean} | {:error, term}
end
