defmodule Crawler.Fetcher.Requester do
  @moduledoc """
  Makes HTTP requests.
  """

  alias Crawler.HTTP

  @doc """
  Makes HTTP requests via `Crawler.HTTP`.

  ## Examples

      iex> Requester.make(url: "http://fake.url", modifier: Crawler.Fetcher.Modifier)
      {:error, "non-existing domain"}
  """
  def make(opts) do
    [
      {Tesla.Middleware.Timeout,
       timeout: opts[:timeout] || Crawler.Options.assign_defaults(%{})[:timeout]}
    ]
    |> Tesla.client()
    |> HTTP.get(opts[:url], [headers: fetch_headers(opts)] ++ opts(opts))
  end

  defp fetch_headers(opts) do
    [{"User-Agent", opts[:user_agent] || ""}] ++ opts[:modifier].headers(opts)
  end

  defp opts(opts) do
    [receive_timeout: opts[:timeout]] ++
      opts[:modifier].headers(opts) ++ opts[:modifier].opts(opts)
  end
end
