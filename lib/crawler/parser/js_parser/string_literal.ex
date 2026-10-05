defmodule Crawler.Parser.JsParser.StringLiteral do
  @moduledoc false

  @escapes %{?b => "\b", ?f => "\f", ?n => "\n", ?r => "\r", ?t => "\t", ?v => <<11>>}

  def decode(source), do: decode(source, [])

  defp decode(<<>>, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp decode(<<"\\\r\n", rest::binary>>, acc), do: decode(rest, acc)

  defp decode(<<?\\, char::utf8, rest::binary>>, acc)
       when char in [?\n, ?\r, 0x2028, 0x2029],
       do: decode(rest, acc)

  defp decode(<<"\\x", digits::binary-size(2), rest::binary>>, acc) do
    with {:ok, code} <- hex(digits) do
      decode(rest, [<<code::utf8>> | acc])
    end
  end

  defp decode(<<"\\u{", rest::binary>>, acc) do
    case :binary.match(rest, "}") do
      {length, 1} when length > 0 ->
        digits = binary_part(rest, 0, length)
        rest = binary_part(rest, length + 1, byte_size(rest) - length - 1)

        with {:ok, code} <- codepoint(digits) do
          decode(rest, [<<code::utf8>> | acc])
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp decode(<<"\\u", digits::binary-size(4), rest::binary>>, acc) do
    with {:ok, code} <- hex(digits) do
      unicode(code, rest, acc)
    end
  end

  defp decode(<<"\\0", digit, _rest::binary>>, _acc) when digit in ?0..?9, do: :error
  defp decode(<<"\\0", rest::binary>>, acc), do: decode(rest, [<<0>> | acc])

  defp decode(<<?\\, char, _rest::binary>>, _acc) when char in [?u, ?x] or char in ?1..?9,
    do: :error

  defp decode(<<?\\, char::utf8, rest::binary>>, acc) do
    decode(rest, [Map.get(@escapes, char, <<char::utf8>>) | acc])
  end

  defp decode(<<?\\, _rest::binary>>, _acc), do: :error
  defp decode(<<char, rest::binary>>, acc), do: decode(rest, [<<char>> | acc])

  defp unicode(high, <<"\\u", digits::binary-size(4), rest::binary>>, acc)
       when high in 0xD800..0xDBFF do
    with {:ok, low} <- hex(digits),
         true <- low in 0xDC00..0xDFFF do
      code = 0x10000 + (high - 0xD800) * 0x400 + low - 0xDC00
      decode(rest, [<<code::utf8>> | acc])
    else
      _ -> :error
    end
  end

  defp unicode(code, rest, acc) do
    if scalar?(code), do: decode(rest, [<<code::utf8>> | acc]), else: :error
  end

  defp codepoint(digits) do
    digits = String.trim_leading(digits, "0")
    digits = if digits == "", do: "0", else: digits

    with true <- byte_size(digits) <= 6,
         {:ok, code} <- hex(digits),
         true <- scalar?(code) do
      {:ok, code}
    else
      _ -> :error
    end
  end

  defp scalar?(code), do: code <= 0x10FFFF and code not in 0xD800..0xDFFF

  defp hex(digits) do
    if Enum.all?(:binary.bin_to_list(digits), &(&1 in ?0..?9 or &1 in ?a..?f or &1 in ?A..?F)) do
      {:ok, String.to_integer(digits, 16)}
    else
      :error
    end
  end
end
