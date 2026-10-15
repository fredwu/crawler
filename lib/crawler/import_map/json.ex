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
