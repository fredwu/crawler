defmodule Crawler.Parser.JsParser.ClassField do
  @moduledoc false

  def start(fields, depth), do: [%{depth: depth, phase: :key} | finish(fields, depth)]
  def finish(fields, depth), do: Enum.reject(fields, &(&1.depth == depth))
  def active?(fields, depth), do: Enum.any?(fields, &(&1.depth == depth))
  def key?(fields, depth), do: Enum.any?(fields, &(&1.depth == depth and &1.phase == :key))
  def close(fields, depth), do: Enum.filter(fields, &(&1.depth <= depth))

  def operator(fields, ?=, depth) do
    Enum.map(fields, fn
      %{depth: ^depth} = field -> %{field | phase: :value}
      field -> field
    end)
  end

  def operator(fields, ?;, depth), do: finish(fields, depth)
  def operator(fields, _operator, _depth), do: fields
end
