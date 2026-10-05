defmodule Crawler.HTTP.BodyTooLarge do
  @moduledoc false

  defexception max_body: nil

  @impl true
  def message(%{max_body: max_body}), do: "response exceeded #{max_body} bytes"
end

defmodule Crawler.HTTP.UnsupportedEncoding do
  @moduledoc false

  defexception encoding: nil

  @impl true
  def message(%{encoding: encoding}), do: "unsupported content-encoding: #{encoding}"
end

defmodule Crawler.HTTP.Body do
  @moduledoc false

  @default_max 10_485_760

  def stream({:data, data}, {request, response}) do
    data = iodata(data)
    state = state(response) || open(response, max_body(request))

    case consume(state, data) do
      {:ok, state} ->
        {:cont, {request, put(response, state)}}

      {:stop, state} ->
        {:halt, {request, put(response, close(state))}}
    end
  end

  def finish({request, %Req.Response{} = response}) do
    case state(response) do
      nil ->
        {request, %{response | body: binary_body(response.body)}}

      %{overflow: true, max: max} = state ->
        close(state)
        Req.Request.halt(request, %Crawler.HTTP.BodyTooLarge{max_body: max})

      %{error: error} = state when not is_nil(error) ->
        close(state)
        Req.Request.halt(request, %Crawler.HTTP.UnsupportedEncoding{encoding: error})

      state ->
        finish_stream(request, response, state)
    end
  end

  def finish(result), do: result

  defp finish_stream(request, response, state) do
    case flush(state) do
      {:ok, state} ->
        close(state)
        {request, %{response | body: IO.iodata_to_binary(state.chunks)}}

      {:stop, state} ->
        close(state)
        halt_stream(request, state)
    end
  end

  defp halt_stream(request, %{overflow: true, max: max}) do
    Req.Request.halt(request, %Crawler.HTTP.BodyTooLarge{max_body: max})
  end

  defp halt_stream(request, state) do
    Req.Request.halt(request, %Crawler.HTTP.UnsupportedEncoding{encoding: state.error})
  end

  defp open(response, max) do
    case encoding(response) do
      :identity ->
        blank(max, :identity, nil)

      :gzip ->
        blank(max, :gzip, inflate_init(16 + 15))

      :deflate ->
        blank(max, :deflate, inflate_init(15))

      {:other, name} ->
        %{blank(max, :other, nil) | error: name}
    end
  end

  defp blank(max, encoding, zlib) do
    %{
      z: zlib,
      encoding: encoding,
      chunks: [],
      size: 0,
      max: max,
      overflow: false,
      error: nil,
      closed?: false,
      finished?: false
    }
  end

  defp inflate_init(window) do
    zlib = :zlib.open()
    :zlib.inflateInit(zlib, window)
    zlib
  end

  defp consume(%{error: error} = state, _data) when not is_nil(error), do: {:stop, state}

  defp consume(%{encoding: :identity} = state, data), do: take(state, data)

  defp consume(%{encoding: :other} = state, _data), do: {:stop, state}

  defp consume(state, data), do: pull(state, data)

  defp pull(state, data) do
    case next_output(state.z, data, state.encoding) do
      {:finished, output} ->
        take(%{state | finished?: true}, output)

      {:continue, output} ->
        continue(state, output, data)

      {:error, reason} ->
        {:stop, %{state | error: reason, chunks: []}}
    end
  end

  defp continue(state, output, data) do
    case take(state, output) do
      {:stop, state} -> {:stop, state}
      {:ok, state} -> more(state, output, data)
    end
  end

  defp more(state, output, data) do
    if IO.iodata_length(output) > 0 or data not in [<<>>, []],
      do: pull(state, []),
      else: {:ok, state}
  end

  defp next_output(zlib, data, encoding) do
    try do
      case :zlib.safeInflate(zlib, data) do
        {status, output} when status in [:finished, :continue] -> {status, output}
        {:need_dictionary, _output} -> {:error, Atom.to_string(encoding)}
      end
    catch
      _, _ -> {:error, Atom.to_string(encoding)}
    end
  end

  defp take(state, output) do
    size = state.size + IO.iodata_length(output)

    if size > state.max do
      {:stop, %{state | overflow: true, chunks: [], size: size}}
    else
      {:ok, %{state | chunks: [state.chunks, output], size: size}}
    end
  end

  defp flush(%{z: nil} = state), do: {:ok, state}

  defp flush(%{finished?: true} = state), do: commit(state)

  defp flush(state) do
    case pull(state, <<>>) do
      {:ok, %{finished?: true} = state} ->
        commit(state)

      {:ok, state} ->
        {:stop, %{state | error: Atom.to_string(state.encoding), chunks: []}}

      {:stop, state} ->
        {:stop, state}
    end
  end

  # `:zlib.safeInflate/2` returns `:finished` when the input is consumed. The gzip or zlib trailer is checked by `inflateEnd/1`.
  defp commit(state) do
    if trailer_ok?(state) do
      {:ok, state}
    else
      {:stop, %{state | error: Atom.to_string(state.encoding), chunks: []}}
    end
  end

  defp trailer_ok?(%{z: zlib}) do
    try do
      :zlib.inflateEnd(zlib)
      true
    catch
      _, _ -> false
    end
  end

  defp close(%{closed?: true} = state), do: state
  defp close(%{z: nil} = state), do: %{state | closed?: true}

  defp close(%{z: zlib} = state) do
    try do
      :zlib.inflateEnd(zlib)
    catch
      _, _ -> :ok
    end

    :zlib.close(zlib)
    %{state | z: nil, closed?: true}
  end

  defp encoding(response) do
    case Req.Response.get_header(response, "content-encoding") do
      [value | _] -> decode_encoding(value)
      _ -> :identity
    end
  end

  defp decode_encoding(value) do
    token =
      value
      |> String.downcase()
      |> String.split(",", parts: 2)
      |> hd()
      |> String.trim()

    case token do
      token when token in ["", "identity"] -> :identity
      token when token in ["gzip", "x-gzip"] -> :gzip
      "deflate" -> :deflate
      other -> {:other, other}
    end
  end

  defp max_body(request) do
    case Req.Request.get_option(request, :crawler_max_body) do
      max when is_integer(max) and max >= 0 -> max
      _ -> @default_max
    end
  end

  defp state(response), do: Req.Response.get_private(response, :crawler_body)

  defp put(response, state), do: Req.Response.put_private(response, :crawler_body, state)

  defp binary_body(body) when is_binary(body), do: body
  defp binary_body(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp binary_body(_body), do: <<>>

  defp iodata(data) when is_binary(data), do: data
  defp iodata(data) when is_list(data), do: IO.iodata_to_binary(data)
  defp iodata(nil), do: <<>>
  defp iodata(data), do: to_string(data)
end
