defmodule Crawler.Fetcher.Requester do
  @moduledoc """
  Makes HTTP requests.
  """

  alias Crawler.HTTP

  @fetch_opts [
    follow_redirect: true,
    max_redirect:    5
  ]

  @doc """
  Makes HTTP requests via `Crawler.HTTP`.

  ## Examples

      iex> Requester.make(url: "fake_url")
      {:error, %HTTPoison.Error{id: nil, reason: :nxdomain}}
  """
  def make(opts) do
    HTTP.get(opts[:url], fetch_headers(opts), fetch_opts(opts))
  end

  defp fetch_headers(opts) do
    [{"User-Agent", opts[:user_agent]}]
  end

  defp fetch_opts(opts) do
    @fetch_opts ++ [
      recv_timeout: opts[:timeout]
    ]
  end
end
