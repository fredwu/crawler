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
  Caller `Cookie`, `Authorization`, and other custom headers stay on the seed
  hostname when the scheme or port changes. Another hostname receives the safe
  headers and its own jar cookies.

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
    {request, user_cookie, modifier_opts} = scope_credentials(request, opts, modifier_opts)

    HTTP.get(
      opts[:url],
      request |> put_cookie(opts, user_cookie) |> Map.fetch!(:headers),
      fetch_opts(opts, modifier_opts, user_cookie),
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
    fetch_opts =
      @fetch_opts
      |> Keyword.merge(timeout_opts(opts[:timeout]))
      |> Keyword.merge(Keyword.delete(modifier_opts, :headers))
      |> Keyword.merge(Keyword.delete(req_options(opts), :headers))

    fetch_opts =
      if credential_host?(opts), do: fetch_opts, else: Keyword.delete(fetch_opts, :auth)

    fetch_opts
    |> Keyword.put(:into, &Body.stream/2)
    |> Keyword.put(:crawler_scope, opts[:scope])
    |> Keyword.put(:crawler_max_body, max_body(opts))
    |> Keyword.put(:crawler_user_cookie, user_cookie)
    |> Keyword.put(:crawler_generation, opts[:generation])
  end

  # The seed host keeps caller headers when the scheme or port changes.
  # Another host gets its own jar cookies and the safe headers only.
  defp scope_credentials(request, opts, modifier_opts) do
    if credential_host?(opts) do
      {request, cookie_value(request), modifier_opts}
    else
      {HTTP.drop_caller_credentials(request), nil, Keyword.delete(modifier_opts, :auth)}
    end
  end

  defp credential_host?(opts) do
    url = to_string(opts[:url] || "")
    HTTP.same_host?(opts[:site] || url, url)
  end

  defp req_options(opts), do: opts[:req_options] || []

  defp max_body(opts) do
    case opts[:max_body] do
      max when is_integer(max) and max >= 0 -> max
      _ -> 10_485_760
    end
  end

  defp put_cookie(request, opts, user_cookie) do
    jar = Store.cookie_header(opts[:scope], opts[:url], opts[:generation])

    case Cookies.merge_header(user_cookie, jar) do
      nil -> Req.Request.delete_header(request, "cookie")
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
    if opts[:robots_fetch] == true or opts[:sitemap_fetch] == true do
      http_url?(url)
    else
      filter = opts[:url_filter] || UrlFilter
      opts = opts |> Enum.into(%{}) |> Map.put(:url, url)
      match?({:ok, true}, filter.filter(url, opts))
    end
  end

  defp http_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end
end
