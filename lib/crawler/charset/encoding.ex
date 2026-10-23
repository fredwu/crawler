defmodule Crawler.Charset.Encoding do
  @moduledoc false

  alias Crawler.Analysis.Budget

  @chunk_bytes 256

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
    {:ok, decoded, _budget, _owned} = decode_result(body, encoding(label), Budget.unlimited())
    decoded
  end

  def decode_result(body, encoding, budget) do
    cond do
      encoding in [:utf8, :unknown] and String.valid?(body) -> unchanged(body, budget)
      encoding == :windows_1252 and ascii?(body) -> unchanged(body, budget)
      body == "" -> unchanged(body, budget)
      true -> convert(body, 0, encoding, [], 0, 0, 0, budget)
    end
  end

  defp unchanged(body, budget), do: {:ok, body, budget, 0}

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

  def to_utf8(body), do: decode_label(body, "utf-8")

  def to_utf16(body, endian) do
    {:ok, decoded, _budget, _owned} = decode_result(body, {:utf16, endian}, Budget.unlimited())
    decoded
  end

  defp convert(body, offset, _encoding, parts, size, count, owned, budget)
       when offset == byte_size(body) do
    scratch = Budget.cost(:binary) + max(size, owned) + Budget.cost(:list_cell, count)

    with {:ok, budget} <- Budget.reserve(budget, scratch) do
      decoded = parts |> Enum.reverse() |> IO.iodata_to_binary()
      retained = Budget.cost(:binary) + :binary.referenced_byte_size(decoded)

      with {:ok, budget} <- Budget.settle(budget, scratch, retained),
           {:ok, budget} <- Budget.refund(budget, owned),
           do: {:ok, decoded, budget, retained}
    end
  end

  defp convert(body, offset, encoding, parts, size, count, owned, budget) do
    length = min(@chunk_bytes, byte_size(body) - offset)
    bound = if match?({:utf16, _}, encoding), do: div(length + 1, 2) * 3 + 3, else: length * 3

    scratch =
      Budget.cost(:frame) + Budget.cost(:binary, 3) + bound * 2 +
        length * (Budget.cost(:binary, 2) + Budget.cost(:list_cell, 2))

    with {:ok, budget} <- Budget.reserve(budget, scratch) do
      chunk = binary_part(body, offset, length)
      {piece, consumed} = convert_chunk(chunk, encoding, offset + length == byte_size(body))
      piece_size = byte_size(piece)

      retained =
        Budget.cost(:binary) + :binary.referenced_byte_size(piece) + Budget.cost(:list_cell)

      with {:ok, budget} <- Budget.settle(budget, scratch, retained) do
        convert(
          body,
          offset + consumed,
          encoding,
          [piece | parts],
          size + piece_size,
          count + 1,
          owned + retained,
          budget
        )
      end
    end
  end

  defp convert_chunk(chunk, :windows_1252, _final?) do
    converted = for <<byte <- chunk>>, into: "", do: <<win_codepoint(byte)::utf8>>
    {converted, byte_size(chunk)}
  end

  defp convert_chunk(chunk, encoding, final?) do
    source = if encoding in [:utf8, :unknown], do: :utf8, else: encoding
    replace_invalid(chunk, source, [], 0, final?)
  end

  defp replace_invalid(body, encoding, parts, consumed, final?) do
    case :unicode.characters_to_binary(body, encoding, :utf8) do
      utf8 when is_binary(utf8) ->
        {IO.iodata_to_binary(Enum.reverse([utf8 | parts])), consumed + byte_size(body)}

      {:error, good, rest} ->
        tail = drop_bad(rest, encoding)
        next = consumed + byte_size(body) - byte_size(tail)
        replace_invalid(tail, encoding, [@replacement, good | parts], next, final?)

      {:incomplete, good, rest} ->
        if final? do
          {IO.iodata_to_binary(Enum.reverse([@replacement, good | parts])),
           consumed + byte_size(body)}
        else
          {IO.iodata_to_binary(Enum.reverse([good | parts])),
           consumed + byte_size(body) - byte_size(rest)}
        end
    end
  end

  defp drop_bad(<<_, rest::binary>>, :utf8), do: rest
  defp drop_bad(<<_, _, rest::binary>>, {:utf16, _endian}), do: rest
  defp drop_bad(_rest, _encoding), do: <<>>

  defp ascii?(<<byte, rest::binary>>) when byte < 128, do: ascii?(rest)
  defp ascii?(<<>>), do: true
  defp ascii?(_body), do: false

  defp win_codepoint(byte) when byte <= 0x7F or byte >= 0xA0, do: byte
  defp win_codepoint(byte), do: Map.get(@windows_1252, byte, 0xFFFD)
end
