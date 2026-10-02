defmodule Crawler.Snapper.LinkReplacer.Javascript do
  @moduledoc false

  alias Crawler.MediaType
  alias Crawler.Parser.JsParser

  # Only a real module specifier moves. The same text in a string, a comment,
  # prose, or a property call stays.
  def replace(source, variant, offline) do
    source
    |> JsParser.spans()
    |> Enum.filter(fn {_at, _len, spec} -> spec == variant end)
    |> Enum.sort_by(fn {at, _len, _spec} -> at end, :desc)
    |> Enum.reduce(source, fn {at, len, _spec}, source ->
      head = binary_part(source, 0, at)
      tail = binary_part(source, at + len, byte_size(source) - at - len)
      head <> offline <> tail
    end)
  end

  def source?(attrs) do
    with {:ok, fragment} <- Floki.parse_fragment("<script " <> attrs <> "></script>") do
      type =
        fragment
        |> Floki.attribute("script", "type")
        |> List.first()
        |> to_string()
        |> String.trim()
        |> String.downcase()

      type in ["", "module"] or MediaType.javascript?(type)
    else
      _ -> false
    end
  end
end
