defmodule Crawler.Charset.Labels do
  @moduledoc false

  alias Crawler.Charset.Encoding

  def http_charset(headers) when is_list(headers) do
    Enum.find_value(headers, &header_charset/1)
  end

  def http_charset(_headers), do: nil

  defp header_charset({name, value}) do
    if ascii_lower(to_string(name)) == "content-type" do
      charset_param(to_string(value))
    end
  end

  defp header_charset(_header), do: nil

  def charset_param(value) when is_binary(value) do
    if String.valid?(value) do
      value
      |> String.split(";")
      |> Enum.drop(1)
      |> Enum.find_value(&parameter_charset/1)
    end
  end

  defp parameter_charset(part) do
    case String.split(part, "=", parts: 2) do
      [key, value] -> charset_parameter(key, value)
      _ -> nil
    end
  end

  defp charset_parameter(key, value) do
    if ascii_lower(String.trim(key)) == "charset", do: usable_label(normalize(value))
  end

  defp usable_label(label) do
    if known?(label), do: label
  end

  def normalize(value) when is_binary(value) do
    value = value |> trim_space() |> trim_quotes() |> trim_space() |> ascii_lower()

    cond do
      not String.valid?(value) -> "utf-8"
      value == "" -> nil
      true -> value
    end
  end

  def normalize(_value), do: nil

  defp trim_space(value), do: value |> skip_space() |> trim_space_end()

  defp trim_space_end(value) do
    size = byte_size(value)

    if size > 0 and :binary.at(value, size - 1) in ~c" \t\n\r" do
      trim_space_end(binary_part(value, 0, size - 1))
    else
      value
    end
  end

  defp trim_quotes(<<quote, rest::binary>>) when quote in ~c"\"'" do
    trim_end_quote(rest, quote)
  end

  defp trim_quotes(value), do: value

  defp trim_end_quote(value, quote) do
    size = byte_size(value)

    if size > 0 and :binary.at(value, size - 1) == quote do
      binary_part(value, 0, size - 1)
    else
      value
    end
  end

  def known?(label) when is_binary(label), do: Encoding.encoding(label) != :unknown
  def known?(_label), do: false

  defp skip_space(<<byte, rest::binary>>) when byte in ~c" \t\n\r" do
    skip_space(rest)
  end

  defp skip_space(binary), do: binary

  def ascii_lower(binary) when is_binary(binary) do
    for <<byte <- binary>>, into: <<>> do
      if byte in ?A..?Z, do: <<byte + 32>>, else: <<byte>>
    end
  end
end
