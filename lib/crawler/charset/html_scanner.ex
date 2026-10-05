defmodule Crawler.Charset.HTMLScanner do
  @moduledoc false

  alias Crawler.HTMLSpans

  def meta_spans(binary) do
    binary
    |> HTMLSpans.tags(attributes: false)
    |> Enum.filter(&(&1.name == "meta" and not &1.closing?))
    |> Enum.map(& &1.span)
  end

  def attributes(binary) do
    binary
    |> attribute_values()
    |> Enum.reduce(%{}, fn {name, value, _span}, attrs -> Map.put_new(attrs, name, value) end)
  end

  def find_attr_value(binary, name) do
    case Enum.find(attribute_values(binary), fn {key, _value, _span} -> key == name end) do
      {^name, _value, span} -> span
      nil -> nil
    end
  end

  defp attribute_values(binary) do
    binary
    |> HTMLSpans.attributes(0, decode: false)
    |> Enum.map(fn attr ->
      span =
        case attr.value_span do
          nil -> nil
          {start, length} -> {start, start + length}
        end

      {attr.name, attr.value, span}
    end)
  end
end
