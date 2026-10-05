defmodule Crawler.Snapper.LinkReplacer.Tokens do
  @moduledoc false

  def prefix(values, marker) do
    find_prefix(values, <<0>> <> marker, marker)
  end

  def at(prefix, index), do: prefix <> Integer.to_string(index) <> <<0>>

  defp find_prefix(values, prefix, marker) do
    if Enum.any?(values, &String.contains?(&1, prefix)) do
      find_prefix(values, prefix <> marker, marker)
    else
      prefix
    end
  end
end
