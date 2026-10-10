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
        finish_unstreamed(request, response)

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

  # Redirect hops and failed transfers never reach finish/1.
  def release({_request, %Req.Response{} = response}) do
    response
    |> state()
    |> release_state()
  end

  def release(_other), do: :ok

  # No bytes arrived, so this does not open an inflate stream.
  defp finish_unstreamed(request, response) do
    case codings(response) do
      {:error, name} ->
        Req.Request.halt(request, %Crawler.HTTP.UnsupportedEncoding{encoding: name})

      [] ->
        {request, %{response | body: binary_body(response.body)}}

      [coding | _rest] ->
        Req.Request.halt(request, %Crawler.HTTP.UnsupportedEncoding{
          encoding: Atom.to_string(coding)
        })
    end
  end

  defp release_state(nil), do: :ok
  defp release_state(%{closed?: true}), do: :ok

  defp release_state(state) when is_map(state) do
    close(state)
    :ok
  end

  defp release_state(_state), do: :ok

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
    case codings(response) do
      {:error, name} ->
        %{blank(max) | error: name}

      [] ->
        blank(max)

      codings ->
        layers = Enum.map(codings, &init_layer/1)
        %{blank(max) | layers: layers, encoding: hd(layers).encoding}
    end
  end

  defp blank(max) do
    %{
      layers: [],
      encoding: :identity,
      chunks: [],
      size: 0,
      max: max,
      overflow: false,
      error: nil,
      closed?: false,
      finished?: false
    }
  end

  defp init_layer(:gzip), do: layer(:gzip, 16 + 15)
  defp init_layer(:deflate), do: layer(:deflate, 15)

  defp layer(encoding, window) do
    %{z: inflate_init(window), encoding: encoding, finished?: false, produced: 0}
  end

  # RFC 9110 applies content-codings in listed order, so the last one is outermost.
  defp codings(response) do
    response
    |> Req.Response.get_header("content-encoding")
    |> Enum.flat_map(&split_codings/1)
    |> Enum.reject(&(&1 in ["", "identity"]))
    |> Enum.reverse()
    |> decode_codings([])
  end

  defp split_codings(value) do
    value
    |> String.downcase()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
  end

  defp decode_codings([], acc), do: Enum.reverse(acc)

  defp decode_codings([token | rest], acc) do
    case classify_coding(token) do
      {:ok, coding} -> decode_codings(rest, [coding | acc])
      {:error, name} -> {:error, name}
    end
  end

  defp classify_coding("gzip"), do: {:ok, :gzip}
  defp classify_coding("x-gzip"), do: {:ok, :gzip}
  defp classify_coding("deflate"), do: {:ok, :deflate}
  defp classify_coding(other), do: {:error, other}

  # `:finished` means this input was consumed, not that the member is closed.
  # A later chunk still belongs to the same decoder.
  defp step([layer | rest], data, max) do
    case next_output(layer.z, data, layer.encoding) do
      {:error, reason} ->
        {:error, reason}

      {status, output} ->
        push(layer, rest, status, output, max)
    end
  end

  defp push(layer, rest, status, output, max) do
    chunk = IO.iodata_length(output)
    layer = %{layer | produced: layer.produced + chunk, finished?: status == :finished}

    if rest != [] and layer.produced > max do
      {:overflow, layer.produced, [layer | rest]}
    else
      case pipe(rest, output, max) do
        {:ok, final, rest} -> {status, final, [layer | rest]}
        {:overflow, produced, layers} -> {:overflow, produced, [layer | layers]}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp pipe([], data, _max), do: {:ok, data, []}

  defp pipe(layers, data, max) do
    case feed(layers, data, [], max) do
      {:ok, output, seen} -> {:ok, output, Enum.reverse(seen)}
      {:overflow, produced, seen, rest} -> {:overflow, produced, Enum.reverse(seen, rest)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp feed([], data, seen, _max), do: {:ok, data, seen}

  defp feed([layer | rest], data, seen, max) do
    case drain_layer(layer, data, max, []) do
      {:ok, output, layer} ->
        feed(rest, output, [layer | seen], max)

      {:overflow, produced, layer} ->
        {:overflow, produced, [layer | seen], rest}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp drain_layer(layer, data, max, acc) do
    case next_output(layer.z, data, layer.encoding) do
      {:error, reason} ->
        {:error, reason}

      {status, output} ->
        drain_output(layer, status, output, data, max, acc)
    end
  end

  defp drain_output(layer, status, output, data, max, acc) do
    produced = layer.produced + IO.iodata_length(output)
    layer = %{layer | produced: produced, finished?: layer.finished? or status == :finished}

    cond do
      produced > max ->
        {:overflow, produced, layer}

      status == :finished ->
        {:ok, IO.iodata_to_binary([acc, output]), layer}

      IO.iodata_length(output) > 0 or data not in [<<>>, []] ->
        drain_layer(layer, <<>>, max, [acc, output])

      true ->
        {:ok, IO.iodata_to_binary(acc), layer}
    end
  end

  defp all_finished?(layers), do: Enum.all?(layers, & &1.finished?)

  defp inflate_init(window) do
    zlib = :zlib.open()
    :zlib.inflateInit(zlib, window)
    zlib
  end

  defp consume(%{error: error} = state, _data) when not is_nil(error), do: {:stop, state}
  defp consume(%{layers: []} = state, data), do: take(state, data)
  defp consume(state, data), do: pull(state, data)

  defp pull(state, data) do
    case step(state.layers, data, state.max) do
      {:error, reason} ->
        {:stop, %{state | error: reason, chunks: []}}

      {:overflow, produced, layers} ->
        {:stop,
         %{state | layers: layers, overflow: true, chunks: [], size: max(state.size, produced)}}

      {status, output, layers} ->
        state = %{state | layers: layers, finished?: all_finished?(layers)}
        release(state, status, output, data)
    end
  end

  defp release(state, :finished, output, _data), do: take(state, output)
  defp release(state, :continue, output, data), do: continue(state, output, data)

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

  defp flush(%{layers: []} = state), do: {:ok, state}

  defp flush(%{finished?: true} = state), do: commit(state)

  defp flush(state) do
    case pull(state, <<>>) do
      {:ok, %{finished?: true} = state} ->
        commit(state)

      {:ok, state} ->
        {:stop, %{state | error: layer_name(state), chunks: []}}

      {:stop, state} ->
        {:stop, state}
    end
  end

  # `:zlib.safeInflate/2` returns `:finished` when the input is consumed. The gzip or zlib trailer is checked by `inflateEnd/1`.
  defp commit(state) do
    if Enum.all?(state.layers, &trailer_ok?/1) do
      {:ok, state}
    else
      {:stop, %{state | error: layer_name(state), chunks: []}}
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

  defp close(%{layers: layers} = state) do
    Enum.each(layers, &close_layer/1)
    %{state | layers: [], closed?: true}
  end

  defp close_layer(%{z: nil}), do: :ok

  defp close_layer(%{z: zlib}) do
    try do
      :zlib.inflateEnd(zlib)
    catch
      _, _ -> :ok
    end

    # :zlib.close/1 raises when this stream was already closed.
    try do
      :zlib.close(zlib)
    catch
      _, _ -> :ok
    end
  end

  defp layer_name(%{layers: [%{encoding: encoding} | _]}), do: Atom.to_string(encoding)
  defp layer_name(%{encoding: encoding}), do: Atom.to_string(encoding)

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
