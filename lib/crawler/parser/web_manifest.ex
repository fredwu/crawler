defmodule Crawler.Parser.WebManifest do
  @moduledoc false
  alias Crawler.Analysis.Budget
  alias Crawler.ImportMap.JSON
  alias Crawler.URL

  def entries(body, base) when is_binary(body) and is_binary(base) do
    case JSON.decode_located(body) do
      {:ok, decoded} -> entries_located(decoded, base)
      _other -> []
    end
  end

  def entries(_body, _base), do: []

  def entries_located(decoded, base) do
    {:ok, entries, _budget} =
      reduce_located(decoded, base, Budget.unlimited(), [], fn entry, acc, budget ->
        {:ok, [entry | acc], budget}
      end)

    Enum.reverse(entries)
  end

  def reduce_located(decoded, base, budget, acc, emit, images? \\ true)

  def reduce_located({:object, pairs}, base, budget, acc, emit, images?) when is_binary(base) do
    with {:ok, acc, budget} <-
           reference(field(pairs, "start_url"), base, :page, budget, acc, emit),
         {:ok, acc, budget} <- images(field(pairs, "icons"), base, budget, acc, emit, images?),
         {:ok, acc, budget} <-
           images(field(pairs, "screenshots"), base, budget, acc, emit, images?) do
      each(field(pairs, "shortcuts"), budget, acc, fn
        {:object, item}, acc, budget ->
          with {:ok, acc, budget} <-
                 reference(field(item, "url"), base, :page, budget, acc, emit),
               do: images(field(item, "icons"), base, budget, acc, emit, images?)

        _item, acc, budget ->
          {:ok, acc, budget}
      end)
    end
  end

  def reduce_located(_decoded, _base, budget, acc, _emit, _images?), do: {:ok, acc, budget}

  defp images(_items, _base, budget, acc, _emit, false), do: {:ok, acc, budget}

  defp images(items, base, budget, acc, emit, true) do
    each(items, budget, acc, fn
      {:object, pairs}, acc, budget ->
        reference(field(pairs, "src"), base, :image, budget, acc, emit)

      _item, acc, budget ->
        {:ok, acc, budget}
    end)
  end

  defp reference({:str, raw, start, length}, base, kind, budget, acc, emit) do
    with {:ok, _hypothetical} <- Budget.count(budget, :occurrences) do
      case URL.resolve_result(raw, base, budget) do
        {:ok, url, budget} ->
          with {:ok, budget} <- Budget.charge(budget, Budget.cost(:token)),
               do: emit.({kind, raw, url, start, length}, acc, budget)

        {:skip, budget} ->
          {:ok, acc, budget}

        error ->
          error
      end
    end
  end

  defp reference(_value, _base, _kind, budget, acc, _emit), do: {:ok, acc, budget}

  defp each(items, budget, acc, fun) when is_list(items) do
    Enum.reduce_while(items, {:ok, acc, budget}, fn item, {:ok, acc, budget} ->
      case fun.(item, acc, budget) do
        {:ok, acc, budget} -> {:cont, {:ok, acc, budget}}
        error -> {:halt, error}
      end
    end)
  end

  defp each(_items, budget, acc, _fun), do: {:ok, acc, budget}

  defp field(pairs, name),
    do:
      Enum.find_value(pairs, fn
        {^name, value} -> value
        _pair -> nil
      end)
end
