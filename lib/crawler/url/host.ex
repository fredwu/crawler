defmodule Crawler.URL.Host do
  @moduledoc false

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
    decoded = URI.decode(host)

    with true <- String.valid?(decoded),
         {:ok, ascii} <- to_ascii(decoded),
         false <- ascii == "" or Regex.match?(@forbidden, ascii),
         {:ok, host} <- IPv4.normalize(ascii) do
      {:ok, strip_single_dot(host)}
    else
      _ -> :error
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

  defp ascii?(host), do: Enum.all?(:binary.bin_to_list(host), &(&1 < 128))

  defp strip_single_dot("."), do: "."

  defp strip_single_dot(host) do
    if String.ends_with?(host, ".") and not String.ends_with?(host, "..") do
      binary_part(host, 0, byte_size(host) - 1)
    else
      host
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
end
