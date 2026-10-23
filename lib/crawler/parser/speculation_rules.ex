defmodule Crawler.Parser.SpeculationRules do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.HTTP.DocumentHeaders
  alias Crawler.ImportMap.JSON
  alias Crawler.URL

  def header_urls(headers) do
    {:ok, urls, _budget} = header_urls_result(headers, Budget.unlimited())
    urls
  end

  def header_urls_result(headers, budget) when is_list(headers) do
    with {:ok, urls, budget} <-
           each(headers, budget, [], fn
             {name, value}, acc, budget when is_binary(value) ->
               with {:ok, matches?, budget} <-
                      DocumentHeaders.name_matches_result(name, "speculation-rules", budget) do
                 if matches?,
                   do: quoted_urls_result(skip_space(value), acc, budget),
                   else: {:ok, acc, budget}
               end

             _header, acc, budget ->
               {:ok, acc, budget}
           end),
         do: {:ok, Enum.reverse(urls), budget}
  end

  def header_urls_result(_headers, budget), do: {:ok, [], budget}

  def entries(body, opts) when is_binary(body) do
    case JSON.decode_located(body) do
      {:ok, decoded} -> entries_located(decoded, opts)
      :error -> []
    end
  end

  def entries(_body, _opts), do: []

  def entries_located(decoded, opts) do
    {:ok, entries, _budget} =
      reduce_located(decoded, opts, Budget.unlimited(), [], fn entry, acc, budget ->
        {:ok, [entry | acc], budget}
      end)

    Enum.reverse(entries)
  end

  def reduce_located({:object, pairs}, opts, budget, acc, emit) do
    each(["prefetch", "prerender"], budget, acc, fn key, acc, budget ->
      each(field(pairs, key), budget, acc, fn item, acc, budget ->
        rule(item, action_name(key), opts, budget, acc, emit)
      end)
    end)
  end

  def reduce_located(_decoded, _opts, budget, acc, _emit), do: {:ok, acc, budget}

  defp rule({:object, pairs}, action, opts, budget, acc, emit) do
    base = rule_base(text(field(pairs, "relative_to")), opts)

    if text(field(pairs, "source")) in [nil, "list"] and is_binary(base) do
      each(field(pairs, "urls"), budget, acc, fn
        {:str, raw, start, length}, acc, budget ->
          rule_url(raw, start, length, action, base, budget, acc, emit)

        _item, acc, budget ->
          {:ok, acc, budget}
      end)
    else
      {:ok, acc, budget}
    end
  end

  defp rule(_item, _action, _opts, budget, acc, _emit), do: {:ok, acc, budget}

  defp rule_url(raw, start, length, action, base, budget, acc, emit) do
    with {:ok, _hypothetical} <- Budget.count(budget, :occurrences) do
      case URL.resolve_result(raw, base, budget) do
        {:ok, url, budget} ->
          with {:ok, budget} <- Budget.charge(budget, Budget.cost(:token)),
               do: emit.({raw, url, start, length, action}, acc, budget)

        {:skip, budget} ->
          {:ok, acc, budget}

        error ->
          error
      end
    end
  end

  defp each(items, budget, acc, fun) when is_list(items) do
    Enum.reduce_while(items, {:ok, acc, budget}, fn item, {:ok, acc, budget} ->
      case fun.(item, acc, budget) do
        {:ok, acc, budget} -> {:cont, {:ok, acc, budget}}
        error -> {:halt, error}
      end
    end)
  end

  defp each(_items, budget, acc, _fun), do: {:ok, acc, budget}

  defp action_name("prefetch"), do: :prefetch
  defp action_name(_action), do: :prerender

  # A missing relative_to and relative_to ruleset keep the base passed to the
  # parser. An inline script passes the document base. A rules file passes its
  # response URL. relative_to document always uses the page.
  defp rule_base(relative_to, %{fetch_kind: :speculation_rules} = opts)
       when relative_to in [nil, "ruleset"],
       do: response_url(opts)

  defp rule_base(relative_to, opts) when relative_to in [nil, "ruleset"] do
    opts[:document_base] || opts[:referrer_url] || opts[:url]
  end

  defp rule_base("document", opts), do: opts[:document_base]
  defp rule_base(_relative_to, _opts), do: nil

  # referrer_url is the response. url remains the request that was redirected.
  defp response_url(%{referrer_url: url}) when is_binary(url) and url != "", do: url
  defp response_url(opts), do: opts[:url]

  defp text({:str, value, _start, _length}), do: value
  defp text(other), do: other

  defp field(pairs, name) do
    Enum.find_value(pairs, fn
      {^name, value} -> value
      _pair -> nil
    end)
  end

  defp quoted_urls_result(<<?", rest::binary>>, acc, budget) do
    case header_url_attempt(rest, budget) do
      {:ok, url, rest, budget} ->
        quoted_urls_result(
          rest |> skip_space() |> drop_comma() |> skip_space(),
          [url | acc],
          budget
        )

      {:invalid, latest, hold} ->
        with {:ok, latest} <- Budget.release(latest, hold),
             {:ok, latest} <- Budget.refund(latest, latest.retained - budget.retained),
             do: {:ok, acc, latest}

      error ->
        error
    end
  end

  defp quoted_urls_result(_value, acc, budget), do: {:ok, acc, budget}

  defp header_url_attempt(rest, budget) do
    with {:ok, budget} <- Budget.charge(budget, Budget.cost(:token), facts: 1),
         {:ok, budget} <- Budget.reserve(budget, Budget.cost(:binary)),
         do: read_quoted_result(rest, [], budget, Budget.cost(:binary), 0)
  end

  defp read_quoted_result(<<?", rest::binary>>, acc, budget, hold, length) do
    url = IO.iodata_to_binary(Enum.reverse(acc))

    with {:ok, budget} <- Budget.settle(budget, hold, length + Budget.cost(:binary)),
         do: {:ok, url, rest, budget}
  end

  defp read_quoted_result(<<?\\, char, rest::binary>>, acc, budget, hold, length),
    do: read_quoted_byte(char, rest, acc, budget, hold, length)

  defp read_quoted_result(<<char, rest::binary>>, acc, budget, hold, length) when char >= 0x20,
    do: read_quoted_byte(char, rest, acc, budget, hold, length)

  defp read_quoted_result(_rest, _acc, budget, hold, _length), do: {:invalid, budget, hold}

  defp read_quoted_byte(char, rest, acc, budget, hold, length) do
    bytes = 2 * Budget.cost(:list_cell) + 1

    with {:ok, budget} <- Budget.reserve(budget, bytes),
         do: read_quoted_result(rest, [char | acc], budget, hold + bytes, length + 1)
  end

  defp drop_comma(<<",", rest::binary>>), do: rest
  defp drop_comma(rest), do: rest

  defp skip_space(<<char, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r], do: skip_space(rest)
  defp skip_space(rest), do: rest
end
