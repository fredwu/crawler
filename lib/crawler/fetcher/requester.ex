defmodule Crawler.Fetcher.Requester do
  @moduledoc """
  Makes HTTP requests.
  """

  alias Crawler.Fetcher.UrlFilter
  alias Crawler.HTTP

  @fetch_opts [
    redirect: true,
    max_redirects: 5,
    retry: false,
    decode_body: false
  ]

  @doc """
  Makes HTTP requests via `Crawler.HTTP`.

  Header names are case-insensitive. Default headers are overridden by
  modifier headers, modifier options, and `:req_options` headers, in that order.
  Use `:redirect` to control redirects; `:follow_redirects` is not supported.

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
    modifier_opts = opts[:modifier].opts(opts)

    HTTP.get(
      opts[:url],
      fetch_headers(opts, modifier_opts),
      fetch_opts(opts, modifier_opts),
      &allow_redirect?(&1, opts)
    )
  end

  defp fetch_headers(opts, modifier_opts) do
    Req.new(headers: [{"User-Agent", opts[:user_agent]}])
    |> Req.merge(headers: opts[:modifier].headers(opts))
    |> Req.merge(headers: Keyword.get(modifier_opts, :headers, []))
    |> Map.fetch!(:headers)
  end

  defp fetch_opts(opts, modifier_opts) do
    @fetch_opts
    |> Keyword.merge(timeout_opts(opts[:timeout]))
    |> Keyword.merge(Keyword.delete(modifier_opts, :headers))
    |> Keyword.merge(opts[:req_options] || [])
  end

  defp timeout_opts(timeout) when is_integer(timeout) or timeout == :infinity do
    [receive_timeout: timeout]
  end

  defp timeout_opts(_timeout), do: []

  defp allow_redirect?(url, opts) do
    filter = opts[:url_filter] || UrlFilter
    opts = opts |> Enum.into(%{}) |> Map.put(:url, url)

    match?({:ok, true}, filter.filter(url, opts))
  end
end
