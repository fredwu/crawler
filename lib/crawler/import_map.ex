defmodule Crawler.ImportMap do
  @moduledoc false

  alias Crawler.ImportMap.JSON
  alias Crawler.URL

  def empty, do: %{imports: %{}, scopes: []}

  def parse(text, base) when is_binary(text) and is_binary(base) do
    case JSON.decode(text) do
      {:ok, {:object, pairs}} -> build(pairs, base)
      _ -> :error
    end
  end

  def parse(_text, _base), do: :error

  def merge_source(text, map, base) do
    case parse(text, base || "") do
      %{imports: _imports, scopes: _scopes} = parsed -> merge(parsed, map)
      :error -> map
    end
  end

  # `old` is the map already reached. Its entries, including null, stay.
  def merge(%{imports: new_imports, scopes: new_scopes}, %{
        imports: old_imports,
        scopes: old_scopes
      }) do
    %{
      imports: Map.merge(new_imports, old_imports),
      scopes: merge_scopes(new_scopes, old_scopes)
    }
  end

  def resolve(specifier, %{imports: imports, scopes: scopes}, script_base)
      when is_binary(specifier) and is_binary(script_base) do
    case classify(specifier, script_base) do
      :skip ->
        :unmapped

      {kind, normalized} ->
        case match_scopes(scopes, normalized, script_base) do
          :miss -> fallback(imports, kind, normalized)
          result -> result
        end
    end
  end

  def resolve(_specifier, _map, _script_base), do: :unmapped

  defp build(pairs, base) do
    pairs = collapse(pairs)

    with {:ok, imports} <- specifier_map(member(pairs, "imports"), base),
         {:ok, scopes} <- scope_map(member(pairs, "scopes"), base) do
      %{imports: imports, scopes: scopes}
    else
      _ -> :error
    end
  end

  # `nil` and `false` are real JSON values. A missing member is the only absence.
  defp member(pairs, key) do
    case List.keyfind(pairs, key, 0) do
      nil -> :absent
      {_key, value} -> {:present, value}
    end
  end

  defp specifier_map(:absent, _base), do: {:ok, %{}}
  defp specifier_map({:present, {:object, pairs}}, base), do: {:ok, normalize_pairs(pairs, base)}
  defp specifier_map({:present, _value}, _base), do: :error

  defp scope_map(:absent, _base), do: {:ok, []}

  defp scope_map({:present, {:object, pairs}}, base) do
    scopes = pairs |> collapse() |> Enum.reduce([], &put_scope(&1, &2, base))
    {:ok, sort_scopes(scopes)}
  end

  defp scope_map({:present, _value}, _base), do: :error

  defp put_scope({key, value}, acc, base) do
    case scope_entry(key, value, base) do
      {:ok, prefix, imports} -> put_new_scope(acc, prefix, imports)
      :ignore -> acc
    end
  end

  defp put_new_scope(acc, prefix, imports) do
    if List.keymember?(acc, prefix, 0), do: acc, else: [{prefix, imports} | acc]
  end

  defp scope_entry("", _value, _base), do: :ignore

  defp scope_entry(key, {:object, pairs}, base) do
    case URL.resolve(key, base) do
      {:ok, prefix} -> {:ok, prefix, normalize_pairs(pairs, base)}
      :skip -> :ignore
    end
  end

  defp scope_entry(_key, _value, _base), do: :ignore

  defp normalize_pairs(pairs, base) do
    pairs |> collapse() |> Enum.reduce(%{}, &put_entry(&1, &2, base))
  end

  defp put_entry({key, value}, acc, base) do
    case entry(key, value, base) do
      {:ok, normalized, address} -> put_new_address(acc, normalized, address)
      :ignore -> acc
    end
  end

  defp put_new_address(acc, normalized, address) do
    if Map.has_key?(acc, normalized), do: acc, else: Map.put(acc, normalized, address)
  end

  defp entry("", _value, _base), do: :ignore

  defp entry(key, value, base) do
    prefix? = String.ends_with?(key, "/")

    with {:ok, normalized} <- normalize_key(key, base),
         {:ok, address} <- normalize_address(value, base, prefix?) do
      {:ok, normalized, address}
    else
      _ -> :ignore
    end
  end

  defp normalize_key(key, base) do
    if url_like?(key) do
      case URL.resolve(key, base) do
        {:ok, url} -> {:ok, url}
        :skip -> :ignore
      end
    else
      {:ok, key}
    end
  end

  defp normalize_address(nil, _base, _prefix?), do: {:ok, :blocked}

  defp normalize_address(value, base, prefix?) when is_binary(value) do
    case URL.resolve(value, base) do
      {:ok, url} ->
        if prefix? and not String.ends_with?(url, "/"), do: :ignore, else: {:ok, url}

      :skip ->
        if prefix? and not String.ends_with?(value, "/"), do: :ignore, else: {:ok, :blocked}
    end
  end

  defp normalize_address(_value, _base, _prefix?), do: :ignore

  defp classify(specifier, base) do
    if url_like?(specifier) do
      case URL.resolve(specifier, base) do
        {:ok, url} -> {:url, url}
        :skip -> :skip
      end
    else
      {:bare, specifier}
    end
  end

  defp fallback(imports, kind, normalized) do
    case match_imports(imports, normalized) do
      :miss -> if kind == :url, do: {:ok, normalized}, else: :unmapped
      result -> result
    end
  end

  defp match_scopes(scopes, normalized, script_base) do
    Enum.reduce_while(scopes, :miss, fn {prefix, imports}, :miss ->
      scope_result(prefix, imports, normalized, script_base)
    end)
  end

  defp scope_result(prefix, imports, normalized, script_base) do
    if scope_match?(prefix, script_base) do
      scoped_imports(imports, normalized)
    else
      {:cont, :miss}
    end
  end

  defp scoped_imports(imports, normalized) do
    case match_imports(imports, normalized) do
      :miss -> {:cont, :miss}
      result -> {:halt, result}
    end
  end

  defp scope_match?(prefix, script_base) do
    prefix == script_base or
      (String.ends_with?(prefix, "/") and String.starts_with?(script_base, prefix))
  end

  defp match_imports(imports, normalized) do
    imports
    |> Enum.sort_by(fn {key, _address} ->
      if String.ends_with?(key, "/"), do: {1, -byte_size(key)}, else: {0, 0}
    end)
    |> Enum.reduce_while(:miss, fn {key, address}, :miss ->
      cond do
        key == normalized ->
          {:halt, finish(address)}

        String.ends_with?(key, "/") and String.starts_with?(normalized, key) ->
          {:halt, prefix_finish(normalized, key, address)}

        true ->
          {:cont, :miss}
      end
    end)
  end

  defp finish(:blocked), do: :blocked
  defp finish(url), do: {:ok, url}

  defp prefix_finish(_normalized, _key, :blocked), do: :blocked

  defp prefix_finish(normalized, key, address) do
    rest = binary_part(normalized, byte_size(key), byte_size(normalized) - byte_size(key))

    case URL.resolve(rest, address) do
      {:ok, url} -> if String.starts_with?(url, address), do: {:ok, url}, else: :blocked
      :skip -> :blocked
    end
  end

  defp merge_scopes(new_scopes, old_scopes) do
    new_scopes = Map.new(new_scopes)
    old_scopes = Map.new(old_scopes)

    (Map.keys(old_scopes) ++ Map.keys(new_scopes))
    |> Enum.uniq()
    |> Enum.map(fn prefix ->
      {prefix, Map.merge(Map.get(new_scopes, prefix, %{}), Map.get(old_scopes, prefix, %{}))}
    end)
    |> sort_scopes()
  end

  defp sort_scopes(scopes),
    do: Enum.sort_by(scopes, fn {prefix, _imports} -> -byte_size(prefix) end)

  # JSON objects keep the last duplicate key. Later normalization keeps the first address.
  defp collapse(pairs) do
    values = Enum.reduce(pairs, %{}, fn {key, value}, acc -> Map.put(acc, key, value) end)

    pairs
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(fn key -> {key, Map.fetch!(values, key)} end)
  end

  defp url_like?(specifier) do
    String.starts_with?(specifier, "/") or String.starts_with?(specifier, "./") or
      String.starts_with?(specifier, "../") or specifier =~ ~r/^[A-Za-z][A-Za-z0-9+.-]*:/
  end
end
