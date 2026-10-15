defmodule Crawler.Parser.WebManifest do
  @moduledoc false

  alias Crawler.ImportMap.JSON
  alias Crawler.URL

  def entries(body, base) when is_binary(body) and is_binary(base) do
    case JSON.decode_located(body) do
      {:ok, {:object, pairs}} ->
        page(field(pairs, "start_url"), base) ++
          images(field(pairs, "icons"), base) ++
          images(field(pairs, "screenshots"), base) ++
          shortcuts(field(pairs, "shortcuts"), base)

      _other ->
        []
    end
  end

  def entries(_body, _base), do: []

  defp shortcuts(items, base) when is_list(items) do
    Enum.flat_map(items, fn
      {:object, pairs} ->
        page(field(pairs, "url"), base) ++ images(field(pairs, "icons"), base)

      _other ->
        []
    end)
  end

  defp shortcuts(_items, _base), do: []

  defp images(items, base) when is_list(items) do
    Enum.flat_map(items, fn
      {:object, pairs} -> image(field(pairs, "src"), base)
      _other -> []
    end)
  end

  defp images(_items, _base), do: []

  defp page({:str, raw, start, length}, base), do: resolve(raw, base, :page, start, length)
  defp page(_raw, _base), do: []

  defp image({:str, raw, start, length}, base), do: resolve(raw, base, :image, start, length)
  defp image(_raw, _base), do: []

  defp resolve(raw, base, kind, start, length) do
    case URL.resolve(raw, base) do
      {:ok, url} -> [{kind, raw, url, start, length}]
      :skip -> []
    end
  end

  defp field(pairs, name) do
    Enum.find_value(pairs, fn
      {^name, value} -> value
      _pair -> nil
    end)
  end
end
