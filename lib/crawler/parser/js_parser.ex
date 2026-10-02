defmodule Crawler.Parser.JsParser do
  @moduledoc """
  Finds static JavaScript module specifiers.
  """

  # A specifier statement may start after a newline, a semicolon, or `}`.
  # A quote cannot, so the match does not enter a string.
  @from ~r/(?:^|[\n;}])\s*(?:import|export)\b[^'";]*?\bfrom\s*(["'`])([^"'`]+)\1/
  @side_effect ~r/(?:^|[\n;}])\s*import\s*(["'`])([^"'`]+)\1/
  # A property call such as `obj.import("./x")` is not the import keyword.
  # The argument must end the call or start the options object. `+` does not.
  @dynamic ~r/(?<!\.)\bimport\s*\(\s*(["'`])([^"'`]+)\1\s*[,)]/

  alias Crawler.Parser.JsParser.Scanner

  def elements(body) when is_binary(body) do
    Enum.map(specs(body), &{"link", [{"href", &1}], []})
  end

  def elements(_body), do: []

  def specs(body) when is_binary(body) do
    body
    |> spans()
    |> Enum.map(fn {_at, _len, spec} -> spec end)
    |> Enum.uniq()
  end

  def specs(_body), do: []

  @doc false
  def spans(body) when is_binary(body) do
    {masked, ranges} = Scanner.scan(body)

    [@from, @side_effect, @dynamic]
    |> Enum.flat_map(&span_matches(&1, body, masked, ranges))
    |> Enum.filter(fn {_at, _len, spec} -> local?(spec) end)
  end

  def spans(_body), do: []

  defp span_matches(regex, original, masked, ranges) do
    regex
    |> Regex.scan(masked, return: :index)
    |> Enum.flat_map(fn [{at, len}, _quote, {spec_at, spec_len}] ->
      if keyword_in_code?(masked, at, len, ranges) and not property_import?(masked, at, len) do
        [{spec_at, spec_len, binary_part(original, spec_at, spec_len)}]
      else
        []
      end
    end)
  end

  # `obj. import("./x")` and `obj./* c */import("./x")` are property calls.
  # Comments are spaces here, so skip those spaces before checking for `.`.
  defp property_import?(source, at, len) do
    case :binary.match(binary_part(source, at, len), "import") do
      {index, _length} -> previous_non_space(source, at + index) == ?.
      :nomatch -> false
    end
  end

  defp previous_non_space(_source, index) when index <= 0, do: nil

  defp previous_non_space(source, index) do
    case :binary.at(source, index - 1) do
      byte when byte in [?\s, ?\t, ?\n, ?\r, ?\f] -> previous_non_space(source, index - 1)
      byte -> byte
    end
  end

  # The specifier itself is a string. Reject the match only when the
  # import or export keyword is inside one.
  defp keyword_in_code?(source, at, len, ranges) do
    key_at =
      case :binary.match(binary_part(source, at, len), ["import", "export"]) do
        {index, _length} -> at + index
        :nomatch -> at
      end

    not inside_string?(ranges, key_at)
  end

  defp inside_string?(ranges, index) do
    Enum.any?(ranges, fn {start, stop} -> index >= start and index < stop end)
  end

  defp local?(spec) do
    scheme = String.downcase(spec)

    not String.contains?(spec, "${") and
      (String.starts_with?(spec, ".") or
         String.starts_with?(spec, "/") or
         String.starts_with?(scheme, "http://") or
         String.starts_with?(scheme, "https://"))
  end
end
