defmodule Crawler.HTTP do
  @moduledoc """
  Project-owned HTTP boundary.

  Redirect logging defaults to disabled. Set `:redirect_log_level` explicitly
  to enable it.
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

  alias Crawler.HTTP.Transport
  alias Crawler.URL

  @redirect_statuses [301, 302, 303, 307, 308]

  def get(url, headers, opts, allow_redirect \\ fn _url -> true end) do
    case URL.resolve(url, nil) do
      {:ok, target} -> request(target, headers, opts, allow_redirect)
      :skip -> {:error, %InvalidURL{url: url}}
    end
  end

  defp request(url, headers, opts, allow_redirect) do
    {explicit_headers, opts} = Keyword.pop(opts, :headers, [])

    opts
    |> Keyword.put_new(:redirect_log_level, false)
    |> Keyword.put(:url, url)
    |> Keyword.put(:headers, headers)
    |> Req.new()
    |> validate_redirect_option()
    |> Req.merge(headers: explicit_headers)
    |> Req.Request.append_request_steps(crawler_transport_adapter: &Transport.install/1)
    |> Req.Request.prepend_response_steps(crawler_redirect: &guard_redirect(&1, allow_redirect))
    |> Req.Request.append_response_steps(crawler_final_url: &capture_final_url/1)
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
  # the next address.
  defp guard_redirect({request, %Req.Response{status: status} = response}, allow)
       when status in @redirect_statuses do
    if follow_redirects?(request) do
      case first_location(response) do
        nil -> {request, Req.Response.delete_header(response, "location")}
        location -> review_redirect(request, response, location, allow)
      end
    else
      {request, response}
    end
  end

  defp guard_redirect(result, _allow), do: result

  defp follow_redirects?(request) do
    Req.Request.get_option(request, :redirect, true) != false and hops_remaining?(request)
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

  defp review_redirect(request, response, location, allow) do
    case URL.resolve(location, URI.to_string(request.url)) do
      {:ok, next} ->
        if allow.(next) do
          {request, Req.Response.put_header(response, "location", next)}
        else
          Req.Request.halt(request, %RedirectRejected{url: next})
        end

      :skip ->
        Req.Request.halt(request, %RedirectRejected{url: location})
    end
  end
end
