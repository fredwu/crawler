defmodule Crawler.Cookies.PublicSuffix.Rules do
  @moduledoc false

  @idna_options [check_hyphens: false, use_std3_ascii_rules: false, verify_dns_length: false]

  def load(path) do
    path
    |> File.stream!()
    |> Enum.reduce(empty(), fn line, rules ->
      case rule(line) do
        nil -> rules
        value -> Enum.reduce(variants(value), rules, &add/2)
      end
    end)
  end

  defp empty, do: %{exact: MapSet.new(), wildcard: MapSet.new(), exception: MapSet.new()}

  defp rule(line) do
    line = line |> String.trim() |> String.downcase()

    cond do
      line == "" -> nil
      String.starts_with?(line, "//") -> nil
      true -> line
    end
  end

  defp variants("*." <> suffix), do: Enum.map(domain_variants(suffix), &("*." <> &1))
  defp variants("!" <> suffix), do: Enum.map(domain_variants(suffix), &("!" <> &1))
  defp variants(rule), do: domain_variants(rule)

  defp domain_variants(domain) do
    case to_ascii(domain) do
      ^domain -> [domain]
      ascii -> [domain, ascii]
    end
  end

  defp to_ascii(domain) do
    if ascii?(domain) do
      domain
    else
      case Unicode.IDNA.to_ascii(domain, @idna_options) do
        {:ok, ascii} -> String.downcase(ascii)
        _ -> domain
      end
    end
  end

  defp ascii?(domain), do: Enum.all?(:binary.bin_to_list(domain), &(&1 < 128))

  defp add("*", rules), do: rules
  defp add("*." <> suffix, rules), do: %{rules | wildcard: MapSet.put(rules.wildcard, suffix)}
  defp add("!" <> suffix, rules), do: %{rules | exception: MapSet.put(rules.exception, suffix)}
  defp add(suffix, rules), do: %{rules | exact: MapSet.put(rules.exact, suffix)}
end

defmodule Crawler.Cookies.PublicSuffix do
  @moduledoc false

  alias Crawler.Cookies.PublicSuffix.Rules

  @list_path Path.expand("../../../priv/public_suffix_list.dat", __DIR__)
  @external_resource @list_path

  @rules Rules.load(@list_path)
  @exact @rules.exact
  @wildcard @rules.wildcard
  @exception @rules.exception

  # Both sections of the Public Suffix List are required. github.io is private,
  # and !www.ck is an exception that must beat the *.ck wildcard.
  true = MapSet.member?(@exact, "com")
  true = MapSet.member?(@exact, "github.io")
  true = MapSet.member?(@wildcard, "ck")
  true = MapSet.member?(@exception, "www.ck")

  def public_suffix?(domain) when is_binary(domain) do
    domain = normalize(domain)
    domain != "" and suffix(domain) == domain
  end

  def public_suffix?(_domain), do: false

  def normalize(domain) when is_binary(domain) do
    domain
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
    |> to_ascii()
    |> strip_edge_dots()
  end

  def normalize(_domain), do: ""

  defp to_ascii(domain) do
    cond do
      not String.valid?(domain) -> domain
      ascii_bytes?(domain) -> domain
      true -> idna_ascii(domain)
    end
  end

  defp ascii_bytes?(domain), do: Enum.all?(:binary.bin_to_list(domain), &(&1 < 128))

  # IDNA maps a Unicode full stop to an ASCII dot after the first strip.
  defp strip_edge_dots(domain) do
    if String.valid?(domain) do
      domain |> String.trim_leading(".") |> String.trim_trailing(".")
    else
      domain
    end
  end

  defp idna_ascii(domain) do
    case Unicode.IDNA.to_ascii(domain,
           check_hyphens: false,
           use_std3_ascii_rules: false,
           verify_dns_length: false
         ) do
      {:ok, ascii} -> String.downcase(ascii)
      _ -> domain
    end
  end

  defp suffix(domain) do
    labels = String.split(domain, ".", trim: true)
    labels |> prevailing(matches(labels)) |> suffix_labels(labels)
  end

  defp matches(labels) do
    exact_matches(labels) ++ wildcard_matches(labels) ++ exception_matches(labels)
  end

  defp exact_matches(labels) do
    labels
    |> tails()
    |> Enum.filter(&MapSet.member?(@exact, &1))
    |> Enum.map(&{:exact, label_count(&1), &1})
  end

  defp exception_matches(labels) do
    labels
    |> tails()
    |> Enum.filter(&MapSet.member?(@exception, &1))
    |> Enum.map(&{:exception, label_count(&1), &1})
  end

  defp wildcard_matches(labels) do
    labels
    |> Enum.drop(1)
    |> tails()
    |> Enum.filter(&MapSet.member?(@wildcard, &1))
    |> Enum.map(&{:wildcard, label_count(&1) + 1, &1})
  end

  defp tails([]), do: []

  defp tails([_label | rest] = labels) do
    [Enum.join(labels, ".") | tails(rest)]
  end

  defp prevailing(_labels, []), do: {:star, 1, "*"}

  defp prevailing(_labels, matches) do
    Enum.max_by(matches, fn {kind, count, _rule} ->
      {count, exception_rank(kind)}
    end)
  end

  defp exception_rank(:exception), do: 1
  defp exception_rank(_kind), do: 0

  defp suffix_labels({:exception, _count, rule}, _labels) do
    case String.split(rule, ".", parts: 2) do
      [_left, rest] -> rest
      [only] -> only
    end
  end

  defp suffix_labels({_kind, count, _rule}, labels) do
    labels |> Enum.take(-count) |> Enum.join(".")
  end

  defp label_count(rule), do: length(String.split(rule, "."))
end
