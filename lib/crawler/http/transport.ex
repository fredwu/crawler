defmodule Crawler.HTTP.Transport do
  @moduledoc false

  alias Crawler.HTTP.Stream
  alias Crawler.URL.Percent

  def install(request) do
    if request.adapter == (&__MODULE__.run/1) do
      request
    else
      request
      |> Req.Request.put_private(:crawler_transport_adapter, request.adapter)
      |> Map.put(:adapter, &__MODULE__.run/1)
    end
  end

  def run(request) do
    uri = request.url
    wire_uri = %{uri | path: encode(uri.path, :path), query: encode(uri.query, :query)}
    adapter = Req.Request.get_private(request, :crawler_transport_adapter)
    {returned, response} = dispatch(adapter, %{request | url: wire_uri}, uri)
    returned = returned |> restore_uri(wire_uri, uri) |> install()
    {returned, response}
  end

  defp dispatch(adapter, request, uri) when is_function(adapter, 1) do
    if adapter == (&Req.Steps.run_finch/1), do: finch(request, uri), else: adapter.(request)
  end

  defp dispatch({Req.Steps, :run_finch, []}, request, uri), do: finch(request, uri)

  defp dispatch({module, function, arguments}, request, _uri),
    do: apply(module, function, [request | arguments])

  defp finch(request, logical_uri) do
    uri = request.url
    transport_uri = finch_uri(uri)
    streaming = preserve_repeated_headers(request)
    transported = wrap_callbacks(%{streaming | url: transport_uri}, logical_uri)
    {returned, response} = Req.Steps.run_finch(transported)
    returned = restore_uri(returned, transport_uri, uri)
    {restore_callbacks(returned, request), response}
  end

  # Req's streamed Finch reducer stores each field with put_header, which keeps
  # only the last Set-Cookie or Link. Append instead, unless the caller already
  # replaced :finch_request.
  defp preserve_repeated_headers(request) do
    case {request.into, Req.Request.get_option(request, :finch_request)} do
      {callback, existing} when is_function(callback, 2) and not is_function(existing, 4) ->
        Req.Request.put_option(request, :finch_request, &Stream.stream/4)

      _other ->
        request
    end
  end

  defp finch_uri(%URI{query: ""} = uri) do
    # Finch drops a bare query marker. Put it in the transport path while
    # keeping the URI seen by callbacks and redirect steps unchanged.
    %{uri | path: (uri.path || "/") <> "?", query: nil}
  end

  defp finch_uri(uri), do: uri

  defp wrap_callbacks(request, uri) do
    request =
      case Req.Request.get_option(request, :finch_request) do
        callback when is_function(callback, 4) ->
          wrapped = fn request, finch, name, options ->
            callback.(%{request | url: uri}, finch, name, options)
          end

          Req.Request.put_option(request, :finch_request, wrapped)

        _ ->
          request
      end

    case request.into do
      callback when is_function(callback, 2) ->
        %{
          request
          | into: fn event, {request, response} ->
              callback.(event, {%{request | url: uri}, response})
            end
        }

      _ ->
        request
    end
  end

  defp restore_uri(%{url: transport_uri} = request, transport_uri, uri), do: %{request | url: uri}
  defp restore_uri(request, _transport_uri, _uri), do: request

  defp restore_callbacks(returned, original) do
    returned = %{returned | into: original.into}

    case Req.Request.get_option(original, :finch_request) do
      nil -> Req.Request.delete_option(returned, :finch_request)
      callback -> Req.Request.put_option(returned, :finch_request, callback)
    end
  end

  defp encode(nil, _context), do: nil
  defp encode(text, context), do: Percent.encode(text, context)
end
