defmodule Crawler.HTTP do
  @moduledoc """
  Project-owned HTTP boundary.
  """

  defmodule RedirectRejected do
    @moduledoc false

    defexception [:url]

    @impl true
    def message(%{url: url}), do: "redirect rejected: #{url}"
  end

  alias Crawler.URL

  @redirect_statuses [301, 302, 303, 307, 308]

  def get(url, headers, opts, allow_redirect \\ fn _url -> true end) do
    opts
    |> Keyword.put(:url, url)
    |> Keyword.put(:headers, headers)
    |> Req.new()
    |> Req.Request.prepend_response_steps(crawler_redirect: &guard_redirect(&1, allow_redirect))
    |> Req.Request.append_response_steps(crawler_final_url: &capture_final_url/1)
    |> Req.request()
  end

  defp capture_final_url({request, %Req.Response{} = response}) do
    url =
      request.url
      |> drop_default_port()
      |> URI.to_string()

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
    next = next_url(request.url, location)

    if allowed_target?(next, allow) do
      {request, Req.Response.put_header(response, "location", next)}
    else
      Req.Request.halt(request, %RedirectRejected{url: display_url(next)})
    end
  end

  defp allowed_target?(url, allow) when is_function(allow, 1) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        allow.(url)

      _ ->
        false
    end
  end

  defp next_url(%URI{} = current, location) do
    case URL.resolve(location, URI.to_string(current)) do
      {:ok, url} -> url
      :skip -> location
    end
  rescue
    ArgumentError -> location
  end

  defp display_url(url) when is_binary(url), do: url
  defp display_url(url), do: inspect(url)

  defp drop_default_port(%URI{scheme: "http", port: 80} = uri), do: %{uri | port: nil}
  defp drop_default_port(%URI{scheme: "https", port: 443} = uri), do: %{uri | port: nil}
  defp drop_default_port(uri), do: uri
end
