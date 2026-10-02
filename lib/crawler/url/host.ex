defmodule Crawler.URL.Host do
  @moduledoc false

  @base 36
  @tmin 1
  @tmax 26
  @skew 38
  @damp 700
  @initial_bias 72
  @initial_n 128

  @doc false
  def fold(host) when is_binary(host) do
    if String.valid?(host) do
      host
      |> String.downcase()
      |> strip_single_dot()
      |> compress_or_punycode()
    else
      host
    end
  end

  defp strip_single_dot("."), do: "."

  defp strip_single_dot(host) do
    if String.ends_with?(host, ".") and not String.ends_with?(host, "..") do
      binary_part(host, 0, byte_size(host) - 1)
    else
      host
    end
  end

  defp compress_or_punycode(host) do
    case :inet.parse_ipv6strict_address(String.to_charlist(host)) do
      {:ok, address} -> format_ipv6(address)
      _ -> punycode_host(host)
    end
  end

  # :inet.ntoa/1 rewrites fe80 and ff02 with a non-zero second hextet into a
  # zone id (`fe80::1%01`). That is a different address, so format RFC 5952 here.
  defp format_ipv6(address) do
    hextets = Tuple.to_list(address)
    words = Enum.map(hextets, &hex_word/1)

    case zero_run(hextets, 0, nil, nil) do
      {start, length} when length >= 2 ->
        compress_words(Enum.take(words, start), Enum.drop(words, start + length))

      _ ->
        Enum.join(words, ":")
    end
  end

  defp hex_word(value) do
    value |> Integer.to_string(16) |> String.downcase()
  end

  defp zero_run([], _index, current, best), do: longer_run(best, current)
  defp zero_run([0 | rest], index, nil, best), do: zero_run(rest, index + 1, {index, 1}, best)

  defp zero_run([0 | rest], index, {start, length}, best) do
    zero_run(rest, index + 1, {start, length + 1}, best)
  end

  defp zero_run([_value | rest], index, nil, best), do: zero_run(rest, index + 1, nil, best)

  defp zero_run([_value | rest], index, current, best) do
    zero_run(rest, index + 1, nil, longer_run(best, current))
  end

  defp longer_run(best, nil), do: best
  defp longer_run(nil, current), do: current
  defp longer_run({_start, best_len}, {_start2, len} = current) when len > best_len, do: current
  defp longer_run(best, _current), do: best

  defp compress_words([], []), do: "::"
  defp compress_words(head, []), do: Enum.join(head, ":") <> "::"
  defp compress_words([], tail), do: "::" <> Enum.join(tail, ":")
  defp compress_words(head, tail), do: Enum.join(head, ":") <> "::" <> Enum.join(tail, ":")

  defp punycode_host(host) do
    host
    |> String.split(".")
    |> Enum.map_join(".", &punycode_label/1)
  end

  defp punycode_label(""), do: ""

  defp punycode_label(label) do
    label = nfc(label)
    if ascii?(label), do: label, else: "xn--" <> encode(label)
  end

  defp nfc(label) do
    case :unicode.characters_to_nfc_binary(label) do
      folded when is_binary(folded) -> folded
      _ -> label
    end
  end

  defp ascii?(label) do
    label
    |> String.to_charlist()
    |> Enum.all?(&(&1 < 128))
  end

  defp encode(label) do
    input = String.to_charlist(label)
    basic = for codepoint <- input, codepoint < 128, do: codepoint
    basic_count = length(basic)
    body = deltas(input, length(input), basic_count, basic_count, @initial_n, 0, @initial_bias)
    delimiter = if basic_count > 0, do: [?-], else: []

    IO.iodata_to_binary([basic, delimiter, body])
  end

  defp deltas(_input, length, handled, _basic_count, _n, _delta, _bias) when handled >= length do
    []
  end

  defp deltas(input, length, handled, basic_count, n, delta, bias) do
    minimum = minimum_above(input, n)
    delta = delta + (minimum - n) * (handled + 1)

    {handled, delta, bias, digits} =
      consume(input, minimum, handled, delta, bias, basic_count, [])

    [digits, deltas(input, length, handled, basic_count, minimum + 1, delta + 1, bias)]
  end

  defp consume([], _n, handled, delta, bias, _basic_count, acc) do
    {handled, delta, bias, acc}
  end

  defp consume([codepoint | rest], n, handled, delta, bias, basic_count, acc)
       when codepoint < n do
    consume(rest, n, handled, delta + 1, bias, basic_count, acc)
  end

  defp consume([codepoint | rest], n, handled, delta, bias, basic_count, acc)
       when codepoint == n do
    digits = emit_digit(delta, bias, @base, [])
    bias = adapt(delta, handled + 1, handled == basic_count)
    consume(rest, n, handled + 1, 0, bias, basic_count, [acc, digits])
  end

  defp consume([_codepoint | rest], n, handled, delta, bias, basic_count, acc) do
    consume(rest, n, handled, delta, bias, basic_count, acc)
  end

  defp minimum_above(codepoints, n) do
    Enum.reduce(codepoints, nil, fn codepoint, lowest ->
      if codepoint >= n and (lowest == nil or codepoint < lowest) do
        codepoint
      else
        lowest
      end
    end)
  end

  defp emit_digit(q, bias, k, acc) do
    t = threshold(k, bias)

    if q < t do
      [acc, digit(q)]
    else
      emit_digit(
        div(q - t, @base - t),
        bias,
        k + @base,
        [acc, digit(t + rem(q - t, @base - t))]
      )
    end
  end

  defp threshold(k, bias) when k <= bias, do: @tmin
  defp threshold(k, bias) when k >= bias + @tmax, do: @tmax
  defp threshold(k, bias), do: k - bias

  defp digit(value) when value < 26, do: ?a + value
  defp digit(value), do: ?0 + value - 26

  defp adapt(delta, numpoints, true), do: adapt_delta(div(delta, @damp), numpoints)
  defp adapt(delta, numpoints, false), do: adapt_delta(div(delta, 2), numpoints)

  defp adapt_delta(delta, numpoints) do
    adapt_k(delta + div(delta, numpoints), 0)
  end

  defp adapt_k(delta, k) when delta > div((@base - @tmin) * @tmax, 2) do
    adapt_k(div(delta, @base - @tmin), k + @base)
  end

  defp adapt_k(delta, k) do
    k + div((@base - @tmin + 1) * delta, delta + @skew)
  end
end
