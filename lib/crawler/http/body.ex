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

  alias Crawler.Deadline
  alias Crawler.HTTP.BodyLimitExceeded
  alias Crawler.HTTP.DeadlineExceeded

  @default_max 10_485_760
  # These caps bound header tokenization and native decoder allocation before body decoding.
  @max_content_encoding_bytes 8192
  @max_content_encoding_layers 8

  def stream({:data, data}, {request, response}) do
    case check_deadline(request, response) do
      :ok -> stream_data(data, request, response)
      {:error, error} -> {:halt, Req.Request.halt(request, error)}
    end
  end

  defp stream_data(data, request, response) do
    data = iodata(data)
    state = state(response) || open(response, max_body(request), deadline(request))

    case consume(state, data) do
      {:ok, state} ->
        {:cont, {request, put(response, state)}}

      {:stop, state} ->
        {:halt, {request, put(response, close(state))}}
    end
  end

  def finish({request, %Req.Response{} = response}) do
    case state(response) do
      %{overflow: true} = state ->
        close(state)
        halt_stream(request, state)

      %{error: error} = state when not is_nil(error) ->
        close(state)
        halt_stream(request, state)

      state ->
        finish_response(request, response, state)
    end
  end

  def finish(result), do: result

  def check_deadline(request, response) do
    case check(deadline(request)) do
      :ok ->
        :ok

      {:error, {:deadline, kind}} ->
        release({request, response})
        {:error, %DeadlineExceeded{kind: kind, reason: {:deadline, kind}}}
    end
  end

  defp finish_response(request, response, state) do
    case check_deadline(request, response) do
      :ok when is_nil(state) -> finish_unstreamed(request, response)
      :ok -> finish_stream(request, response, state)
      {:error, error} -> Req.Request.halt(request, error)
    end
  end

  # Redirect hops and failed transfers never reach finish/1.
  def release({_request, %Req.Response{} = response}) do
    response
    |> state()
    |> release_state()
  end

  def release(_other), do: :ok

  defp finish_unstreamed(request, response) do
    state = open(response, max_body(request), deadline(request))

    case consume(state, body_data(response.body)) do
      {:ok, state} ->
        finish_stream(request, response, state)

      {:stop, state} ->
        close(state)
        halt_stream(request, state)
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

        case check_deadline(request, response) do
          :ok -> {request, %{response | body: IO.iodata_to_binary(state.chunks)}}
          {:error, error} -> Req.Request.halt(request, error)
        end

      {:stop, state} ->
        close(state)
        halt_stream(request, state)
    end
  end

  defp halt_stream(request, %{overflow: true, max: max}) do
    Req.Request.halt(request, %Crawler.HTTP.BodyTooLarge{max_body: max})
  end

  defp halt_stream(request, %{error: {:limit, key}}) do
    Req.Request.halt(request, %BodyLimitExceeded{
      key: key,
      limit: encoding_limit(key),
      reason: {:limit, key}
    })
  end

  defp halt_stream(request, %{error: {:deadline, kind}}) do
    Req.Request.halt(request, %DeadlineExceeded{kind: kind, reason: {:deadline, kind}})
  end

  defp halt_stream(request, state) do
    Req.Request.halt(request, %Crawler.HTTP.UnsupportedEncoding{encoding: state.error})
  end

  defp open(response, max, deadline) do
    case codings(response) do
      {:error, name} ->
        %{blank(max, deadline) | error: name}

      [] ->
        blank(max, deadline)

      codings ->
        layers = Enum.map(codings, &init_layer(&1, deadline))
        %{blank(max, deadline) | layers: layers, encoding: hd(layers).encoding}
    end
  end

  defp blank(max, deadline) do
    %{
      layers: [],
      deadline: deadline,
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

  defp init_layer(:gzip, deadline), do: layer(:gzip, 16 + 15, deadline)
  defp init_layer(:deflate, deadline), do: layer(:deflate, 15, deadline)

  defp layer(encoding, window, deadline) do
    %{
      z: inflate_init(window),
      encoding: encoding,
      deadline: deadline,
      finished?: false,
      produced: 0
    }
  end

  # RFC 9110 applies content-codings in listed order, so the last one is outermost.
  defp codings(response) do
    headers = Req.Response.get_header(response, "content-encoding")

    case encoding_header_size(headers, 0, 0) do
      :ok ->
        headers
        |> Enum.flat_map(&split_codings/1)
        |> decode_codings([], 0)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp encoding_header_size([], _size, _count), do: :ok

  defp encoding_header_size([value | rest], size, count) do
    size = size + byte_size(value) + if(count == 0, do: 0, else: 1)

    if size > @max_content_encoding_bytes do
      {:error, {:limit, :content_encoding_bytes}}
    else
      encoding_header_size(rest, size, count + 1)
    end
  end

  defp split_codings(value) do
    value
    |> String.downcase()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
  end

  defp decode_codings([], acc, _count), do: acc

  defp decode_codings([token | rest], acc, count) when token in ["", "identity"],
    do: decode_codings(rest, acc, count)

  defp decode_codings([token | rest], acc, count) do
    case classify_coding(token) do
      {:ok, _coding} when count == @max_content_encoding_layers ->
        {:error, {:limit, :content_encoding_layers}}

      {:ok, coding} ->
        decode_codings(rest, [coding | acc], count + 1)

      {:error, name} ->
        {:error, name}
    end
  end

  defp encoding_limit(:content_encoding_bytes), do: @max_content_encoding_bytes
  defp encoding_limit(:content_encoding_layers), do: @max_content_encoding_layers

  defp classify_coding("gzip"), do: {:ok, :gzip}
  defp classify_coding("x-gzip"), do: {:ok, :gzip}
  defp classify_coding("deflate"), do: {:ok, :deflate}
  defp classify_coding(other), do: {:error, other}

  # `:finished` means this input was consumed, not that the member is closed.
  # A later chunk still belongs to the same decoder.
  defp step([layer | rest], data, max) do
    case next_output(layer, data) do
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
    case next_output(layer, data) do
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
        {:ok, [acc, output], layer}

      IO.iodata_length(output) > 0 or data not in [<<>>, []] ->
        drain_layer(layer, <<>>, max, [acc, output])

      true ->
        {:ok, acc, layer}
    end
  end

  defp all_finished?(layers), do: Enum.all?(layers, & &1.finished?)

  defp inflate_init(window) do
    zlib = :zlib.open()
    :zlib.inflateInit(zlib, window)
    zlib
  end

  defp consume(%{overflow: true} = state, _data), do: {:stop, state}
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

  defp next_output(layer, data) do
    case check(layer.deadline) do
      :ok -> inflate(layer.z, data, layer.encoding)
      {:error, reason} -> {:error, reason}
    end
  end

  defp inflate(zlib, data, encoding) do
    try do
      case :zlib.safeInflate(zlib, data) do
        {status, output} when status in [:finished, :continue] -> {status, output}
        {:need_dictionary, _dictionary, _output} -> {:error, Atom.to_string(encoding)}
      end
    catch
      _, _ -> {:error, Atom.to_string(encoding)}
    end
  end

  defp take(state, output) do
    case check(state.deadline) do
      :ok -> take_output(state, output)
      {:error, reason} -> {:stop, %{state | error: reason, chunks: []}}
    end
  end

  defp take_output(state, output) do
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

  defp deadline(request), do: Req.Request.get_option(request, :crawler_deadline)

  defp check(nil), do: :ok
  defp check(%Deadline{} = deadline), do: Deadline.check(deadline)

  defp state(response), do: Req.Response.get_private(response, :crawler_body)

  defp put(response, state), do: Req.Response.put_private(response, :crawler_body, state)

  defp body_data(body) when is_binary(body) or is_list(body), do: body
  defp body_data(_body), do: <<>>

  defp iodata(data) when is_binary(data) or is_list(data), do: data
  defp iodata(nil), do: <<>>
  defp iodata(data), do: to_string(data)
end
