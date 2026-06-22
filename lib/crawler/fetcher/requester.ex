defmodule Crawler.Fetcher.Requester do
  @moduledoc """
  Makes HTTP requests.
  """

  alias Crawler.HTTP

  @fetch_opts [
    redirect: true,
    max_redirects: 5,
    retry: false,
    decode_body: false
  ]

  @doc """
  Makes HTTP requests via `Crawler.HTTP`.

  ## Examples

      iex> adapter = fn request ->
      iex>   {request, Req.Response.new(status: 200, body: "ok")}
      iex> end
      iex> {:ok, response} = Requester.make(
      iex>   url: "http://example.com",
      iex>   user_agent: "Crawler",
      iex>   timeout: 100,
      iex>   modifier: Crawler.Fetcher.Modifier,
      iex>   req_options: [adapter: adapter]
      iex> )
      iex> response.status
      200
  """
  def make(opts) do
    HTTP.get(opts[:url], fetch_headers(opts), fetch_opts(opts))
  end

  defp fetch_headers(opts) do
    [{"User-Agent", opts[:user_agent]}] ++ opts[:modifier].headers(opts)
  end

  defp fetch_opts(opts) do
    @fetch_opts
    |> Keyword.merge(timeout_opts(opts[:timeout]))
    |> Keyword.merge(opts[:modifier].opts(opts))
    |> Keyword.merge(opts[:req_options] || [])
  end

  defp timeout_opts(timeout) when is_integer(timeout) or timeout == :infinity do
    [receive_timeout: timeout]
  end

  defp timeout_opts(_timeout), do: []
end
