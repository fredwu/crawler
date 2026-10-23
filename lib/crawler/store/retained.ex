defmodule Crawler.Store.Retained do
  @moduledoc false

  def bytes(term, limit) when is_integer(limit) and limit >= 0 do
    measure(term, limit, :retained)
  end

  def copy_bytes(term, limit) when is_integer(limit) and limit >= 0 do
    measure(term, limit, :copy)
  end

  def return_bytes(term, certificate, limit) when is_integer(limit) and limit >= 0 do
    with {:ok, copy} <- copy_bytes(term, limit),
         {:ok, backing} <- backings([{term, {:known, certificate}, 0}], 0, 0, limit - copy) do
      {:ok, copy + backing}
    end
  end

  defp measure(term, limit, mode) do
    case walk([{term, 0}], 0, 0, limit, mode) do
      {:ok, bytes} -> {:ok, bytes}
      :limited -> {:error, {:limit, :max_retained_bytes}}
    end
  end

  @continuation_limit 65_536

  defp walk(items, bytes, work, limit, mode), do: walk(items, bytes, work, limit, mode, 0)

  defp walk(_items, bytes, work, limit, _mode, _space) when bytes > limit or work > 100_000,
    do: :limited

  defp walk([], bytes, _work, _limit, _mode, _space), do: {:ok, bytes}

  defp walk([{_term, depth} | _], _bytes, _work, _limit, _mode, _space) when depth > 256,
    do: :limited

  defp walk([{:release, cost, :workspace} | rest], bytes, work, limit, mode, space),
    do: walk(rest, bytes, work, limit, mode, space - cost)

  defp walk([{:tuple, _term, 0, _depth} | rest], bytes, work, limit, mode, space),
    do: walk(rest, bytes, work, limit, mode, space - 256)

  defp walk([{:tuple, term, index, depth} | rest], bytes, work, limit, mode, space),
    do:
      walk(
        [{elem(term, index - 1), depth + 1}, {:tuple, term, index - 1, depth} | rest],
        bytes + 8,
        work + 1,
        limit,
        mode,
        space
      )

  defp walk([{:map, iterator, depth, cost} | rest], bytes, work, limit, mode, space) do
    case :maps.next(iterator) do
      :none ->
        walk(rest, bytes, work, limit, mode, space - cost)

      {key, value, iterator} ->
        walk(
          [{key, depth + 1}, {value, depth + 1}, {:map, iterator, depth, cost} | rest],
          bytes + 32,
          work + 1,
          limit,
          mode,
          space
        )
    end
  end

  defp walk([{term, depth} | rest], bytes, work, limit, mode, space) do
    cond do
      is_binary(term) ->
        payload =
          if mode == :copy, do: min(byte_size(term), 64), else: :binary.referenced_byte_size(term)

        header = if mode == :copy, do: 128, else: 64
        walk(rest, bytes + header + payload, work + 1, limit, mode, space)

      is_bitstring(term) ->
        :limited

      is_integer(term) and (term > 134_217_727 or term < -134_217_728) ->
        walk(rest, bytes + 64 + :erlang.external_size(term), work + 1, limit, mode, space)

      term == [] ->
        walk(rest, bytes + 8, work + 1, limit, mode, space)

      is_list(term) ->
        [head | tail] = term
        walk([{head, depth + 1}, {tail, depth} | rest], bytes + 16, work + 1, limit, mode, space)

      is_tuple(term) ->
        if space + 256 > @continuation_limit,
          do: :limited,
          else:
            walk(
              [{:tuple, term, tuple_size(term), depth} | rest],
              bytes + 8,
              work,
              limit,
              mode,
              space + 256
            )

      is_map(term) ->
        cost = 512 + 128 * map_size(term)

        if space + cost > @continuation_limit,
          do: :limited,
          else:
            walk(
              [{:map, :maps.iterator(term), depth, cost} | rest],
              bytes + 64,
              work,
              limit,
              mode,
              space + cost
            )

      is_function(term) ->
        cost = if mode == :retained, do: 0, else: 512 + 32 * :erlang.external_size(term)

        if space + cost > @continuation_limit do
          :limited
        else
          {:env, env} = :erlang.fun_info(term, :env)

          walk(
            [{env, depth + 1}, {:release, cost, :workspace} | rest],
            bytes + 128,
            work + 1,
            limit,
            mode,
            space + cost
          )
        end

      true ->
        walk(rest, bytes + 64, work + 1, limit, mode, space)
    end
  end

  defp previous_map_value({:known, original}, key) when is_map(original) do
    case Map.fetch(original, key) do
      {:ok, previous} -> {:known, previous}
      :error -> :unknown
    end
  end

  defp previous_map_value(_old, _key), do: :unknown

  defp backings(items, bytes, work, limit), do: backings(items, bytes, work, limit, 0)

  defp backings(_items, bytes, work, limit, _space) when bytes > limit or work > 100_000,
    do: {:error, {:limit, :max_retained_bytes}}

  defp backings([], bytes, _work, _limit, _space), do: {:ok, bytes}

  defp backings([{_term, _old, depth} | _], _bytes, _work, _limit, _space)
       when is_integer(depth) and depth > 256,
       do: {:error, {:limit, :max_retained_bytes}}

  defp backings([{:release, cost, :workspace} | rest], bytes, work, limit, space),
    do: backings(rest, bytes, work, limit, space - cost)

  defp backings([{:map, iterator, old, depth, cost} | rest], bytes, work, limit, space) do
    case :maps.next(iterator) do
      :none ->
        backings(rest, bytes, work, limit, space - cost)

      {key, value, iterator} ->
        previous = previous_map_value(old, key)

        backings(
          [
            {key, :unknown, depth + 1},
            {value, previous, depth + 1},
            {:map, iterator, old, depth, cost} | rest
          ],
          bytes,
          work + 1,
          limit,
          space
        )
    end
  end

  defp backings([{:tuple, _term, 0, _old, _depth} | rest], bytes, work, limit, space),
    do: backings(rest, bytes, work, limit, space - 256)

  defp backings([{:tuple, term, index, old, depth} | rest], bytes, work, limit, space) do
    previous =
      case old do
        {:known, original} when is_tuple(original) and tuple_size(original) >= index ->
          {:known, elem(original, index - 1)}

        _ ->
          :unknown
      end

    backings(
      [
        {elem(term, index - 1), previous, depth + 1},
        {:tuple, term, index - 1, old, depth} | rest
      ],
      bytes,
      work + 1,
      limit,
      space
    )
  end

  defp backings([{term, old, depth} | rest], bytes, work, limit, space) do
    trusted? =
      case old do
        {:known, original} -> :erts_debug.same(term, original)
        :unknown -> false
      end

    cond do
      trusted? ->
        backings(rest, bytes, work + 1, limit, space)

      is_binary(term) ->
        backing = :binary.referenced_byte_size(term)
        backings(rest, bytes + if(backing > 64, do: backing, else: 0), work + 1, limit, space)

      term == [] ->
        backings(rest, bytes, work + 1, limit, space)

      is_list(term) ->
        [head | tail] = term

        {old_head, old_tail} =
          case old do
            {:known, [head | tail]} -> {{:known, head}, {:known, tail}}
            _ -> {:unknown, :unknown}
          end

        backings(
          [{head, old_head, depth + 1}, {tail, old_tail, depth} | rest],
          bytes,
          work + 1,
          limit,
          space
        )

      is_tuple(term) ->
        if space + 256 > @continuation_limit,
          do: {:error, {:limit, :max_retained_bytes}},
          else:
            backings(
              [{:tuple, term, tuple_size(term), old, depth} | rest],
              bytes,
              work,
              limit,
              space + 256
            )

      is_map(term) ->
        cost = 512 + 128 * map_size(term)

        if space + cost > @continuation_limit,
          do: {:error, {:limit, :max_retained_bytes}},
          else:
            backings(
              [{:map, :maps.iterator(term), old, depth, cost} | rest],
              bytes,
              work,
              limit,
              space + cost
            )

      is_function(term) ->
        cost = 512 + 32 * :erlang.external_size(term)

        if space + cost > @continuation_limit do
          {:error, {:limit, :max_retained_bytes}}
        else
          {:env, env} = :erlang.fun_info(term, :env)

          backings(
            [{env, :unknown, depth + 1}, {:release, cost, :workspace} | rest],
            bytes,
            work + 1,
            limit,
            space + cost
          )
        end

      true ->
        backings(rest, bytes, work + 1, limit, space)
    end
  end
end
