defmodule Crawler.URL.Host do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.URL.IPv4

  @idna_options [check_hyphens: false, use_std3_ascii_rules: false, verify_dns_length: false]
  @forbidden ~r/[\x00-\x20\x7f#%\/:<>?@\[\]\\^|]/

  def fold(host) when is_binary(host) do
    case ipv6(host) do
      {:ok, address} ->
        address

      :error ->
        case domain(host) do
          {:ok, domain} -> domain
          :error -> host
        end
    end
  end

  def domain(host) when is_binary(host) do
    case domain_result(host, Budget.unlimited()) do
      {:ok, host, _budget} -> {:ok, host}
      {:invalid, _budget} -> :error
    end
  end

  @doc false
  def domain_result(host, budget) when is_binary(host) do
    decoded = URI.decode(host)
    scratch = if ascii?(decoded), do: 0, else: 32_768 * (byte_size(decoded) + 1)

    # UTS46 maps at most 18 codepoints per input codepoint. This hold covers
    # mapped/NFC lists, label records, bidi/context lists and Punycode buffers.
    with {:ok, reserved} <- Budget.reserve(budget, scratch) do
      result =
        with true <- String.valid?(decoded),
             {:ok, ascii} <- to_ascii(decoded),
             false <- ascii == "" or Regex.match?(@forbidden, ascii),
             {:ok, host} <- IPv4.normalize(ascii) do
          {:ok, host}
        else
          _ -> :invalid
        end

      with {:ok, budget} <- Budget.release(reserved, scratch) do
        case result do
          {:ok, host} -> {:ok, host, budget}
          :invalid -> {:invalid, budget}
        end
      end
    end
  end

  def ipv6(host) when is_binary(host) do
    if String.valid?(host) do
      case :inet.parse_ipv6strict_address(String.to_charlist(host)) do
        {:ok, address} -> {:ok, format_ipv6(address)}
        _ -> :error
      end
    else
      :error
    end
  end

  # The relaxed browser algorithm returns ASCII domains without IDNA checks.
  defp to_ascii(host) do
    if ascii?(host),
      do: {:ok, String.downcase(host)},
      else: Unicode.IDNA.to_ascii(host, @idna_options)
  end

  defp ascii?(<<>>), do: true
  defp ascii?(<<byte, rest::binary>>) when byte < 128, do: ascii?(rest)
  defp ascii?(_host), do: false

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
end
