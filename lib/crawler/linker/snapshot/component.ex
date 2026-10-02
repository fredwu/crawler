defmodule Crawler.Linker.Snapshot.Component do
  @moduledoc false

  @limit 255
  @marker "__sha256_"

  def marker, do: @marker

  def bound(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &bound_component/1)
  end

  defp bound_component(component) when byte_size(component) <= @limit, do: component

  defp bound_component(component) do
    digest = component |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    name = @marker <> digest
    extension = Path.extname(component)

    if byte_size(name) + byte_size(extension) <= @limit, do: name <> extension, else: name
  end
end
