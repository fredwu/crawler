defmodule Crawler.Parser.Srcset do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.HTMLSpans

  @candidate ~r/^[\t\n\f\r ,]*([^\t\n\f\r ]+)/

  def urls(value), do: Enum.map(spans(value), fn {_start, _length, url} -> url end)

  def replace(value, variant, offline) do
    {decoded, segments} = HTMLSpans.decode_with_spans(value)

    edits =
      for {start, length, url} <- spans(decoded), url == variant do
        {HTMLSpans.source_span(segments, {start, length}), offline}
      end

    HTMLSpans.rewrite(value, edits)
  end

  def spans(value) do
    {:ok, spans, _budget} = spans_result(value, Budget.unlimited())
    spans
  end

  def spans_result(value, budget), do: collect(value, 0, [], budget)

  defp collect(value, offset, acc, budget) do
    case Regex.run(@candidate, value, return: :index) do
      [{0, consumed}, {start, length}] ->
        with {:ok, budget} <- Budget.charge(budget, Budget.cost(:token), facts: 1),
             {:ok, budget} <- Budget.reserve(budget, length + Budget.cost(:binary)) do
          raw = binary_part(value, start, length)
          url = String.trim_trailing(raw, ",")
          {tail, consumed} = candidate_tail(value, consumed, raw)
          acc = if url == "", do: acc, else: [{offset + start, byte_size(url), url} | acc]

          with {:ok, budget} <- Budget.release(budget, length + Budget.cost(:binary)),
               do: collect(tail, offset + consumed, acc, budget)
        end

      nil ->
        {:ok, Enum.reverse(acc), budget}
    end
  end

  defp candidate_tail(value, consumed, url) do
    tail = binary_part(value, consumed, byte_size(value) - consumed)

    if String.ends_with?(url, ",") do
      {tail, consumed}
    else
      {tail, length} = skip_descriptors(tail, 0, false)
      {tail, consumed + length}
    end
  end

  defp skip_descriptors(<<>>, length, _in_parens), do: {"", length}
  defp skip_descriptors(<<?,, tail::binary>>, length, false), do: {tail, length + 1}

  defp skip_descriptors(<<?(, tail::binary>>, length, false),
    do: skip_descriptors(tail, length + 1, true)

  defp skip_descriptors(<<?), tail::binary>>, length, true),
    do: skip_descriptors(tail, length + 1, false)

  defp skip_descriptors(<<_char, tail::binary>>, length, in_parens),
    do: skip_descriptors(tail, length + 1, in_parens)
end
