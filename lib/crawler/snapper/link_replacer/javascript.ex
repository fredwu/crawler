defmodule Crawler.Snapper.LinkReplacer.Javascript do
  @moduledoc false

  alias Crawler.Parser.JsParser

  # Only a real module specifier moves. The same text in a string, a comment,
  # prose, or a property call stays.
  def replace(source, variant, offline, goal \\ :module) do
    source
    |> JsParser.spans(goal)
    |> Enum.filter(fn {_at, _len, spec} -> spec == variant end)
    |> Enum.sort_by(fn {at, _len, _spec} -> at end, :desc)
    |> Enum.reduce(source, fn {at, len, _spec}, source ->
      head = binary_part(source, 0, at)
      tail = binary_part(source, at + len, byte_size(source) - at - len)
      head <> offline <> tail
    end)
  end
end
