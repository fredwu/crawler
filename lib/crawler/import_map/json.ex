defmodule Crawler.ImportMap.JSON do
  @moduledoc false

  alias Crawler.Analysis.Budget

  @max_input_bytes 10_485_760
  @max_depth 128
  @max_tokens 100_000
  @max_string_bytes 1_048_576
  @max_number_bytes 1_024
  @number_scratch_per_byte 16
  @raw_chunk_bytes 4096
  @number ~r/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/

  def decode(input) do
    case decode_located(input) do
      {:ok, decoded} -> {:ok, plain(decoded)}
      :error -> :error
    end
  end

  def decode_located(input) do
    case decode_located_result(input) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> :error
    end
  end

  def decode_located_result(input) do
    case decode_located_result(input, Budget.unlimited()) do
      {:ok, decoded, _budget} -> {:ok, decoded}
      {:error, reason, _budget} -> {:error, reason}
    end
  end

  # A limit reports the first exhausted budget; the remaining input is not validated.
  def decode_located_result(input, %Budget{} = entry) do
    case parse(input, entry) do
      {:ok, _decoded, _budget} = result ->
        result

      {:error, reason, budget} ->
        {:ok, budget} = Budget.release(budget, budget.scratch - entry.scratch)
        {:ok, budget} = Budget.refund(budget, budget.retained - entry.retained)
        {:error, reason, budget}
    end
  end

  defp parse(input, budget) when is_binary(input) and byte_size(input) <= @max_input_bytes do
    size = byte_size(input)

    case value(skip(strip_bom(input)), size, 0, @max_tokens, budget) do
      {:ok, decoded, rest, _tokens, budget} ->
        if skip(rest) == "", do: {:ok, decoded, budget}, else: {:error, :invalid_json, budget}

      {:error, _reason, _budget} = error ->
        error
    end
  end

  defp parse(input, budget) when is_binary(input),
    do: {:error, {:limit, :max_input_bytes}, budget}

  defp parse(_input, budget), do: {:error, :invalid_json, budget}

  # JSON objects keep the last duplicate key. The first key stays in place.
  def collapse_pairs(pairs) do
    {keys, values} =
      Enum.reduce(pairs, {[], %{}}, fn {key, value}, {keys, values} ->
        keys = if Map.has_key?(values, key), do: keys, else: [key | keys]
        {keys, Map.put(values, key, value)}
      end)

    keys |> Enum.reverse() |> Enum.map(fn key -> {key, Map.fetch!(values, key)} end)
  end

  defp plain({:str, value, _start, _length}), do: value

  defp plain({:object, pairs}) do
    {:object, Enum.map(pairs, fn {key, value} -> {key, plain(value)} end)}
  end

  defp plain(values) when is_list(values), do: Enum.map(values, &plain/1)
  defp plain(value), do: value

  defp strip_bom(<<"\uFEFF", rest::binary>>), do: rest
  defp strip_bom(input), do: input

  defp value(_input, _size, _depth, tokens, budget) when tokens <= 0,
    do: {:error, {:limit, :max_tokens}, budget}

  defp value(<<char, _::binary>>, _size, depth, _tokens, budget)
       when char in ~c"{[" and depth >= @max_depth,
       do: {:error, {:limit, :max_depth}, budget}

  defp value(input, size, depth, tokens, budget) do
    kind =
      case input do
        <<char, _::binary>> when char in ~c"{[" -> :json_container
        _ -> :json_scalar
      end

    with {:ok, budget} <- charge(budget, Budget.cost(kind), facts: 1) do
      parse_value(input, size, depth, tokens - 1, budget)
    end
  end

  defp parse_value(<<?", _::binary>> = input, size, _depth, tokens, budget) do
    start = size - byte_size(input)

    with {:ok, value, rest, budget} <- take_string(input, budget) do
      {:ok, {:str, value, start, byte_size(input) - byte_size(rest)}, rest, tokens, budget}
    end
  end

  defp parse_value(<<"{", rest::binary>>, size, depth, tokens, budget) do
    with {:ok, budget} <- reserve(budget, Budget.cost(:frame)) do
      result =
        case skip(rest) do
          <<"}", rest::binary>> -> {:ok, {:object, []}, rest, tokens, budget}
          rest -> object(rest, size, depth + 1, tokens, budget, [], 0)
        end

      release_result(result, Budget.cost(:frame))
    end
  end

  defp parse_value(<<"[", rest::binary>>, size, depth, tokens, budget) do
    with {:ok, budget} <- reserve(budget, Budget.cost(:frame)) do
      result =
        case skip(rest) do
          <<"]", rest::binary>> -> {:ok, [], rest, tokens, budget}
          rest -> array(rest, size, depth + 1, tokens, budget, [], 0)
        end

      release_result(result, Budget.cost(:frame))
    end
  end

  defp parse_value(<<"null", rest::binary>>, _size, _depth, tokens, budget),
    do: {:ok, nil, rest, tokens, budget}

  defp parse_value(<<"true", rest::binary>>, _size, _depth, tokens, budget),
    do: {:ok, true, rest, tokens, budget}

  defp parse_value(<<"false", rest::binary>>, _size, _depth, tokens, budget),
    do: {:ok, false, rest, tokens, budget}

  defp parse_value(<<char, _::binary>> = input, _size, _depth, tokens, budget)
       when char in ~c"-0123456789" do
    with {:ok, value, rest, budget} <- number(input, budget) do
      {:ok, value, rest, tokens, budget}
    end
  end

  defp parse_value(_input, _size, _depth, _tokens, budget), do: {:error, :invalid_json, budget}

  defp object(input, size, depth, tokens, budget, acc, count) when tokens > 0 do
    with {:ok, budget} <-
           charge(budget, Budget.cost(:json_pair) + Budget.cost(:list_cell), facts: 1),
         {:ok, budget} <- reserve(budget, pair_scratch()),
         {:ok, key, rest, budget} <- take_string(input, budget),
         {:ok, rest, budget} <- object_value_input(rest, budget),
         {:ok, decoded, rest, tokens, budget} <-
           value(skip(rest), size, depth, tokens - 1, budget) do
      case skip(rest) do
        <<",", rest::binary>> ->
          object(skip(rest), size, depth, tokens, budget, [{key, decoded} | acc], count + 1)

        <<"}", rest::binary>> ->
          pairs = [{key, decoded} | acc] |> Enum.reverse() |> collapse_pairs()

          with {:ok, budget} <- release(budget, pair_scratch() * (count + 1)) do
            {:ok, {:object, pairs}, rest, tokens, budget}
          end

        _ ->
          {:error, :invalid_json, budget}
      end
    end
  end

  defp object(_input, _size, _depth, _tokens, budget, _acc, _count),
    do: {:error, {:limit, :max_tokens}, budget}

  defp object_value_input(rest, budget) do
    case skip(rest) do
      <<":", rest::binary>> -> {:ok, rest, budget}
      _ -> {:error, :invalid_json, budget}
    end
  end

  # Pair reversal, duplicate collapse, and persistent map revisions overlap.
  defp pair_scratch,
    do: Budget.cost(:map_entry, 4) + Budget.cost(:list_cell, 4) + Budget.cost(:json_pair)

  defp array(input, size, depth, tokens, budget, acc, count) do
    with {:ok, budget} <- charge(budget, Budget.cost(:list_cell)),
         {:ok, budget} <- reserve(budget, Budget.cost(:list_cell)),
         {:ok, decoded, rest, tokens, budget} <- value(input, size, depth, tokens, budget) do
      case skip(rest) do
        <<",", rest::binary>> ->
          array(skip(rest), size, depth, tokens, budget, [decoded | acc], count + 1)

        <<"]", rest::binary>> ->
          values = Enum.reverse([decoded | acc])

          with {:ok, budget} <- release(budget, Budget.cost(:list_cell, count + 1)) do
            {:ok, values, rest, tokens, budget}
          end

        _ ->
          {:error, :invalid_json, budget}
      end
    end
  end

  defp release_result({:ok, value, rest, tokens, budget}, scratch) do
    with {:ok, budget} <- release(budget, scratch),
         do: {:ok, value, rest, tokens, budget}
  end

  defp release_result(error, _scratch), do: error

  defp take_string(<<?", rest::binary>>, budget) do
    with {:ok, budget} <- charge(budget, Budget.cost(:binary)),
         {:ok, budget} <- reserve(budget, Budget.cost(:frame)) do
      string(rest, [], @max_string_bytes, budget, Budget.cost(:frame))
    end
  end

  defp take_string(_input, budget), do: {:error, :invalid_json, budget}

  defp string(<<?", rest::binary>>, acc, _remaining, budget, scratch) do
    decoded = IO.iodata_to_binary(Enum.reverse(acc))
    with {:ok, budget} <- release(budget, scratch), do: {:ok, decoded, rest, budget}
  end

  defp string(<<?\\, escape, rest::binary>>, acc, remaining, budget, scratch)
       when escape in [?", ?\\, ?/, ?b, ?f, ?n, ?r, ?t] do
    decoded =
      case escape do
        ?b -> ?\b
        ?f -> ?\f
        ?n -> ?\n
        ?r -> ?\r
        ?t -> ?\t
        other -> other
      end

    string_code(rest, decoded, 2, acc, remaining, budget, scratch)
  end

  defp string(<<"\\u", hex::binary-size(4), rest::binary>>, acc, remaining, budget, scratch) do
    case code_unit(hex) do
      {:ok, high} when high in 0xD800..0xDBFF ->
        surrogate_pair(high, rest, acc, remaining - 6, budget, scratch)

      {:ok, low} when low in 0xDC00..0xDFFF ->
        {:error, :invalid_json, budget}

      {:ok, code} ->
        string_code(rest, code, 6, acc, remaining, budget, scratch)

      :error ->
        {:error, :invalid_json, budget}
    end
  end

  defp string(<<?\\, _::binary>>, _acc, _remaining, budget, _scratch),
    do: {:error, :invalid_json, budget}

  defp string(input, acc, remaining, budget, scratch) do
    segment = Budget.cost(:segment) + Budget.cost(:list_cell, 2)

    with {:ok, budget} <- count(budget, :facts),
         {:ok, budget} <- reserve(budget, segment),
         {:ok, length, budget} <- raw_string(input, 0, remaining, budget) do
      <<raw::binary-size(length), rest::binary>> = input
      string(rest, [raw | acc], remaining - length, budget, scratch + segment)
    end
  end

  defp string_code(_rest, _code, consumed, _acc, remaining, budget, _scratch)
       when consumed > remaining,
       do: {:error, {:limit, :max_string_bytes}, budget}

  defp string_code(rest, code, consumed, acc, remaining, budget, scratch) do
    bytes = utf8_bytes(code)
    segment = Budget.cost(:segment) + Budget.cost(:list_cell, 2) + bytes

    with {:ok, budget} <- charge(budget, bytes, facts: 1),
         {:ok, budget} <- reserve(budget, segment) do
      string(rest, [<<code::utf8>> | acc], remaining - consumed, budget, scratch + segment)
    end
  end

  defp raw_string(<<char, _::binary>>, length, _remaining, budget) when char in [?", ?\\],
    do: {:ok, length, budget}

  defp raw_string(<<char::utf8, _::binary>> = input, length, remaining, budget)
       when char >= 0x20 do
    bytes = utf8_bytes(char)

    if bytes > remaining do
      {:error, {:limit, :max_string_bytes}, budget}
    else
      capacity = min(min(byte_size(input), remaining), @raw_chunk_bytes)
      # Prepay bounded output chunks within the same UTF-8 scan.
      capacity =
        case Budget.available(budget) do
          :infinity -> capacity
          available -> max(bytes, min(capacity, available))
        end

      with {:ok, budget} <- reserve(budget, capacity),
           do: raw_chunk(input, length, remaining, budget, capacity, 0)
    end
  end

  defp raw_string(_input, _length, _remaining, budget), do: {:error, :invalid_json, budget}

  defp raw_chunk(<<char, _::binary>>, length, _remaining, budget, reserved, used)
       when char in [?", ?\\] do
    with {:ok, budget} <- settle(budget, reserved, used), do: {:ok, length, budget}
  end

  defp raw_chunk(<<char::utf8, rest::binary>> = input, length, remaining, budget, reserved, used)
       when char >= 0x20 do
    bytes = utf8_bytes(char)

    cond do
      bytes > remaining ->
        {:error, {:limit, :max_string_bytes}, budget}

      used + bytes <= reserved ->
        raw_chunk(rest, length + bytes, remaining - bytes, budget, reserved, used + bytes)

      true ->
        with {:ok, budget} <- settle(budget, reserved, used),
             do: raw_string(input, length, remaining, budget)
    end
  end

  defp raw_chunk(_input, _length, _remaining, budget, _reserved, _used),
    do: {:error, :invalid_json, budget}

  defp utf8_bytes(code) when code <= 0x7F, do: 1
  defp utf8_bytes(code) when code <= 0x7FF, do: 2
  defp utf8_bytes(code) when code <= 0xFFFF, do: 3
  defp utf8_bytes(_code), do: 4

  defp number(input, budget) do
    with {:ok, budget} <- reserve(budget, Budget.cost(:frame)),
         {:ok, length, budget} <- number_length(input, 0, budget) do
      text = binary_part(input, 0, length)

      case Regex.run(@number, text) do
        [^text] ->
          value = parse_number(text)

          with {:ok, budget} <-
                 release(budget, Budget.cost(:frame) + length * @number_scratch_per_byte) do
            {:ok, value, binary_part(input, length, byte_size(input) - length), budget}
          end

        _ ->
          {:error, :invalid_json, budget}
      end
    end
  end

  defp number_length(<<char, rest::binary>>, length, budget) when char in ~c"-+0123456789.eE" do
    if length == @max_number_bytes do
      {:error, {:limit, :max_number_bytes}, budget}
    else
      with {:ok, budget} <- charge(budget, 1),
           {:ok, budget} <- reserve(budget, @number_scratch_per_byte) do
        number_length(rest, length + 1, budget)
      end
    end
  end

  defp number_length(_input, length, budget), do: {:ok, length, budget}

  defp parse_number(text) do
    if String.contains?(text, [".", "e", "E"]) do
      parse_float(text)
    else
      String.to_integer(text)
    end
  end

  defp parse_float(text) do
    case Float.parse(text) do
      {value, ""} -> value
      :error -> :non_finite
    end
  rescue
    ArgumentError -> :non_finite
  end

  defp surrogate_pair(
         high,
         <<"\\u", hex::binary-size(4), rest::binary>>,
         acc,
         remaining,
         budget,
         scratch
       ) do
    case code_unit(hex) do
      {:ok, low} when low in 0xDC00..0xDFFF ->
        code = 0x10000 + (high - 0xD800) * 0x400 + (low - 0xDC00)
        string_code(rest, code, 6, acc, remaining, budget, scratch)

      _ ->
        {:error, :invalid_json, budget}
    end
  end

  defp surrogate_pair(_high, _rest, _acc, _remaining, budget, _scratch),
    do: {:error, :invalid_json, budget}

  defp code_unit(hex) do
    if hex =~ ~r/^[0-9a-fA-F]{4}$/, do: {:ok, String.to_integer(hex, 16)}, else: :error
  end

  defp skip(<<char, rest::binary>>) when char in [?\s, ?\t, ?\n, ?\r], do: skip(rest)
  defp skip(rest), do: rest

  defp charge(budget, bytes, counters \\ []),
    do: budget_result(Budget.charge(budget, bytes, counters), budget)

  defp count(budget, key), do: budget_result(Budget.count(budget, key), budget)
  defp reserve(budget, bytes), do: budget_result(Budget.reserve(budget, bytes), budget)
  defp release(budget, bytes), do: budget_result(Budget.release(budget, bytes), budget)

  defp settle(budget, reserved, retained),
    do: budget_result(Budget.settle(budget, reserved, retained), budget)

  defp budget_result({:ok, budget}, _previous), do: {:ok, budget}
  defp budget_result({:error, reason}, budget), do: {:error, reason, budget}
end
