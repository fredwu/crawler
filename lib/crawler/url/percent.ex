defmodule Crawler.URL.Percent do
  @moduledoc false

  defguardp is_hex(byte) when byte in ?0..?9 or byte in ?a..?f or byte in ?A..?F

  @doc false
  def canonicalize(text) when is_binary(text) do
    text
    |> scan(<<>>, [])
    |> IO.iodata_to_binary()
  end

  @doc false
  def lowercase_hex(text) when is_binary(text) do
    text
    |> lower_hex([])
    |> IO.iodata_to_binary()
  end

  defp scan(<<>>, pending, acc), do: [acc, flush(pending)]

  defp scan(<<"%", high, low, rest::binary>>, pending, acc) when is_hex(high) and is_hex(low) do
    scan(rest, <<pending::binary, hex_byte(high, low)>>, acc)
  end

  defp scan(<<byte, rest::binary>>, pending, acc) when byte < 0x80 do
    scan(rest, <<>>, [acc, flush(pending), raw_ascii(byte)])
  end

  defp scan(binary, pending, acc) do
    case take_utf8(binary) do
      {:ok, char, rest} ->
        scan(rest, <<>>, [acc, flush(pending), char])

      :error ->
        <<byte, rest::binary>> = binary
        scan(rest, <<>>, [acc, flush(pending), percent(byte)])
    end
  end

  defp lower_hex(<<>>, acc), do: acc

  defp lower_hex(<<"%", high, low, rest::binary>>, acc) when is_hex(high) and is_hex(low) do
    lower_hex(rest, [acc, "%", lower_hex_digit(high), lower_hex_digit(low)])
  end

  defp lower_hex(<<byte, rest::binary>>, acc) do
    lower_hex(rest, [acc, byte])
  end

  defp flush(<<>>), do: []
  defp flush(bytes), do: emit(bytes, [])

  defp emit(<<>>, acc), do: acc

  defp emit(<<byte, rest::binary>>, acc) when byte < 0x80 do
    emit(rest, [acc, emit_ascii(byte)])
  end

  defp emit(bytes, acc) do
    case take_utf8(bytes) do
      {:ok, char, rest} ->
        emit(rest, [acc, char])

      :error ->
        <<byte, rest::binary>> = bytes
        emit(rest, [acc, percent(byte)])
    end
  end

  defp raw_ascii(0x20), do: "%20"
  defp raw_ascii(0x5C), do: "%5c"
  defp raw_ascii(byte), do: <<byte>>

  defp emit_ascii(byte) do
    if unreserved?(byte), do: <<byte>>, else: percent(byte)
  end

  defp unreserved?(byte) do
    byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in ~c"-._~"
  end

  defp percent(byte), do: "%" <> Base.encode16(<<byte>>, case: :lower)

  defp take_utf8(<<lead, _rest::binary>> = binary) do
    length = utf8_length(lead)

    if length > 1 and byte_size(binary) >= length do
      <<slice::binary-size(length), rest::binary>> = binary
      if utf8?(slice), do: {:ok, slice, rest}, else: :error
    else
      :error
    end
  end

  defp utf8_length(lead) when lead in 0xC2..0xDF, do: 2
  defp utf8_length(lead) when lead in 0xE0..0xEF, do: 3
  defp utf8_length(lead) when lead in 0xF0..0xF4, do: 4
  defp utf8_length(_lead), do: 0

  defp utf8?(slice), do: is_binary(:unicode.characters_to_binary(slice, :utf8))

  defp hex_byte(high, low), do: hex_value(high) * 16 + hex_value(low)

  defp hex_value(byte) when byte in ?0..?9, do: byte - ?0
  defp hex_value(byte) when byte in ?a..?f, do: byte - ?a + 10
  defp hex_value(byte) when byte in ?A..?F, do: byte - ?A + 10

  defp lower_hex_digit(byte) when byte in ?A..?F, do: byte + 32
  defp lower_hex_digit(byte), do: byte
end
