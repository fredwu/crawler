defmodule Crawler.Parser.CssParser.Identifier do
  @moduledoc false

  defguard name_byte(byte)
           when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in [?_, ?-] or
                  byte >= 128

  defguardp hex_byte(byte) when byte in ?0..?9 or byte in ?a..?f or byte in ?A..?F

  def take(body), do: take(body, [])

  defp take(<<byte, rest::binary>>, acc) when name_byte(byte) do
    take(rest, [byte | acc])
  end

  defp take(<<"\\", _rest::binary>> = body, acc) do
    {decoded, rest} = decode_escape(body)
    take(rest, [decoded | acc])
  end

  defp take(rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  @doc false
  def decode_escape(<<"\\", rest::binary>>) do
    case hex_digits(rest, 0, 0) do
      {value, count, tail} when count > 0 ->
        {codepoint(value), skip_space(tail)}

      _ ->
        escaped_character(rest)
    end
  end

  defp hex_digits(<<byte, rest::binary>>, value, count) when count < 6 and hex_byte(byte) do
    hex_digits(rest, value * 16 + hex_value(byte), count + 1)
  end

  defp hex_digits(rest, value, count), do: {value, count, rest}

  defp hex_value(byte) when byte in ?0..?9, do: byte - ?0
  defp hex_value(byte) when byte in ?a..?f, do: byte - ?a + 10
  defp hex_value(byte), do: byte - ?A + 10

  defp skip_space(<<"\r\n", rest::binary>>), do: rest
  defp skip_space(<<byte, rest::binary>>) when byte in [?\s, ?\t, ?\n, ?\r, ?\f], do: rest
  defp skip_space(rest), do: rest

  defp codepoint(value) when value > 0 and value <= 0x10FFFF and value not in 0xD800..0xDFFF,
    do: <<value::utf8>>

  defp codepoint(_value), do: <<0xFFFD::utf8>>

  defp escaped_character(<<char, _rest::binary>> = rest) when char in [?\n, ?\r, ?\f],
    do: {"\\", rest}

  defp escaped_character(<<char::utf8, rest::binary>>), do: {<<char::utf8>>, rest}
  defp escaped_character(<<byte, rest::binary>>), do: {<<byte>>, rest}
  defp escaped_character(<<>>), do: {"\\", ""}
end
