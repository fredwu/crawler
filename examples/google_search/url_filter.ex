defmodule Crawler.Example.GoogleSearch.UrlFilter do
  @moduledoc """
  We start with Google, then only crawls Github.
  """

  @behaviour Crawler.Fetcher.UrlFilter.Spec

  def filter("https://www.google.com" <> _, _opts), do: {:ok, true}
  def filter("https://github.com" <> _, _opts), do: {:ok, true}
  def filter(_url, _opts), do: {:ok, false}
end
