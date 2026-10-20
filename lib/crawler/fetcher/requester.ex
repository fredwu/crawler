defmodule Crawler.Fetcher.Requester do
  @moduledoc """
  Makes HTTP requests.
  """

  alias Crawler.Cookies
  alias Crawler.Fetcher.UrlFilter
  alias Crawler.HTTP
  alias Crawler.HTTP.Body
  alias Crawler.Robots
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
  Caller `Authorization` and other custom headers stay on the seed hostname
  when the scheme or port changes. The caller `Cookie` also stays when the
  credential mode allows that origin. A same-origin request drops it when the
  scheme or port changes. Another hostname receives the safe headers and its
  own jar cookies. Jar cookies use the page that caused the request. A
  redirect keeps that page and applies the same credential mode on every hop.

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

    context = cookie_context(opts)

    fetch_opts
    |> Keyword.put(:into, &Body.stream/2)
    |> Keyword.put(:crawler_scope, opts[:scope])
    |> Keyword.put(:crawler_max_body, max_body(opts))
    |> Keyword.put(:crawler_user_cookie, user_cookie)
    |> Keyword.put(:crawler_generation, opts[:generation])
    |> Keyword.put(:crawler_cookie_site, context.site)
    |> Keyword.put(:crawler_cookie_navigation, context.navigation)
    |> Keyword.put(:crawler_cookie_credentials, context.credentials)
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
    context = cookie_context(opts)
    jar = Store.cookie_header(opts[:scope], opts[:url], opts[:generation], context)
    user_cookie = caller_cookie(opts[:url], context, user_cookie)

    case Cookies.merge_header(user_cookie, jar) do
      nil -> Req.Request.delete_header(request, "cookie")
      header -> Req.Request.put_header(request, "cookie", header)
    end
  end

  defp cookie_context(opts) do
    %{
      site: opts[:cookie_site] || opts[:url],
      navigation: Cookies.request_navigation?(opts),
      credentials: Cookies.credential_mode(opts)
    }
  end

  defp caller_cookie(url, context, user_cookie) do
    if Cookies.caller_cookie?(url, context), do: user_cookie
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

  # The next URL is part of this fetch. robots.txt itself may redirect to
  # another host's rules file. Every other hop has to be allowed for the
  # destination, including a sitemap file. Callers that never set
  # `:respect_robots` keep the previous URL-filter check.
  defp allow_redirect?(url, opts) do
    opts = opts |> Enum.into(%{}) |> Map.put(:url, url)

    cond do
      opts[:robots_fetch] == true ->
        http_url?(url)

      opts[:sitemap_fetch] == true ->
        http_url?(url) and robots_allow?(opts)

      true ->
        filter = opts[:url_filter] || UrlFilter
        match?({:ok, true}, filter.filter(url, opts)) and robots_allow?(opts)
    end
  end

  defp robots_allow?(opts) do
    opts[:respect_robots] != true or Robots.permitted?(opts)
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
