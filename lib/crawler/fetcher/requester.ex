defmodule Crawler.Fetcher.Requester do
  @moduledoc """
  Makes HTTP requests.
  """

  alias Crawler.HTTP

  @fetch_opts [
    follow_redirect: true,
    max_redirect:    5,
  ]

  @doc """
  Makes HTTP requests via `Crawler.HTTP`.

  ## Examples

      iex> Requester.make(url: "fake.url", modifier: Crawler.Fetcher.Modifier)
      {:error, %HTTPoison.Error{id: nil, reason: :nxdomain}}
  """
  def make(opts) do
    HTTP.get(opts[:url], fetch_headers(opts), fetch_opts(opts))
  end

  defp fetch_headers(opts) do
    [{"User-Agent", opts[:user_agent]}] ++ opts[:modifier].headers(opts)
  end

  defp fetch_opts(opts) do
    @fetch_opts ++ [recv_timeout: opts[:timeout]] ++ opts[:modifier].opts(opts)
  end
end
