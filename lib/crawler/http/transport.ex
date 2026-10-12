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
    outgoing = browser_pool(%{request | url: transport_uri})
    streaming = preserve_repeated_headers(outgoing)
    transported = wrap_callbacks(streaming, logical_uri)
    {returned, response} = Req.Steps.run_finch(transported)

    returned =
      returned
      |> restore_uri(transport_uri, uri)
      |> restore_callbacks(request)
      |> restore_pool_options(request)

    {returned, response}
  end

  # Mint rejects a request target that is not RFC 3986, including a literal
  # `|` or a bare `%`. A browser still sends those bytes. Skip that check
  # only for those targets, and only when the caller did not choose a Finch pool.
  defp browser_pool(request) do
    cond do
      not relaxed_target?(request.url) ->
        request

      Map.has_key?(request.options, :finch) ->
        request

      true ->
        request |> Req.Request.put_option(:finch, relaxed_finch(request)) |> drop_pool_options()
    end
  end

  defp drop_pool_options(request) do
    Req.Request.drop_options(request, [:connect_options, :pool_max_idle_time])
  end

  # A missing path is nil on the URI and `/` on the request line.
  defp relaxed_target?(%URI{} = uri) do
    uri = %{uri | path: uri.path || "/"}

    case Finch.Request.request_path(uri) do
      "" -> false
      target -> not mint_target?(target)
    end
  end

  defp mint_target?(<<>>), do: true

  defp mint_target?(<<"%", high, low, rest::binary>>) do
    hex?(high) and hex?(low) and mint_target?(rest)
  end

  defp mint_target?(<<byte, rest::binary>>) do
    URI.char_unescaped?(byte) and mint_target?(rest)
  end

  defp hex?(byte) when byte in ?0..?9 or byte in ?a..?f or byte in ?A..?F, do: true
  defp hex?(_byte), do: false

  defp relaxed_finch(request) do
    options = ipv6_options(request)
    pool_options = relaxed_pool_options(options)
    name = pool_name(pool_options)

    case DynamicSupervisor.start_child(Req.FinchSupervisor, finch_child(name, pool_options)) do
      {:ok, _pid} -> name
      {:error, {:already_started, _pid}} -> name
    end
  end

  defp ipv6_options(request) do
    if !request.options[:inet6] and (request.url.host || "") =~ ":" do
      Map.put(request.options, :inet6, true)
    else
      request.options
    end
  end

  defp relaxed_pool_options(options) do
    options
    |> Req.Finch.pool_options()
    |> Keyword.update(
      :conn_opts,
      [skip_target_validation: true],
      &Keyword.put(&1, :skip_target_validation, true)
    )
  end

  defp pool_name(pool_options) do
    hash =
      pool_options
      |> :erlang.term_to_binary()
      |> :erlang.md5()
      |> Base.url_encode64(padding: false)

    Module.concat(__MODULE__, "Pool_" <> hash)
  end

  defp finch_child(name, pool_options) do
    {Finch, name: name, pools: %{default: pool_options}}
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

  # Req follows a redirect with the request this hop returns. A pool chosen
  # for this target must not stay there, or the next host keeps it.
  defp restore_pool_options(returned, original) do
    Enum.reduce([:finch, :connect_options, :pool_max_idle_time, :inet6], returned, fn key,
                                                                                      request ->
      case Map.fetch(original.options, key) do
        {:ok, value} -> Req.Request.put_option(request, key, value)
        :error -> Req.Request.delete_option(request, key)
      end
    end)
  end

  defp encode(nil, _context), do: nil
  defp encode(text, context), do: Percent.encode(text, context)
end
