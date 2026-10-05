defmodule Crawler.Parser.JsParser.MethodHeader do
  @moduledoc false

  def word(header, word, depth, start?, next, class?) do
    cond do
      start? and class? and word == "static" and next != ?( ->
        new(depth, [], :static)

      start? ->
        begin_header(word, depth, next)

      header != nil and header.depth == depth and header.phase == :static ->
        begin_header(word, depth, next)

      prefix?(header, depth) ->
        %{header | phase: :key}

      header != nil and header.depth == depth ->
        nil

      true ->
        header
    end
  end

  def key(header, depth, start?) do
    cond do
      start? -> new(depth, [], :key)
      prefix?(header, depth) -> %{header | phase: :key}
      true -> header
    end
  end

  def operator(header, ?*, depth, start?) do
    cond do
      start? -> new(depth, ["yield"], :prefix)
      prefix?(header, depth) -> %{header | forced: ["yield" | header.forced], phase: :prefix}
      true -> header
    end
  end

  def operator(%{depth: depth}, operator, depth, _start?) when operator in [?=, ?,, ?:, ?;],
    do: nil

  def operator(header, _operator, _depth, _start?), do: header

  def line_break(%{depth: depth, phase: :prefix, forced: ["await"]}, depth), do: nil
  def line_break(header, _depth), do: header

  def ready?(%{depth: start, phase: :key}, depth), do: start == depth - 1
  def ready?(_header, _depth), do: false

  def close(%{depth: start}, depth) when start > depth, do: nil
  def close(header, _depth), do: header

  defp begin_header("async", depth, next) when next != ?(,
    do: new(depth, ["await"], :prefix)

  defp begin_header(word, depth, next) when word in ["get", "set"] and next != ?(,
    do: new(depth, [], :prefix)

  defp begin_header(_word, depth, _next), do: new(depth, [], :key)
  defp new(depth, forced, phase), do: %{depth: depth, forced: forced, phase: phase}
  defp prefix?(%{depth: depth, phase: phase}, depth) when phase in [:prefix, :static], do: true
  defp prefix?(_header, _depth), do: false
end
