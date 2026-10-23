defmodule Crawler.Robots.Directives do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.HTMLSpans

  # Homepage URL words must not select a product group or agent directive.
  @url ~r/[A-Za-z][A-Za-z0-9+.-]*:\/\/[^\s<>)]+/
  @product ~r/[A-Za-z0-9_-]+/

  def nofollow_result(tags, opts, %Budget{} = budget) do
    retained = budget.retained

    with {:ok, tokens, budget} <- token_set(opts[:user_agent], budget),
         {:ok, headers_block, budget} <- header_result(opts[:headers], tokens, budget),
         {:ok, blocked, budget} <- meta_after_header(headers_block, tags, tokens, budget),
         {:ok, budget} <- Budget.refund(budget, budget.retained - retained) do
      {:ok, blocked, budget}
    end
  end

  def product_tokens(user_agent) do
    {:ok, tokens, _budget} = product_tokens_result(user_agent, Budget.unlimited())
    tokens
  end

  defp token_set(user_agent, budget) do
    with {:ok, values, budget} <- product_tokens_result(user_agent, budget),
         {:ok, budget} <- Budget.charge(budget, Budget.cost(:frame), facts: 1) do
      token_set(values, MapSet.new(), budget, 0)
    end
  end

  defp token_set([], tokens, budget, held) do
    with {:ok, budget} <- Budget.release(budget, held), do: {:ok, tokens, budget}
  end

  defp token_set([value | rest], tokens, budget, held) do
    scratch = Budget.cost(:map_entry, 2)

    with {:ok, budget} <- Budget.charge(budget, Budget.cost(:map_entry), facts: 1),
         {:ok, budget} <- Budget.reserve(budget, scratch) do
      token_set(rest, MapSet.put(tokens, value), budget, held + scratch)
    end
  end

  defp product_tokens_result(user_agent, budget) when is_binary(user_agent) do
    # This bound includes URL replacement chunks, regex work, and mask flattening.
    scratch = Budget.cost(:frame, 4) + Budget.cost(:binary, 4) + byte_size(user_agent) * 64

    with {:ok, budget} <- Budget.count(budget, :facts),
         {:ok, budget} <- Budget.reserve(budget, scratch),
         {:ok, masked, budget} <- strip_urls(user_agent, 0, [], budget),
         {:ok, tokens, budget} <- token_list(masked, 0, [], budget),
         {:ok, budget} <- Budget.release(budget, scratch) do
      {:ok, tokens, budget}
    end
  end

  defp product_tokens_result(_user_agent, budget) do
    bytes = Budget.cost(:token) + Budget.cost(:list_cell) + Budget.cost(:binary) + 7

    with {:ok, budget} <- Budget.charge(budget, bytes, facts: 1),
         do: {:ok, ["crawler"], budget}
  end

  defp strip_urls(text, offset, acc, budget) do
    case Regex.run(@url, text, return: :index, capture: :first, offset: offset) do
      [{start, length}] ->
        with {:ok, budget} <- Budget.count(budget, :facts) do
          prefix = binary_part(text, offset, start - offset)
          strip_urls(text, start + length, [" ", prefix | acc], budget)
        end

      nil ->
        tail = binary_part(text, offset, byte_size(text) - offset)
        {:ok, IO.iodata_to_binary(Enum.reverse([tail | acc])), budget}
    end
  end

  defp token_list(text, offset, acc, budget) do
    case Regex.run(@product, text, return: :index, capture: :first, offset: offset) do
      [{start, length}] ->
        bytes = Budget.cost(:token) + Budget.cost(:binary) + Budget.cost(:list_cell) + length
        scratch = Budget.cost(:binary, 3) + length * 3

        with {:ok, budget} <- Budget.charge(budget, bytes, facts: 1),
             {:ok, budget} <- Budget.reserve(budget, scratch) do
          token = text |> binary_part(start, length) |> String.downcase() |> :binary.copy()

          with {:ok, budget} <- Budget.release(budget, scratch) do
            token_list(text, start + length, [token | acc], budget)
          end
        end

      nil ->
        {:ok, Enum.reverse(acc), budget}
    end
  end

  defp header_result(headers, tokens, budget) when is_list(headers),
    do: header_rows(headers, tokens, budget)

  defp header_result(_headers, _tokens, budget), do: {:ok, false, budget}

  defp header_rows([], _tokens, budget), do: {:ok, false, budget}

  defp header_rows([{name, value} | rest], tokens, budget) do
    with {:ok, matches, budget} <- header_name(name, budget),
         {:ok, blocked, budget} <- header_directives(matches, value, tokens, budget) do
      if blocked, do: {:ok, true, budget}, else: header_rows(rest, tokens, budget)
    end
  end

  defp header_rows([_invalid | _rest], _tokens, _budget), do: {:error, :invalid_robots_header}

  defp header_name(name, budget) when is_integer(name) or is_float(name),
    do: {:ok, false, budget}

  defp header_name(name, budget),
    do: normalized_match(name, false, &(&1 == "x-robots-tag"), budget)

  defp header_directives(false, _value, _tokens, budget), do: {:ok, false, budget}
  defp header_directives(true, value, tokens, budget), do: directives_block(value, tokens, budget)

  defp meta_after_header(true, _tags, _tokens, budget), do: {:ok, true, budget}
  defp meta_after_header(false, tags, tokens, budget), do: meta_rows(tags, tokens, budget)

  defp meta_rows([], _tokens, budget), do: {:ok, false, budget}

  defp meta_rows([tag | rest], tokens, budget) do
    active =
      tag.name == "meta" and not tag.closing? and not tag.in_template? and not tag.in_shadow_root?

    with {:ok, blocked, budget} <- meta_block(active, tag, tokens, budget) do
      if blocked, do: {:ok, true, budget}, else: meta_rows(rest, tokens, budget)
    end
  end

  defp meta_block(false, _tag, _tokens, budget), do: {:ok, false, budget}

  defp meta_block(true, tag, tokens, budget) do
    with {:ok, matches, budget} <-
           normalized_match(
             active_value(tag, "name"),
             true,
             &(&1 == "robots" or MapSet.member?(tokens, &1)),
             budget
           ) do
      if matches,
        do: directives_block(active_value(tag, "content") || "", tokens, budget),
        else: {:ok, false, budget}
    end
  end

  defp active_value(tag, name) do
    case HTMLSpans.active_attribute(tag, name) do
      nil -> nil
      attr -> attr.decoded
    end
  end

  defp normalized_match(value, trim, matches, budget) when is_binary(value) do
    scratch = Budget.cost(:frame) + Budget.cost(:binary, 6) + byte_size(value) * 8

    with {:ok, budget} <- Budget.count(budget, :facts),
         {:ok, budget} <- Budget.reserve(budget, scratch) do
      value = if trim, do: String.trim(value), else: value
      result = value |> String.downcase() |> matches.()
      with {:ok, budget} <- Budget.release(budget, scratch), do: {:ok, result, budget}
    end
  end

  defp normalized_match(nil, trim, matches, budget),
    do: normalized_match("", trim, matches, budget)

  defp normalized_match(value, trim, matches, budget) when is_atom(value) do
    scratch = Budget.cost(:binary) + 1024

    with {:ok, budget} <- Budget.count(budget, :facts),
         {:ok, budget} <- Budget.reserve(budget, scratch),
         {:ok, result, budget} <- normalized_match(Atom.to_string(value), trim, matches, budget),
         {:ok, budget} <- Budget.release(budget, scratch) do
      {:ok, result, budget}
    end
  end

  defp normalized_match(value, trim, matches, budget) when is_list(value) do
    scratch = Budget.cost(:frame) + Budget.cost(:binary, 2)

    with {:ok, budget} <- Budget.count(budget, :facts),
         {:ok, budget} <- Budget.reserve(budget, scratch),
         {:ok, text, held, budget} <- scalar_chars(value, [], "", scratch, budget),
         {:ok, result, budget} <- normalized_match(text, trim, matches, budget),
         {:ok, budget} <- Budget.release(budget, held) do
      {:ok, result, budget}
    end
  end

  defp normalized_match(_value, _trim, _matches, _budget),
    do: {:error, :unsupported_robots_scalar}

  defp scalar_chars([], [], text, held, budget), do: {:ok, text, held, budget}

  defp scalar_chars([], [rest | pending], text, held, budget) do
    with {:ok, budget} <- Budget.release(budget, Budget.cost(:frame)),
         do: scalar_chars(rest, pending, text, held - Budget.cost(:frame), budget)
  end

  defp scalar_chars([char | rest], pending, text, held, budget)
       when is_integer(char) and char >= 0 and char <= 0x10FFFF and char not in 0xD800..0xDFFF do
    bytes = utf8_bytes(char) * 4

    with {:ok, budget} <- Budget.reserve(budget, bytes),
         do: scalar_chars(rest, pending, <<text::binary, char::utf8>>, held + bytes, budget)
  end

  defp scalar_chars([part | rest], pending, text, held, budget)
       when is_binary(part) or is_list(part) do
    with {:ok, budget} <- Budget.reserve(budget, Budget.cost(:frame)),
         do: scalar_chars(part, [rest | pending], text, held + Budget.cost(:frame), budget)
  end

  defp scalar_chars(<<>>, pending, text, held, budget),
    do: scalar_chars([], pending, text, held, budget)

  defp scalar_chars(<<char::utf8, rest::binary>>, pending, text, held, budget) do
    bytes = utf8_bytes(char) * 4

    with {:ok, budget} <- Budget.reserve(budget, bytes),
         do: scalar_chars(rest, pending, <<text::binary, char::utf8>>, held + bytes, budget)
  end

  defp scalar_chars(_value, _pending, _text, _held, _budget),
    do: {:error, :unsupported_robots_scalar}

  defp utf8_bytes(char) when char <= 0x7F, do: 1
  defp utf8_bytes(char) when char <= 0x7FF, do: 2
  defp utf8_bytes(char) when char <= 0xFFFF, do: 3
  defp utf8_bytes(_char), do: 4

  defp directives_block(value, tokens, budget) when is_binary(value) do
    with {:ok, budget} <- Budget.reserve(budget, Budget.cost(:frame)) do
      result = directive_tokens(value, 0, tokens, budget)
      release_result(result, Budget.cost(:frame))
    end
  end

  defp directives_block(_value, _tokens, budget), do: {:ok, false, budget}

  defp directive_tokens(value, offset, tokens, budget) do
    with {:ok, budget} <- Budget.count(budget, :facts, 2) do
      {length, next} =
        case :binary.match(value, ",", scope: {offset, byte_size(value) - offset}) do
          {at, 1} -> {at - offset, at + 1}
          :nomatch -> {byte_size(value) - offset, nil}
        end

      scratch = Budget.cost(:frame) + Budget.cost(:binary, 6) + length * 8

      with {:ok, budget} <- Budget.reserve(budget, scratch) do
        piece = value |> binary_part(offset, length) |> String.downcase() |> String.trim()
        blocked = directive_piece(piece, tokens)

        with {:ok, budget} <- Budget.release(budget, scratch) do
          cond do
            blocked -> {:ok, true, budget}
            next == nil -> {:ok, false, budget}
            true -> directive_tokens(value, next, tokens, budget)
          end
        end
      end
    end
  end

  defp directive_piece(piece, tokens) do
    case :binary.split(piece, ":") do
      [directive] ->
        directive in ["nofollow", "none"]

      [agent, directive] ->
        MapSet.member?(tokens, String.trim(agent)) and
          String.trim(directive) in ["nofollow", "none"]
    end
  end

  defp release_result({:ok, value, budget}, scratch) do
    with {:ok, budget} <- Budget.release(budget, scratch), do: {:ok, value, budget}
  end

  defp release_result(error, _scratch), do: error
end
