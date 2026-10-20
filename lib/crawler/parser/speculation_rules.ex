defmodule Crawler.Parser.SpeculationRules do
  @moduledoc false

  alias Crawler.ImportMap.JSON
  alias Crawler.URL

  def header_urls(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      {name, value} when is_binary(value) ->
        if header_name?(name), do: quoted_urls(value), else: []

      _header ->
        []
    end)
  end

  def header_urls(_headers), do: []

  def entries(body, opts) when is_binary(body) do
    case JSON.decode_located(body) do
      {:ok, decoded} -> collect(decoded, opts)
      :error -> []
    end
  end

  def entries(_body, _opts), do: []

  defp collect({:object, pairs}, opts) do
    Enum.flat_map(["prefetch", "prerender"], fn key ->
      pairs |> field(key) |> rules(key, opts)
    end)
  end

  defp collect(_decoded, _opts), do: []

  defp rules(items, action, opts) when is_list(items) do
    Enum.flat_map(items, &rule(&1, action, opts))
  end

  defp rules(_items, _action, _opts), do: []

  defp rule({:object, pairs}, action, opts) do
    source = text(field(pairs, "source"))
    urls = field(pairs, "urls")

    cond do
      source not in [nil, "list"] ->
        []

      not is_list(urls) ->
        []

      true ->
        case rule_base(text(field(pairs, "relative_to")), opts) do
          base when is_binary(base) -> resolve_urls(urls, base, action_name(action))
          _base -> []
        end
    end
  end

  defp rule(_rule, _action, _opts), do: []

  defp action_name("prefetch"), do: :prefetch
  defp action_name(_action), do: :prerender

  defp rule_base(nil, %{fetch_kind: :speculation_rules} = opts), do: response_url(opts)
  defp rule_base(nil, opts), do: opts[:document_base] || opts[:referrer_url] || opts[:url]
  defp rule_base("document", opts), do: opts[:document_base]
  defp rule_base("ruleset", %{fetch_kind: :speculation_rules} = opts), do: response_url(opts)
  defp rule_base("ruleset", _opts), do: nil
  defp rule_base(_relative_to, _opts), do: nil

  # referrer_url is the response. url remains the request that was redirected.
  defp response_url(%{referrer_url: url}) when is_binary(url) and url != "", do: url
  defp response_url(opts), do: opts[:url]

  defp resolve_urls(urls, base, action) do
    Enum.flat_map(urls, fn
      {:str, raw, start, length} ->
        case URL.resolve(raw, base) do
          {:ok, resolved} -> [{raw, resolved, start, length, action}]
          :skip -> []
        end

      _url ->
        []
    end)
  end

  defp text({:str, value, _start, _length}), do: value
  defp text(other), do: other

  defp field(pairs, name) do
    Enum.find_value(pairs, fn
      {^name, value} -> value
      _pair -> nil
    end)
  end

  defp header_name?(name) do
    name |> to_string() |> String.downcase() == "speculation-rules"
  end

  defp quoted_urls(value), do: quoted_urls(skip_space(value), [])

  defp quoted_urls(<<?", rest::binary>>, acc) do
    case read_quoted(rest, []) do
      {:ok, url, rest} ->
        rest = rest |> skip_space() |> drop_comma()
        quoted_urls(skip_space(rest), [url | acc])

      :error ->
        Enum.reverse(acc)
    end
  end

  defp quoted_urls(_value, acc), do: Enum.reverse(acc)

  defp read_quoted(<<?", rest::binary>>, acc),
    do: {:ok, IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp read_quoted(<<?\\, char, rest::binary>>, acc), do: read_quoted(rest, [char | acc])

  defp read_quoted(<<char, rest::binary>>, acc) when char >= 0x20,
    do: read_quoted(rest, [char | acc])

  defp read_quoted(_rest, _acc), do: :error

  defp drop_comma(<<",", rest::binary>>), do: rest
  defp drop_comma(rest), do: rest

  defp skip_space(<<char, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r], do: skip_space(rest)
  defp skip_space(rest), do: rest
end
