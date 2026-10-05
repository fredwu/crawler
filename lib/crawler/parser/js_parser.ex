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
    {masked, strings} = Scanner.scan(body, goal)
    strings = MapSet.new(strings)

    [@from, @side_effect, @dynamic]
    |> Enum.flat_map(&span_matches(&1, body, masked, strings))
    |> Enum.filter(fn {_at, _len, spec} -> local?(spec) end)
  end

  def spans(_body, _goal), do: []

  defp span_matches(regex, original, masked, strings) do
    regex
    |> Regex.scan(masked, return: :index)
    |> Enum.flat_map(fn [_statement, _quote, {spec_at, spec_len}] ->
      with true <- MapSet.member?(strings, {spec_at, spec_at + spec_len}),
           {:ok, spec} <- StringLiteral.decode(binary_part(original, spec_at, spec_len)) do
        [{spec_at, spec_len, spec}]
      else
        _ -> []
      end
    end)
  end

  defp local?(spec) do
    scheme = String.downcase(spec)

    String.starts_with?(spec, ".") or
      String.starts_with?(spec, "/") or
      String.starts_with?(scheme, "http://") or
      String.starts_with?(scheme, "https://")
  end
end
