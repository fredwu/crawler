defmodule Crawler.HTTP do
  @moduledoc """
  Project-owned HTTP boundary.

  Redirect logging defaults to disabled. Set `:redirect_log_level` explicitly
  to enable it. A redirect rebuilds `Cookie` for the next URL. The same host
  keeps the caller's `Cookie`, `Authorization`, and other custom headers when
  the scheme or port changes. Another host does not receive them.
  """

  defmodule RedirectRejected do
    @moduledoc false

    defexception [:url]

    @impl true
    def message(%{url: url}), do: "redirect rejected: #{url}"
  end

  defmodule InvalidURL do
    @moduledoc false

    defexception [:url]

    @impl true
    def message(%{url: url}), do: "invalid HTTP URL: #{url}"
  end

  alias Crawler.Cookies
  alias Crawler.HTTP.Body
  alias Crawler.HTTP.Transport
  alias Crawler.Store
  alias Crawler.URL

  @safe_redirect_headers ["user-agent", "accept", "accept-language", "accept-encoding"]

  @redirect_statuses [301, 302, 303, 307, 308]

  def get(url, headers, opts, allow_redirect \\ fn _url -> true end) do
    case URL.resolve(url, nil) do
      {:ok, target} -> request(target, headers, opts, allow_redirect)
      :skip -> {:error, %InvalidURL{url: url}}
    end
  end

  defp request(url, headers, opts, allow_redirect) do
    {explicit_headers, opts} = Keyword.pop(opts, :headers, [])
    {scope, opts} = Keyword.pop(opts, :crawler_scope)
    {max_body, opts} = Keyword.pop(opts, :crawler_max_body)
    {user_cookie, opts} = Keyword.pop(opts, :crawler_user_cookie)
    {generation, opts} = Keyword.pop(opts, :crawler_generation)

    opts
    |> Keyword.put_new(:redirect_log_level, false)
    |> Keyword.put(:url, url)
    |> Keyword.put(:headers, headers)
    |> Req.new()
    |> Req.Request.register_options([
      :crawler_scope,
      :crawler_max_body,
      :crawler_user_cookie,
      :crawler_generation
    ])
    |> Req.Request.merge_options(
      crawler_scope: scope,
      crawler_max_body: max_body,
      crawler_user_cookie: user_cookie,
      crawler_generation: generation
    )
    |> validate_redirect_option()
    |> Req.merge(headers: explicit_headers)
    |> Req.Request.append_request_steps(crawler_transport_adapter: &Transport.install/1)
    |> Req.Request.prepend_response_steps(crawler_redirect: &guard_redirect(&1, allow_redirect))
    |> Req.Request.prepend_response_steps(crawler_cookies: &capture_cookies/1)
    |> Req.Request.append_response_steps(crawler_final_url: &capture_final_url/1)
    |> Req.Request.append_response_steps(crawler_body: &Body.finish/1)
    |> Req.request()
  end

  defp validate_redirect_option(request) do
    if Map.has_key?(request.options, :follow_redirects) do
      raise ArgumentError, ":follow_redirects is not supported; use :redirect instead"
    end

    request
  end

  defp capture_final_url({request, %Req.Response{} = response}) do
    url = URI.to_string(request.url)

    {request, Req.Response.put_private(response, :crawler_url, url)}
  end

  defp capture_final_url(result), do: result

  # Runs before Req follows a redirect. The next address has to be one this
  # crawl is allowed to request, and the hop requests that normalized address.
  # A blank location is removed so Req does not request it. A spent redirect
  # budget stays with Req, which reports too many redirects and does not fetch
  # the next address. A hop that will not reach Body.finish/1 closes its inflate
  # streams here. A response that stays in this pipeline is left open.
  defp guard_redirect({request, %Req.Response{status: status} = response}, allow)
       when status in @redirect_statuses do
    cond do
      not redirect_enabled?(request) ->
        {request, response}

      hops_remaining?(request) ->
        review_location(request, response, allow)

      location_header?(response) ->
        {request, abandon_body(request, response)}

      true ->
        {request, response}
    end
  end

  defp guard_redirect(result, _allow), do: result

  defp redirect_enabled?(request) do
    Req.Request.get_option(request, :redirect, true) != false
  end

  # `:req_redirect_count` is the hop count Req stores on the inner request.
  defp hops_remaining?(request) do
    count = Req.Request.get_private(request, :req_redirect_count, 0)
    max = Req.Request.get_option(request, :max_redirects, 10)
    count < max
  end

  defp first_location(response) do
    case Req.Response.get_header(response, "location") do
      [location | _] when is_binary(location) ->
        if URL.sanitize(location) == "", do: nil, else: location

      _ ->
        nil
    end
  end

  defp location_header?(response) do
    match?([_ | _], Req.Response.get_header(response, "location"))
  end

  defp review_location(request, response, allow) do
    case first_location(response) do
      nil ->
        {request, Req.Response.delete_header(response, "location")}

      location ->
        review_redirect(request, response, location, allow)
    end
  end

  defp review_redirect(request, response, location, allow) do
    response = abandon_body(request, response)

    case URL.resolve(location, URI.to_string(request.url)) do
      {:ok, next} ->
        accepted_redirect(request, response, next, allow)

      :skip ->
        Req.Request.halt(request, %RedirectRejected{url: location})
    end
  end

  defp accepted_redirect(request, response, next, allow) do
    if allow.(next) do
      request = redirect_headers(request, next)
      {request, Req.Response.put_header(response, "location", next)}
    else
      Req.Request.halt(request, %RedirectRejected{url: next})
    end
  end

  defp abandon_body(request, response) do
    Body.release({request, response})
    response
  end

  defp capture_cookies({request, %Req.Response{} = response} = result) do
    scope = Req.Request.get_option(request, :crawler_scope)
    generation = Req.Request.get_option(request, :crawler_generation)
    headers = Req.Response.get_header(response, "set-cookie")

    if scope && headers != [] do
      Store.save_cookies(scope, URI.to_string(request.url), headers, generation)
    end

    result
  end

  defp capture_cookies(result), do: result

  defp redirect_headers(request, next) do
    request = if host_changed?(request.url, next), do: keep_headers(request), else: request
    put_cookie(request, next)
  end

  defp host_changed?(%URI{host: current}, next) when is_binary(current) do
    case URI.parse(next) do
      %URI{host: host} when is_binary(host) ->
        String.downcase(current) != String.downcase(host)

      _ ->
        true
    end
  end

  defp host_changed?(_current, _next), do: true

  defp keep_headers(request) do
    names =
      request.headers
      |> Req.Fields.get_list()
      |> Enum.map(fn {name, _value} -> name end)
      |> Enum.uniq()

    # Req reapplies `:auth` on the next hop. Drop it with the header so a new
    # host does not receive the credential.
    request = Req.Request.delete_option(request, :auth)

    Enum.reduce(names, request, fn name, request ->
      if String.downcase(to_string(name)) in @safe_redirect_headers do
        request
      else
        Req.Request.delete_header(request, name)
      end
    end)
  end

  defp put_cookie(request, url) do
    scope = Req.Request.get_option(request, :crawler_scope)
    generation = Req.Request.get_option(request, :crawler_generation)
    jar = scope && Store.cookie_header(scope, url, generation)

    case Cookies.merge_header(user_cookie(request, url), jar) do
      nil -> Req.Request.delete_header(request, "cookie")
      header -> Req.Request.put_header(request, "cookie", header)
    end
  end

  defp user_cookie(request, url) do
    if host_changed?(request.url, url) do
      nil
    else
      Req.Request.get_option(request, :crawler_user_cookie)
    end
  end
end
