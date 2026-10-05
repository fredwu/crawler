defmodule Crawler.Parser.JsParser.Identifier do
  @moduledoc false

  alias Crawler.Parser.JsParser.StringLiteral

  @unicode_start ~r/^[\p{L}\p{Nl}]$/u
  @unicode_part ~r/^[\p{Mn}\p{Mc}\p{Nd}\p{Pc}]$/u
  # Unicode identifier properties include stability exceptions beyond these categories.
  @other_starts [0x1885, 0x1886, 0x2118, 0x212E, 0x309B, 0x309C]
  @other_parts [0x00B7, 0x0387, 0x19DA, 0x200C, 0x200D, 0x30FB, 0xFF65]
  @escape ~r/^\\u(?:[0-9a-fA-F]{4}|\{[0-9a-fA-F]+\})/

  def take(source) do
    with {:ok, raw, rest, char} <- unit(source),
         true <- start?(char) do
      take_rest(rest, [raw], [<<char::utf8>>])
    else
      _ -> :none
    end
  end

  defp take_rest(source, raw_acc, name_acc) do
    with {:ok, raw, rest, char} <- unit(source),
         true <- part?(char) do
      take_rest(rest, [raw | raw_acc], [<<char::utf8>> | name_acc])
    else
      _ ->
        raw = raw_acc |> Enum.reverse() |> IO.iodata_to_binary()
        name = name_acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, raw, name, source}
    end
  end

  defp unit(<<"\\u", _rest::binary>> = source) do
    with [{0, length}] <- Regex.run(@escape, source, return: :index),
         raw = binary_part(source, 0, length),
         {:ok, <<char::utf8>>} <- StringLiteral.decode(raw) do
      {:ok, raw, binary_part(source, length, byte_size(source) - length), char}
    else
      _ -> :none
    end
  end

  defp unit(<<char::utf8, rest::binary>>), do: {:ok, <<char::utf8>>, rest, char}
  defp unit(_source), do: :none

  defp start?(char) when char in ?a..?z or char in ?A..?Z or char in [?_, ?$], do: true
  defp start?(char) when char < 0x80, do: false

  defp start?(char) do
    char in @other_starts or (char != 0x2E2F and Regex.match?(@unicode_start, <<char::utf8>>))
  end

  defp part?(char) when char in ?0..?9, do: true

  defp part?(char) do
    start?(char) or char in @other_parts or char in 0x1369..0x1371 or
      (char >= 0x80 and Regex.match?(@unicode_part, <<char::utf8>>))
  end
end
