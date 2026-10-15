defmodule Crawler.Snapper.LinkReplacer.Json do
  @moduledoc false

  def replace_spans(body, spans) when is_binary(body) and is_list(spans) do
    spans
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.reduce(body, fn {start, length, offline}, body ->
      replace_span(body, start, length, offline)
    end)
  end

  def replace_spans(body, _spans), do: body

  defp replace_span(body, start, length, offline) do
    head = binary_part(body, 0, start)
    tail = binary_part(body, start + length, byte_size(body) - start - length)
    head <> encode(offline) <> tail
  end

  defp encode(value) do
    <<?", escape(value)::binary, ?">>
  end

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end
end
