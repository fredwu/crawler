defmodule Crawler.Fetcher.UrlFilter do
  @moduledoc """
  A placeholder module that let all URLs pass through.
  """

  @behaviour __MODULE__.Spec

  @doc """
  Whether to pass through a given URL.
    - `true` for letting the url through.
    - `false` for rejecting the url.
  """
  def filter(_url), do: {:ok, true}
end
