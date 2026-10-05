defmodule Crawler.URL.IPv4 do
  @moduledoc false

  @numeric_ending ~r/\A(?:[0-9]+|0[xX][0-9a-fA-F]*)\z/
  @max_address 0xFFFFFFFF

  def normalize(domain) when is_binary(domain) do
    parts = domain |> String.split(".") |> drop_trailing_empty()

    if Regex.match?(@numeric_ending, List.last(parts)) do
      with true <- length(parts) <= 4,
           {:ok, numbers} <- parse_numbers(parts),
           {:ok, address} <- address(numbers) do
        {:ok, serialize(address)}
      else
        _ -> :error
      end
    else
      {:ok, domain}
    end
  end

  defp drop_trailing_empty(parts) do
    if length(parts) > 1 and List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
  end

  defp parse_numbers(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, numbers} ->
      case number(part) do
        {:ok, value} -> {:cont, {:ok, [value | numbers]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp number(""), do: :error
  defp number(<<?0, marker, rest::binary>>) when marker in [?x, ?X], do: digits(rest, 16, 0)
  defp number("0" <> rest) when rest != "", do: digits(rest, 8, 0)
  defp number(part), do: digits(part, 10, 0)

  defp digits("", _radix, value), do: {:ok, value}

  defp digits(<<char, rest::binary>>, radix, value) do
    digit = digit(char)
    next = value * radix + digit

    if digit >= 0 and digit < radix and next <= @max_address,
      do: digits(rest, radix, next),
      else: :error
  end

  defp digit(char) when char in ?0..?9, do: char - ?0
  defp digit(char) when char in ?a..?f, do: char - ?a + 10
  defp digit(char) when char in ?A..?F, do: char - ?A + 10
  defp digit(_char), do: -1

  defp address([last | reversed_prefix]) do
    prefix = Enum.reverse(reversed_prefix)

    if Enum.all?(prefix, &(&1 <= 255)) and last < Integer.pow(256, 4 - length(prefix)) do
      address =
        prefix
        |> Enum.with_index()
        |> Enum.reduce(last, fn {part, index}, value ->
          value + part * Integer.pow(256, 3 - index)
        end)

      {:ok, address}
    else
      :error
    end
  end

  defp serialize(address) do
    Enum.map_join(3..0//-1, ".", fn exponent ->
      address |> div(Integer.pow(256, exponent)) |> rem(256) |> Integer.to_string()
    end)
  end
end
