defmodule Crawler.Charset.Encoding do
  @moduledoc false

  @utf8_bom <<0xEF, 0xBB, 0xBF>>
  @utf16be_bom <<0xFE, 0xFF>>
  @utf16le_bom <<0xFF, 0xFE>>
  @replacement <<0xEF, 0xBF, 0xBD>>

  @windows_1252 %{
    0x80 => 0x20AC,
    0x82 => 0x201A,
    0x83 => 0x0192,
    0x84 => 0x201E,
    0x85 => 0x2026,
    0x86 => 0x2020,
    0x87 => 0x2021,
    0x88 => 0x02C6,
    0x89 => 0x2030,
    0x8A => 0x0160,
    0x8B => 0x2039,
    0x8C => 0x0152,
    0x8E => 0x017D,
    0x91 => 0x2018,
    0x92 => 0x2019,
    0x93 => 0x201C,
    0x94 => 0x201D,
    0x95 => 0x2022,
    0x96 => 0x2013,
    0x97 => 0x2014,
    0x98 => 0x02DC,
    0x99 => 0x2122,
    0x9A => 0x0161,
    0x9B => 0x203A,
    0x9C => 0x0153,
    0x9E => 0x017E,
    0x9F => 0x0178
  }

  def bom(<<@utf8_bom, rest::binary>>), do: {:utf8, rest}
  def bom(<<@utf16be_bom, rest::binary>>), do: {:utf16, :big, rest}
  def bom(<<@utf16le_bom, rest::binary>>), do: {:utf16, :little, rest}
  def bom(_body), do: :none

  def decode_label(body, label) do
    case encoding(label) do
      :utf8 -> to_utf8(body)
      :windows_1252 -> windows_1252(body)
      {:utf16, endian} -> to_utf16(body, endian)
      :unknown -> to_utf8(body)
    end
  end

  def encoding("utf-8"), do: :utf8
  def encoding("utf8"), do: :utf8
  def encoding("windows-1252"), do: :windows_1252
  def encoding("iso-8859-1"), do: :windows_1252
  def encoding("latin1"), do: :windows_1252
  def encoding("latin-1"), do: :windows_1252
  def encoding("ascii"), do: :windows_1252
  def encoding("us-ascii"), do: :windows_1252
  def encoding("utf-16"), do: {:utf16, :big}
  def encoding("utf-16be"), do: {:utf16, :big}
  def encoding("utf-16le"), do: {:utf16, :little}
  def encoding(_label), do: :unknown

  def to_utf8(body), do: replace_invalid(body, :utf8, [])
  def to_utf16(body, endian), do: replace_invalid(body, {:utf16, endian}, [])

  defp replace_invalid(<<>>, _encoding, acc), do: IO.iodata_to_binary(acc)

  defp replace_invalid(body, encoding, acc) do
    case :unicode.characters_to_binary(body, encoding, :utf8) do
      utf8 when is_binary(utf8) ->
        IO.iodata_to_binary([acc, utf8])

      {:error, good, rest} ->
        replace_invalid(drop_bad(rest, encoding), encoding, [acc, good, @replacement])

      {:incomplete, good, _rest} ->
        IO.iodata_to_binary([acc, good, @replacement])
    end
  end

  defp drop_bad(<<_, rest::binary>>, :utf8), do: rest
  defp drop_bad(<<_, _, rest::binary>>, {:utf16, _endian}), do: rest
  defp drop_bad(_rest, _encoding), do: <<>>

  defp windows_1252(body) do
    for <<byte <- body>>, into: "" do
      <<win_codepoint(byte)::utf8>>
    end
  end

  defp win_codepoint(byte) when byte <= 0x7F or byte >= 0xA0, do: byte
  defp win_codepoint(byte), do: Map.get(@windows_1252, byte, 0xFFFD)
end
