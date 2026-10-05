defmodule Crawler.Charset.Parameters do
  @moduledoc false

  def values(binary) when is_binary(binary), do: values(binary, 0, [])

  def find_value(binary, name) do
    case Enum.find(values(binary), fn {key, _value, _span} -> key == name end) do
      {_key, _value, span} -> span
      nil -> nil
    end
  end

  defp values(<<>>, _offset, acc), do: Enum.reverse(acc)

  defp values(binary, offset, acc) do
    length = parameter_length(binary, 0, :key)
    parameter = binary_part(binary, 0, length)

    acc =
      case parameter_value(parameter, offset) do
        nil -> acc
        value -> [value | acc]
      end

    if length == byte_size(binary) do
      Enum.reverse(acc)
    else
      consumed = length + 1
      rest = binary_part(binary, consumed, byte_size(binary) - consumed)
      values(rest, offset + consumed, acc)
    end
  end

  defp parameter_length(<<>>, length, _state), do: length

  defp parameter_length(<<";", _rest::binary>>, length, state)
       when not is_integer(state),
       do: length

  defp parameter_length(<<"=", rest::binary>>, length, :key) do
    parameter_length(rest, length + 1, :value)
  end

  defp parameter_length(<<byte, rest::binary>>, length, :value)
       when byte in ~c" \t\n\f\r" do
    parameter_length(rest, length + 1, :value)
  end

  defp parameter_length(<<quote, rest::binary>>, length, :value)
       when quote in ~c"\"'" do
    parameter_length(rest, length + 1, quote)
  end

  defp parameter_length(<<"\\", _byte, rest::binary>>, length, quote)
       when is_integer(quote) do
    parameter_length(rest, length + 2, quote)
  end

  defp parameter_length(<<quote, rest::binary>>, length, quote) do
    parameter_length(rest, length + 1, :unquoted)
  end

  defp parameter_length(<<_byte, rest::binary>>, length, :value) do
    parameter_length(rest, length + 1, :unquoted)
  end

  defp parameter_length(<<_byte, rest::binary>>, length, state) do
    parameter_length(rest, length + 1, state)
  end

  defp parameter_value(parameter, offset) do
    case :binary.match(parameter, "=") do
      {equals, 1} ->
        key = parameter |> binary_part(0, equals) |> String.trim()
        input = binary_part(parameter, equals + 1, byte_size(parameter) - equals - 1)
        input = skip_space(input)
        start = offset + byte_size(parameter) - byte_size(input)
        {value, length, quote_size} = value(input)
        {key, value, {start + quote_size, start + quote_size + length}}

      :nomatch ->
        nil
    end
  end

  defp value(<<quote, rest::binary>>) when quote in ~c"\"'" do
    {value, length} = quoted_value(rest, quote, 0, [])
    {value, length, 1}
  end

  defp value(binary) do
    value = trim_space_end(binary)
    {value, byte_size(value), 0}
  end

  defp quoted_value(<<quote, _rest::binary>>, quote, length, acc) do
    {IO.iodata_to_binary(Enum.reverse(acc)), length}
  end

  defp quoted_value(<<"\\", byte, rest::binary>>, quote, length, acc) do
    quoted_value(rest, quote, length + 2, [byte | acc])
  end

  defp quoted_value(<<byte, rest::binary>>, quote, length, acc) do
    quoted_value(rest, quote, length + 1, [byte | acc])
  end

  defp quoted_value(<<>>, _quote, length, acc) do
    {IO.iodata_to_binary(Enum.reverse(acc)), length}
  end

  defp skip_space(<<byte, rest::binary>>) when byte in ~c" \t\n\f\r" do
    skip_space(rest)
  end

  defp skip_space(binary), do: binary

  defp trim_space_end(binary) do
    size = byte_size(binary)

    if size > 0 and :binary.at(binary, size - 1) in ~c" \t\n\f\r" do
      trim_space_end(binary_part(binary, 0, size - 1))
    else
      binary
    end
  end
end
