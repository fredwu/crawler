defmodule Crawler.Example.GoogleSearch.UrlFilter do
  @moduledoc """
  Allows HTTPS pages on Google Search and GitHub without URL credentials.
  """

  @behaviour Crawler.Fetcher.UrlFilter.Spec

  alias Crawler.URL.Host

  def filter(url, _opts) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil}} when is_binary(host) ->
        {:ok, Host.fold(host) in ["www.google.com", "github.com"]}

      _ ->
        {:ok, false}
    end
  end

  def filter(_url, _opts), do: {:ok, false}
end
