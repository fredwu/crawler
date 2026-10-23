defmodule Crawler.ImportMap do
  @moduledoc false
  alias Crawler.Analysis.Budget
  alias Crawler.ImportMap.JSON
  alias Crawler.URL

  def empty, do: %{imports: %{}, scopes: []}

  def parse(text, base) when is_binary(text) and is_binary(base) do
    case JSON.decode_located(text) do
      {:ok, decoded} -> from_located(decoded, base)
      _other -> :error
    end
  end

  def parse(_text, _base), do: :error

  def from_located(decoded, base) do
    case from_located_result(decoded, base, Budget.unlimited()) do
      {:ok, map, _budget} -> map
      {:error, _reason, _budget} -> :error
      {:error, _reason} -> :error
    end
  end

  def from_located_result(decoded, base, budget) do
    case from_located_attempt(decoded, base, budget) do
      {:error, reason, latest} ->
        with {:ok, latest} <- Budget.release(latest, latest.scratch - budget.scratch),
             {:ok, latest} <- Budget.refund(latest, latest.retained - budget.retained),
             do: {:error, reason, latest}

      result ->
        result
    end
  end

  defp from_located_attempt({:object, pairs}, base, budget) when is_binary(base) do
    with_pairs(pairs, budget, fn pairs, budget ->
      with {:ok, budget} <- charge(budget, Budget.cost(:context)),
           {:ok, imports, budget} <- specifier_map(member(pairs, "imports"), base, budget),
           {:ok, scopes, budget} <- scopes(member(pairs, "scopes"), base, budget) do
        {:ok, %{imports: imports, scopes: scopes}, budget}
      end
    end)
  end

  defp from_located_attempt(_decoded, _base, budget), do: {:error, :invalid_import_map, budget}

  def merge_source(text, map, base) do
    case parse(text, base || "") do
      %{imports: _imports, scopes: _scopes} = parsed -> merge(parsed, map)
      :error -> map
    end
  end

  def merge(new, old) do
    {:ok, map, _budget} = merge_result(new, old, Budget.unlimited())
    map
  end

  def merge_result(new, old, budget) do
    entries =
      map_size(new.imports) + map_size(old.imports) +
        Enum.reduce(new.scopes, 0, fn {_prefix, imports}, n -> n + map_size(imports) + 1 end) +
        Enum.reduce(old.scopes, 0, fn {_prefix, imports}, n -> n + map_size(imports) + 1 end)

    with {:ok, budget} <-
           Budget.charge(budget, Budget.cost(:map_entry, entries) + Budget.cost(:context)),
         {:ok, budget} <- Budget.reserve(budget, Budget.cost(:map_entry, entries)) do
      scopes = merge_scopes(new.scopes, old.scopes)
      map = %{imports: Map.merge(new.imports, old.imports), scopes: scopes}

      with {:ok, budget} <- Budget.release(budget, Budget.cost(:map_entry, entries)),
           do: {:ok, map, budget}
    end
  end

  def resolve(specifier, map, base) do
    case resolve_result(specifier, map, base, Budget.unlimited()) do
      {:ok, url, _budget} -> {:ok, url}
      {:blocked, _budget} -> :blocked
      {:unmapped, _budget} -> :unmapped
    end
  end

  def resolve_result(specifier, %{imports: imports, scopes: scopes}, base, budget)
      when is_binary(specifier) and is_binary(base) do
    case classify(specifier, base, budget) do
      {:skip, budget} ->
        {:unmapped, budget}

      {:ok, kind, normalized, budget} ->
        case scoped_match(scopes, normalized, base) do
          :miss -> finish_match(match_imports(imports, normalized), kind, normalized, budget)
          match -> finish_match(match, kind, normalized, budget)
        end

      error ->
        error
    end
  end

  def resolve_result(_specifier, _map, _base, budget), do: {:unmapped, budget}

  defp member(pairs, key) do
    case List.keyfind(pairs, key, 0) do
      nil -> :absent
      {_key, value} -> {:present, value}
    end
  end

  defp specifier_map(:absent, _base, budget), do: {:ok, %{}, budget}

  defp specifier_map({:present, {:object, pairs}}, base, budget),
    do: normalize_pairs(pairs, base, budget)

  defp specifier_map(_value, _base, budget), do: {:error, :invalid_import_map, budget}

  defp scopes(:absent, _base, budget), do: {:ok, [], budget}

  defp scopes({:present, {:object, pairs}}, base, budget) do
    with_pairs(pairs, budget, fn pairs, budget ->
      with {:ok, scopes, budget} <-
             each(pairs, [], budget, &normalize_scope(&1, base, &2, &3)) do
        {:ok, sort_scopes(scopes), budget}
      end
    end)
  end

  defp scopes(_value, _base, budget), do: {:error, :invalid_import_map, budget}

  defp normalize_scope({key, {:object, entries}}, base, acc, budget) when key != "" do
    case URL.resolve_result(key, base, budget) do
      {:ok, prefix, budget} ->
        with {:ok, imports, budget} <- normalize_pairs(entries, base, budget),
             {:ok, budget} <- charge(budget, Budget.cost(:binding), facts: 1) do
          acc =
            if List.keymember?(acc, prefix, 0),
              do: acc,
              else: [{prefix, imports} | acc]

          {:ok, acc, budget}
        end

      {:skip, budget} ->
        {:ok, acc, budget}

      error ->
        error
    end
  end

  defp normalize_scope(_entry, _base, acc, budget), do: {:ok, acc, budget}

  defp normalize_pairs(pairs, base, budget) do
    with_pairs(pairs, budget, fn pairs, budget ->
      each(pairs, %{}, budget, &normalize_pair(&1, base, &2, &3))
    end)
  end

  defp normalize_pair({"", _value}, _base, acc, budget), do: {:ok, acc, budget}

  defp normalize_pair({key, value}, base, acc, budget) do
    with {:ok, budget} <- charge(budget, Budget.cost(:binding), facts: 1) do
      case normalize_key(key, base, budget) do
        {:ok, normalized, budget} ->
          case normalize_address(text(value), base, String.ends_with?(key, "/"), budget) do
            {:ok, address, budget} -> {:ok, Map.put_new(acc, normalized, address), budget}
            {:ignore, budget} -> {:ok, acc, budget}
            error -> error
          end

        {:ignore, budget} ->
          {:ok, acc, budget}

        error ->
          error
      end
    end
  end

  defp normalize_key(key, base, budget) do
    if url_like?(key) do
      case URL.resolve_result(key, base, budget) do
        {:ok, url, budget} -> {:ok, url, budget}
        {:skip, budget} -> {:ignore, budget}
        error -> error
      end
    else
      {:ok, key, budget}
    end
  end

  defp normalize_address(nil, _base, _prefix, budget), do: {:ok, :blocked, budget}

  defp normalize_address(value, base, prefix?, budget) when is_binary(value) do
    case URL.resolve_result(value, base, budget) do
      {:ok, url, budget} ->
        if prefix? and not String.ends_with?(url, "/"),
          do: {:ignore, budget},
          else: {:ok, url, budget}

      {:skip, budget} ->
        if prefix? and not String.ends_with?(value, "/"),
          do: {:ignore, budget},
          else: {:ok, :blocked, budget}

      error ->
        error
    end
  end

  defp normalize_address(_value, _base, _prefix, budget), do: {:ignore, budget}

  defp classify(specifier, base, budget) do
    if url_like?(specifier) do
      case URL.resolve_result(specifier, base, budget) do
        {:ok, url, budget} -> {:ok, :url, url, budget}
        other -> other
      end
    else
      {:ok, :bare, specifier, budget}
    end
  end

  defp scoped_match(scopes, normalized, base) do
    Enum.reduce_while(scopes, :miss, fn {prefix, imports}, :miss ->
      if prefix == base or (String.ends_with?(prefix, "/") and String.starts_with?(base, prefix)) do
        scoped_match_result(match_imports(imports, normalized))
      else
        {:cont, :miss}
      end
    end)
  end

  defp scoped_match_result(:miss), do: {:cont, :miss}
  defp scoped_match_result(match), do: {:halt, match}

  defp match_imports(imports, normalized) do
    case Map.fetch(imports, normalized) do
      {:ok, address} ->
        {:exact, address}

      :error ->
        Enum.reduce(imports, :miss, &match_prefix(&1, &2, normalized))
    end
  end

  defp match_prefix({key, address}, best, normalized) do
    if String.ends_with?(key, "/") and String.starts_with?(normalized, key) and
         (best == :miss or byte_size(key) > byte_size(elem(best, 1))),
       do: {:prefix, key, address},
       else: best
  end

  defp finish_match(:miss, :url, normalized, budget), do: {:ok, normalized, budget}
  defp finish_match(:miss, _kind, _normalized, budget), do: {:unmapped, budget}
  defp finish_match({:exact, :blocked}, _kind, _normalized, budget), do: {:blocked, budget}
  defp finish_match({:exact, address}, _kind, _normalized, budget), do: {:ok, address, budget}
  defp finish_match({:prefix, _key, :blocked}, _kind, _normalized, budget), do: {:blocked, budget}

  defp finish_match({:prefix, key, address}, _kind, normalized, budget) do
    rest = binary_part(normalized, byte_size(key), byte_size(normalized) - byte_size(key))

    case URL.resolve_result(rest, address, budget) do
      {:ok, url, budget} ->
        if String.starts_with?(url, address), do: {:ok, url, budget}, else: {:blocked, budget}

      {:skip, budget} ->
        {:blocked, budget}

      error ->
        error
    end
  end

  defp merge_scopes(new, old) do
    new = Map.new(new)
    old = Map.new(old)

    (Map.keys(old) ++ Map.keys(new))
    |> Enum.uniq()
    |> Enum.map(fn prefix ->
      {prefix, Map.merge(Map.get(new, prefix, %{}), Map.get(old, prefix, %{}))}
    end)
    |> sort_scopes()
  end

  defp sort_scopes(scopes),
    do: Enum.sort_by(scopes, fn {prefix, _imports} -> -byte_size(prefix) end)

  defp each(items, acc, budget, fun) do
    Enum.reduce_while(items, {:ok, acc, budget}, fn item, {:ok, acc, budget} ->
      case fun.(item, acc, budget) do
        {:ok, acc, budget} -> {:cont, {:ok, acc, budget}}
        error -> {:halt, error}
      end
    end)
  end

  defp with_pairs(pairs, budget, fun) do
    scratch = length(pairs) * (Budget.cost(:map_entry) * 2 + Budget.cost(:list_cell) * 3)

    with {:ok, budget} <- reserve(budget, scratch),
         {:ok, value, budget} <- fun.(JSON.collapse_pairs(pairs), budget),
         {:ok, budget} <- release(budget, scratch),
         do: {:ok, value, budget}
  end

  defp charge(budget, bytes, counters \\ []) do
    ledger_result(Budget.charge(budget, bytes, counters), budget)
  end

  defp reserve(budget, bytes), do: ledger_result(Budget.reserve(budget, bytes), budget)
  defp release(budget, bytes), do: ledger_result(Budget.release(budget, bytes), budget)
  defp ledger_result({:ok, budget}, _previous), do: {:ok, budget}
  defp ledger_result({:error, reason}, budget), do: {:error, reason, budget}

  defp text({:str, value, _at, _len}), do: value
  defp text(value), do: value

  defp url_like?(specifier) do
    String.starts_with?(specifier, "/") or String.starts_with?(specifier, "./") or
      String.starts_with?(specifier, "../") or specifier =~ ~r/^[A-Za-z][A-Za-z0-9+.-]*:/
  end
end
