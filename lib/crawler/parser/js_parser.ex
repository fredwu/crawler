defmodule Crawler.Parser.JsParser do
  @moduledoc """
  Finds literal JavaScript module specifiers in imports and re-exports.

  Decodes string escapes for URL resolution and keeps original byte spans for rewriting.
  The optional source goal is `:module` (default) or `:script` for classic JavaScript.
  """

  # Scanner masks literal contents. Only its completed string tokens can be specifiers.
  @from ~r/(?:^|[\n\r;}])\s*(?:import|export)\b[^;]*?\bfrom\s*(["'`])([^"'`]+)\1/
  @side_effect ~r/(?:^|[\n\r;}])\s*import\s*(["'`])([^"'`]+)\1/
  # The argument must end the call or start the options object. `+` does not.
  @dynamic ~r/\bimport\s*\(\s*(["'`])([^"'`]+)\1\s*[,)]/

  alias Crawler.Analysis.Budget
  alias Crawler.Parser.JsParser.Matches
  alias Crawler.Parser.JsParser.Scanner
  alias Crawler.Parser.JsParser.StringLiteral

  def elements(body, goal \\ :module)

  def elements(body, goal) when is_binary(body) do
    Enum.map(specs(body, goal), &{"link", [{"href", &1}], []})
  end

  def elements(_body, _goal), do: []

  def specs(body, goal \\ :module)

  def specs(body, goal) when is_binary(body) do
    body
    |> spans(goal)
    |> Enum.map(fn {_at, _len, spec} -> spec end)
    |> Enum.uniq()
  end

  def specs(_body, _goal), do: []

  @doc false
  def spans(body, goal \\ :module)

  def spans(body, goal) when is_binary(body) do
    body
    |> specifier_spans(goal)
    |> Enum.flat_map(fn {_kind, at, len, spec} ->
      if local?(spec), do: [{at, len, spec}], else: []
    end)
  end

  def spans(_body, _goal), do: []

  @doc false
  def specifier_spans(body, goal \\ :module)

  def specifier_spans(body, goal) when is_binary(body) do
    specifier_spans(body, goal, Scanner.scan(body, goal))
  end

  def specifier_spans(_body, _goal), do: []

  @doc false
  def specifier_spans(body, goal, scan) when is_binary(body) do
    {:ok, spans, _budget} = specifier_spans_result(body, goal, scan, Budget.unlimited())
    spans
  end

  def specifier_spans_result(body, _goal, {masked, strings, _comments}, budget)
      when is_binary(body) do
    scratch = byte_size(body) * Budget.cost(:token) + Budget.cost(:context, 8)

    with {:ok, budget} <- Budget.reserve(budget, scratch) do
      strings = MapSet.new(strings)

      result =
        Enum.reduce_while(
          [{:static, @from}, {:static, @side_effect}, {:dynamic, @dynamic}],
          {:ok, [], budget, 0},
          fn {kind, regex}, {:ok, acc, budget, retained} ->
            case span_matches(regex, kind, body, masked, strings, acc, budget, retained) do
              {:ok, acc, budget, retained} -> {:cont, {:ok, acc, budget, retained}}
              error -> {:halt, error}
            end
          end
        )

      with {:ok, spans, budget, retained} <- result,
           {:ok, budget} <- Budget.settle(budget, scratch, retained) do
        {:ok, Enum.reverse(spans), budget}
      end
    end
  end

  defp span_matches(regex, kind, original, masked, strings, acc, budget, retained) do
    result =
      Matches.reduce(regex, masked, {acc, budget, retained}, fn [_statement, _quote, {at, len}],
                                                                {acc, budget, retained} ->
        if MapSet.member?(strings, {at, at + len}) do
          with {:ok, budget} <- Budget.count(budget, :facts) do
            decode_span(original, kind, at, len, acc, budget, retained)
          else
            error -> {:halt, error}
          end
        else
          {:cont, {acc, budget, retained}}
        end
      end)

    case result do
      {:ok, {acc, budget, retained}} -> {:ok, acc, budget, retained}
      error -> error
    end
  end

  defp decode_span(original, kind, at, len, acc, budget, retained) do
    case StringLiteral.decode(binary_part(original, at, len)) do
      {:ok, spec} ->
        bytes =
          Budget.cost(:token) + Budget.cost(:binary) +
            Budget.cost(:list_cell, 2) + byte_size(spec)

        {:cont, {[{kind, at, len, spec} | acc], budget, retained + bytes}}

      :error ->
        {:cont, {acc, budget, retained}}
    end
  end

  defp local?(spec) do
    scheme = String.downcase(spec)

    String.starts_with?(spec, ".") or
      String.starts_with?(spec, "/") or
      String.starts_with?(scheme, "http://") or
      String.starts_with?(scheme, "https://")
  end
end
