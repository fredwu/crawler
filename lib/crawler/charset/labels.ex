defmodule Crawler.Charset.Labels do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.Charset.Encoding
  alias Crawler.Charset.Parameters

  def http_charset(headers) do
    {:ok, label, _budget} = http_charset_result(headers, Budget.unlimited())
    label
  end

  def http_charset_result([header | rest], budget) do
    scratch = 2_048 + :erlang.external_size(header) * 512

    with {:ok, budget} <- Budget.reserve(budget, scratch) do
      case header_charset(header) do
        label when is_binary(label) ->
          with {:ok, budget} <- Budget.charge(budget, Budget.cost(:binary) + byte_size(label)) do
            label = :binary.copy(label)
            with {:ok, budget} <- Budget.release(budget, scratch), do: {:ok, label, budget}
          end

        _none ->
          with {:ok, budget} <- Budget.release(budget, scratch),
               do: http_charset_result(rest, budget)
      end
    end
  end

  def http_charset_result(_headers, budget), do: {:ok, nil, budget}

  defp header_charset({name, value}) do
    if ascii_lower(to_string(name)) == "content-type" do
      charset_param(to_string(value))
    end
  end

  defp header_charset(_header), do: nil

  def charset_param(value) when is_binary(value) do
    value
    |> :binary.split(";")
    |> Enum.at(1, "")
    |> Parameters.values()
    |> Enum.find_value(&parameter_charset/1)
  end

  defp parameter_charset({key, value, _span}) do
    if ascii_lower(key) == "charset", do: usable_label(normalize(value))
  end

  defp usable_label(label) do
    if known?(label), do: label
  end

  def normalize(value) when is_binary(value) do
    value = value |> trim_space() |> ascii_lower()

    if String.valid?(value) and value != "", do: value
  end

  def normalize(_value), do: nil

  defp trim_space(value), do: value |> skip_space() |> trim_space_end()

  defp trim_space_end(value) do
    size = byte_size(value)

    if size > 0 and :binary.at(value, size - 1) in ~c" \t\n\f\r" do
      trim_space_end(binary_part(value, 0, size - 1))
    else
      value
    end
  end

  def known?(label) when is_binary(label), do: Encoding.encoding(label) != :unknown
  def known?(_label), do: false

  defp skip_space(<<byte, rest::binary>>) when byte in ~c" \t\n\f\r" do
    skip_space(rest)
  end

  defp skip_space(binary), do: binary

  def ascii_lower(binary) when is_binary(binary) do
    for <<byte <- binary>>, into: <<>> do
      if byte in ?A..?Z, do: <<byte + 32>>, else: <<byte>>
    end
  end
end
