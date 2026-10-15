defmodule Crawler.ImportMap.JSON do
  @moduledoc false

  def decode(input) when is_binary(input) do
    input = String.trim_leading(input, "\uFEFF")

    case value(skip(input)) do
      {:ok, decoded, rest} ->
        if skip(rest) == "", do: {:ok, decoded}, else: :error

      :error ->
        :error
    end
  end

  def decode(_input), do: :error

  def decode_located(input) when is_binary(input) do
    {input, shift} = strip_bom(input)
    size = byte_size(input) + shift

    case located_value(skip(input), size) do
      {:ok, decoded, rest} ->
        if skip(rest) == "", do: {:ok, decoded}, else: :error

      :error ->
        :error
    end
  end

  def decode_located(_input), do: :error

  # JSON objects keep the last duplicate key. The first key stays in place.
  def collapse_pairs(pairs) do
    values = Enum.reduce(pairs, %{}, fn {key, value}, acc -> Map.put(acc, key, value) end)

    pairs
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(fn key -> {key, Map.fetch!(values, key)} end)
  end

  defp strip_bom(<<"\uFEFF", rest::binary>>), do: {rest, 3}
  defp strip_bom(input), do: {input, 0}

  defp located_value(<<?", _rest::binary>> = input, size) do
    start = size - byte_size(input)

    case take_string(input) do
      {:ok, value, rest} ->
        {:ok, {:str, value, start, byte_size(input) - byte_size(rest)}, rest}

      :error ->
        :error
    end
  end

  defp located_value(<<"{", rest::binary>>, size), do: located_object(skip(rest), size, [])
  defp located_value(<<"[", rest::binary>>, size), do: located_array(skip(rest), size, [])
  defp located_value(<<"null", rest::binary>>, _size), do: {:ok, nil, rest}
  defp located_value(<<"true", rest::binary>>, _size), do: {:ok, true, rest}
  defp located_value(<<"false", rest::binary>>, _size), do: {:ok, false, rest}

  defp located_value(<<char, _rest::binary>> = input, _size) when char in ~c"-0123456789" do
    number(input)
  end

  defp located_value(_input, _size), do: :error

  defp located_object(<<"}", rest::binary>>, _size, []), do: {:ok, {:object, []}, rest}

  defp located_object(input, size, acc) do
    with {:ok, key, rest} <- key(input),
         {:ok, rest} <- colon(skip(rest)),
         {:ok, decoded, rest} <- located_value(skip(rest), size) do
      case skip(rest) do
        <<",", rest::binary>> ->
          located_object(skip(rest), size, [{key, decoded} | acc])

        <<"}", rest::binary>> ->
          pairs = [{key, decoded} | acc] |> Enum.reverse() |> collapse_pairs()
          {:ok, {:object, pairs}, rest}

        _rest ->
          :error
      end
    else
      _other -> :error
    end
  end

  defp located_array(<<"]", rest::binary>>, _size, []), do: {:ok, [], rest}

  defp located_array(input, size, acc) do
    with {:ok, decoded, rest} <- located_value(input, size) do
      case skip(rest) do
        <<",", rest::binary>> -> located_array(skip(rest), size, [decoded | acc])
        <<"]", rest::binary>> -> {:ok, Enum.reverse([decoded | acc]), rest}
        _rest -> :error
      end
    else
      _other -> :error
    end
  end

  defp take_string(<<?", rest::binary>>) do
    case string(rest, []) do
      {:ok, value, rest} -> {:ok, value, rest}
      :error -> :error
    end
  end

  defp value(<<"null", rest::binary>>), do: {:ok, nil, rest}
  defp value(<<"true", rest::binary>>), do: {:ok, true, rest}
  defp value(<<"false", rest::binary>>), do: {:ok, false, rest}
  defp value(<<"{", rest::binary>>), do: object(skip(rest), [])
  defp value(<<"[", rest::binary>>), do: array(skip(rest), [])
  defp value(<<?", rest::binary>>), do: string(rest, [])
  defp value(<<char, _rest::binary>> = input) when char in ~c"-0123456789", do: number(input)
  defp value(_input), do: :error

  defp object(<<"}", rest::binary>>, []), do: {:ok, {:object, []}, rest}

  defp object(input, acc) do
    with {:ok, key, rest} <- key(input),
         {:ok, rest} <- colon(skip(rest)),
         {:ok, decoded, rest} <- value(skip(rest)) do
      case skip(rest) do
        <<",", rest::binary>> -> object(skip(rest), [{key, decoded} | acc])
        <<"}", rest::binary>> -> {:ok, {:object, Enum.reverse([{key, decoded} | acc])}, rest}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  defp array(<<"]", rest::binary>>, []), do: {:ok, [], rest}

  defp array(input, acc) do
    with {:ok, decoded, rest} <- value(input) do
      case skip(rest) do
        <<",", rest::binary>> -> array(skip(rest), [decoded | acc])
        <<"]", rest::binary>> -> {:ok, Enum.reverse([decoded | acc]), rest}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  defp key(<<?", rest::binary>>), do: string(rest, [])
  defp key(_input), do: :error

  defp colon(<<":", rest::binary>>), do: {:ok, rest}
  defp colon(_input), do: :error

  defp string(<<?", rest::binary>>, acc), do: {:ok, IO.iodata_to_binary(Enum.reverse(acc)), rest}
  defp string(<<"\\\"", rest::binary>>, acc), do: string(rest, [?" | acc])
  defp string(<<"\\\\", rest::binary>>, acc), do: string(rest, [?\\ | acc])
  defp string(<<"\\/", rest::binary>>, acc), do: string(rest, [?/ | acc])
  defp string(<<"\\b", rest::binary>>, acc), do: string(rest, [?\b | acc])
  defp string(<<"\\f", rest::binary>>, acc), do: string(rest, [?\f | acc])
  defp string(<<"\\n", rest::binary>>, acc), do: string(rest, [?\n | acc])
  defp string(<<"\\r", rest::binary>>, acc), do: string(rest, [?\r | acc])
  defp string(<<"\\t", rest::binary>>, acc), do: string(rest, [?\t | acc])

  defp string(<<"\\u", hex::binary-size(4), rest::binary>>, acc) do
    case code_unit(hex) do
      {:ok, high} when high in 0xD800..0xDBFF ->
        surrogate_pair(high, rest, acc)

      {:ok, low} when low in 0xDC00..0xDFFF ->
        :error

      {:ok, code} ->
        string(rest, [<<code::utf8>> | acc])

      :error ->
        :error
    end
  end

  defp string(<<char::utf8, rest::binary>>, acc) when char >= 0x20 do
    string(rest, [<<char::utf8>> | acc])
  end

  defp string(_input, _acc), do: :error

  defp number(input) do
    case Regex.run(~r/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/, input) do
      [text] ->
        rest_size = byte_size(input) - byte_size(text)
        {:ok, parse_number(text), binary_part(input, byte_size(text), rest_size)}

      _ ->
        :error
    end
  end

  defp parse_number(text) do
    if String.contains?(text, ".") or String.contains?(text, "e") or String.contains?(text, "E") do
      case Float.parse(text) do
        {value, ""} -> value
        :error -> :non_finite
      end
    else
      String.to_integer(text)
    end
  end

  defp surrogate_pair(high, <<"\\u", hex::binary-size(4), rest::binary>>, acc) do
    case code_unit(hex) do
      {:ok, low} when low in 0xDC00..0xDFFF ->
        code = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
        string(rest, [<<code::utf8>> | acc])

      _ ->
        :error
    end
  end

  defp surrogate_pair(_high, _rest, _acc), do: :error

  defp code_unit(hex) do
    if hex =~ ~r/^[0-9a-fA-F]{4}$/, do: {:ok, String.to_integer(hex, 16)}, else: :error
  end

  defp skip(<<char, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r], do: skip(rest)
  defp skip(rest), do: rest
end
