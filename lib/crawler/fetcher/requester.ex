defmodule Crawler.Fetcher.Requester do
  @moduledoc """
  Makes HTTP requests.
  """

  alias Crawler.Cookies
  alias Crawler.Fetcher.UrlFilter
  alias Crawler.HTTP
  alias Crawler.HTTP.Body
  alias Crawler.Store

  @fetch_opts [
    redirect: true,
    max_redirects: 5,
    redirect_trusted: true,
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
    request = prepared_request(opts, modifier_opts)

    HTTP.get(
      opts[:url],
      request |> put_cookie(opts) |> Map.fetch!(:headers),
      fetch_opts(opts, modifier_opts, cookie_value(request)),
      &allow_redirect?(&1, opts)
    )
  end

  defp prepared_request(opts, modifier_opts) do
    Req.new(headers: [{"User-Agent", opts[:user_agent]}])
    |> Req.merge(headers: opts[:modifier].headers(opts))
    |> Req.merge(headers: Keyword.get(modifier_opts, :headers, []))
    |> Req.merge(headers: req_headers(opts))
    |> Req.Request.put_new_header("accept-encoding", "gzip, deflate")
  end

  defp req_headers(opts) do
    opts |> req_options() |> Keyword.get(:headers, [])
  end

  defp fetch_opts(opts, modifier_opts, user_cookie) do
    @fetch_opts
    |> Keyword.merge(timeout_opts(opts[:timeout]))
    |> Keyword.merge(Keyword.delete(modifier_opts, :headers))
    |> Keyword.merge(Keyword.delete(req_options(opts), :headers))
    |> Keyword.put(:into, &Body.stream/2)
    |> Keyword.put(:crawler_scope, opts[:scope])
    |> Keyword.put(:crawler_max_body, max_body(opts))
    |> Keyword.put(:crawler_user_cookie, user_cookie)
    |> Keyword.put(:crawler_generation, opts[:generation])
  end

  defp req_options(opts), do: opts[:req_options] || []

  defp max_body(opts) do
    case opts[:max_body] do
      max when is_integer(max) and max >= 0 -> max
      _ -> 10_485_760
    end
  end

  defp put_cookie(request, opts) do
    jar = Store.cookie_header(opts[:scope], opts[:url], opts[:generation])

    case Cookies.merge_header(cookie_value(request), jar) do
      nil -> request
      header -> Req.Request.put_header(request, "cookie", header)
    end
  end

  defp cookie_value(request) do
    case Req.Request.get_header(request, "cookie") do
      [] -> nil
      values -> Enum.join(values, "; ")
    end
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
