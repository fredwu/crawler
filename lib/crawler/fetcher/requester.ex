defmodule Crawler.Fetcher.Requester do
  import Kernel, except: [send: 2]

  @moduledoc """
  Makes HTTP requests.
  """

  alias Crawler.Cookies
  alias Crawler.Fetcher.Requester.PreparedRequest
  alias Crawler.Fetcher.UrlFilter
  alias Crawler.HTTP
  alias Crawler.Limits
  alias Crawler.Robots

  @fetch_opts [
    redirect: true,
    max_redirects: 5,
    redirect_trusted: true,
    retry: false,
    decode_body: false
  ]
  @execution_fields [:scope, :generation, :queue, :execution_lease, :deadline, :crawler_deadline]

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
    case prepare(opts) do
      {:ok, prepared} -> send(prepared, opts |> Map.new() |> Map.take(@execution_fields))
      {:error, {:request_preparation, :unsupported_follow_redirects}} -> unsupported_redirect!()
      error -> error
    end
  end

  @doc false
  def call(opts), do: make(opts)

  @doc false
  def prepare(opts) do
    opts = Map.new(opts)
    cookie_limits = cookie_limits(opts)
    opts = Map.merge(opts, cookie_limits)
    modifier = opts[:modifier] || Crawler.Fetcher.Modifier
    modifier_opts = modifier.opts(opts)

    url =
      Keyword.get(opts[:req_options] || [], :url, Keyword.get(modifier_opts, :url, opts[:url]))

    with {:ok, url} <- HTTP.resolve_url(url) do
      request =
        Req.new(Keyword.take(Keyword.merge(modifier_opts, opts[:req_options] || []), [:plugins]))
        |> Req.Request.register_options(HTTP.options())
        |> Req.merge(@fetch_opts)
        |> Req.merge(timeout_opts(opts[:timeout]))
        |> Req.merge(url: opts[:url], headers: user_agent(opts))
        |> Req.merge(headers: modifier.headers(opts))
        |> Req.merge(Keyword.delete(modifier_opts, :plugins))
        |> Req.merge(Keyword.delete(opts[:req_options] || [], :plugins))
        |> Req.merge(url: url)
        |> Req.Request.put_new_header("accept-encoding", "gzip, deflate")
        |> Req.Request.merge_options(
          crawler_scope: opts[:scope],
          crawler_max_body: opts[:max_body],
          crawler_generation: opts[:generation],
          crawler_queue: opts[:queue],
          crawler_execution_lease: opts[:execution_lease],
          crawler_cookie_site: opts[:cookie_site] || opts[:url],
          crawler_cookie_navigation: Cookies.request_navigation?(opts),
          crawler_cookie_credentials: Cookies.credential_mode(opts),
          crawler_deadline: opts[:deadline] || opts[:crawler_deadline]
        )

      context = %PreparedRequest.Context{
        allow_redirect: fn url, execution_context ->
          allow_redirect?(url, Map.merge(opts, Map.take(execution_context, @execution_fields)))
        end,
        policy: policy(opts),
        cookie_partition: opts[:scope],
        cookie_limits: cookie_limits,
        opaque?: (opts[:url_filter] || UrlFilter) != UrlFilter
      }

      HTTP.prepare(request, opts[:site] || opts[:url], context)
    end
  rescue
    _exception -> {:error, {:request_preparation, :invalid_options}}
  end

  @doc false
  def prepare_http(url, headers, options, allow_redirect) do
    {effective_url, options} = Keyword.pop(options, :url, url)
    {cookie_options, options} = Keyword.split(options, Map.keys(Cookies.limits()))
    cookie_limits = cookie_limits(Map.new(cookie_options))

    with {:ok, target} <- HTTP.resolve_url(effective_url) do
      {headers_options, options} = Keyword.pop(options, :headers, [])
      {crawler_options, options} = Keyword.split(options, HTTP.options())
      {plugins, options} = Keyword.split(options, [:plugins])

      request =
        Req.new(plugins)
        |> Req.Request.register_options(HTTP.options())
        |> Req.merge(url: target, headers: headers)
        |> Req.merge(options)
        |> Req.merge(headers: headers_options)
        |> Req.Request.merge_options(crawler_options)

      context = %PreparedRequest.Context{
        allow_redirect: fn url, _execution_context -> allow_redirect.(url) end,
        policy: {:direct, allow_redirect},
        cookie_partition: crawler_options[:crawler_scope],
        cookie_limits: cookie_limits,
        opaque?: true
      }

      HTTP.prepare(request, crawler_options[:crawler_cookie_site] || url, context)
    end
  rescue
    _exception -> {:error, {:request_preparation, :invalid_options}}
  end

  @doc false
  def send(%PreparedRequest{} = prepared, execution_context \\ %{}) do
    HTTP.send(prepared, execution_context)
  end

  @doc false
  def bind_cookie_proof(%PreparedRequest{} = prepared, proof) do
    %{prepared | context: %{prepared.context | cookie_proof: proof}}
  end

  @doc false
  def reuse_disposition(%Req.Response{} = response) do
    case Req.Response.get_private(response, :crawler_reuse) do
      %PreparedRequest.ReuseDisposition{dependency: :initial, disposition: disposition} = receipt
      when disposition in [:candidate, :private] ->
        receipt

      %PreparedRequest.ReuseDisposition{
        dependency: {:redirect_jar, _proof},
        disposition: disposition
      } = receipt
      when disposition in [:candidate, :private] ->
        receipt

      _ ->
        private_disposition()
    end
  end

  defp private_disposition do
    %PreparedRequest.ReuseDisposition{
      dependency: :initial,
      disposition: :private,
      reason: :cookie_proof_unproven
    }
  end

  @doc false
  @spec unsupported_redirect!() :: no_return()
  def unsupported_redirect! do
    raise ArgumentError, ":follow_redirects is not supported; use :redirect instead"
  end

  defp user_agent(%{user_agent: agent}) when is_binary(agent), do: [{"user-agent", agent}]
  defp user_agent(_opts), do: []

  defp policy(opts) do
    filter = opts[:url_filter] || UrlFilter

    {
      filter,
      Crawler.Site.origin(opts[:site]),
      opts[:reference_tag] in [nil, "a", "area", "meta"],
      opts[:respect_robots] == true,
      opts[:robots_fetch] == true,
      opts[:sitemap_fetch] == true,
      opts[:user_agent],
      if(filter != UrlFilter, do: make_ref())
    }
  end

  defp cookie_limits(opts) do
    opts
    |> Limits.cookies()
    |> Limits.validate!(Cookies.limits())
    |> Limits.cookies()
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
        http_url?(url) and robots_redirect(opts)

      true ->
        filter = opts[:url_filter] || UrlFilter
        match?({:ok, true}, filter.filter(url, opts)) and robots_redirect(opts)
    end
  end

  defp robots_redirect(%{respect_robots: true} = opts) do
    case Robots.permitted_result(opts) do
      {:ok, allowed?} -> allowed?
      {:error, {kind, _}} = error when kind in [:limit, :deadline] -> error
      {:error, :stale} = error -> error
      _ -> false
    end
  end

  defp robots_redirect(_opts), do: true

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
