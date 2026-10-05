defmodule Crawler.Parser.JsParser.ExpressionBoundary do
  @moduledoc false

  alias Crawler.Parser.JsParser.Identifier

  def confirmed?(source, %{line_boundary?: true, property?: false}, false, field_key?),
    do: starts_statement?(source, field_key?)

  def confirmed?(_source, _body, _pending?, _field_key?), do: false

  defp starts_statement?(<<char, _rest::binary>>, true) when char in [?*, ?[], do: true

  defp starts_statement?(<<char, _rest::binary>>, _field_key?)
       when char in [?", ?', ?{, ?#, ?~] or char in ?0..?9,
       do: true

  defp starts_statement?(<<"++", _rest::binary>>, _field_key?), do: true
  defp starts_statement?(<<"--", _rest::binary>>, _field_key?), do: true
  defp starts_statement?(<<"!=", _rest::binary>>, _field_key?), do: false
  defp starts_statement?(<<"!", _rest::binary>>, _field_key?), do: true

  defp starts_statement?(source, field_key?) do
    case Identifier.take(source) do
      {:ok, raw, _name, _rest} -> field_key? or raw not in ["in", "instanceof"]
      :none -> false
    end
  end
end
