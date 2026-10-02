defmodule Crawler.Charset.HTMLScanner do
  @moduledoc false

  @text_tags ~w(script style title textarea xmp iframe noembed noframes)

  def next_meta_span(binary, offset) when offset >= byte_size(binary), do: nil

  def next_meta_span(binary, offset) do
    case match_at(binary, "<", offset) do
      :nomatch -> nil
      {start, 1} -> read_markup(binary, start)
    end
  end

  defp read_markup(binary, start) do
    cond do
      starts_with?(binary, start, "<!--") ->
        next_meta_span(binary, skip_comment(binary, start + 4))

      named_tag?(binary, start, "meta") ->
        {start, tag_boundary(binary, start + 5)}

      named_tag?(binary, start, "plaintext") ->
        nil

      tag_start?(binary, start + 1) ->
        skip_tag(binary, start)

      true ->
        next_meta_span(binary, start + 1)
    end
  end

  defp skip_tag(binary, start) do
    after_tag = tag_boundary(binary, start + 1)

    case Enum.find(@text_tags, &named_tag?(binary, start, &1)) do
      nil -> next_meta_span(binary, after_tag)
      name -> skip_text(binary, after_tag, name)
    end
  end

  defp skip_text(binary, offset, name) do
    case match_at(binary, "</" <> name, offset) do
      :nomatch ->
        nil

      {start, size} ->
        if tag_name_boundary?(binary, start + size) do
          next_meta_span(binary, tag_boundary(binary, start + size))
        else
          skip_text(binary, start + size, name)
        end
    end
  end

  defp named_tag?(binary, start, name) do
    starts_with?(binary, start, "<" <> name) and
      tag_name_boundary?(binary, start + byte_size(name) + 1)
  end

  defp starts_with?(binary, offset, value) do
    size = byte_size(value)
    offset + size <= byte_size(binary) and binary_part(binary, offset, size) == value
  end

  defp tag_start?(binary, offset) when offset >= byte_size(binary), do: false

  defp tag_start?(binary, offset) do
    byte = :binary.at(binary, offset)
    byte in ?a..?z or byte in ~c"!?" or (byte == ?/ and tag_start?(binary, offset + 1))
  end

  defp tag_boundary(binary, position), do: tag_boundary(binary, position, nil)

  defp tag_boundary(binary, position, _quote) when position >= byte_size(binary) do
    position
  end

  defp tag_boundary(binary, position, nil) do
    case :binary.at(binary, position) do
      ?> -> position + 1
      quote when quote in ~c"\"'" -> tag_boundary(binary, position + 1, quote)
      _byte -> tag_boundary(binary, position + 1, nil)
    end
  end

  defp tag_boundary(binary, position, quote) do
    byte = :binary.at(binary, position)
    next_quote = if byte == quote, do: nil, else: quote
    tag_boundary(binary, position + 1, next_quote)
  end

  defp match_at(binary, pattern, offset) do
    :binary.match(binary, pattern, scope: {offset, byte_size(binary) - offset})
  end

  defp skip_comment(binary, offset) do
    case match_at(binary, "-->", offset) do
      :nomatch -> byte_size(binary)
      {start, size} -> start + size
    end
  end

  defp tag_name_boundary?(binary, position) do
    position >= byte_size(binary) or :binary.at(binary, position) in ~c" \t\n\r/>"
  end

  def attributes(binary) do
    binary |> attribute_values() |> Map.new(fn {name, value, _span} -> {name, value} end)
  end

  def find_attr_value(binary, name) do
    binary
    |> attribute_values()
    |> Enum.find_value(fn
      {^name, _value, span} -> span
      _attribute -> nil
    end)
  end

  defp attribute_values(binary), do: attribute_values(binary, byte_size(binary), [])

  defp attribute_values(<<>>, _size, acc), do: Enum.reverse(acc)
  defp attribute_values(<<">", _rest::binary>>, _size, acc), do: Enum.reverse(acc)

  defp attribute_values(<<byte, rest::binary>>, size, acc) when byte in ~c" \t\n\r/" do
    attribute_values(rest, size, acc)
  end

  defp attribute_values(binary, size, acc) do
    {name, rest} = take_name(binary, [])

    case skip_space(rest) do
      <<"=", rest::binary>> ->
        input = skip_space(rest)
        {value, rest} = take_value(input)
        start = size - byte_size(input) + quote_size(input)
        attribute = {name, value, {start, start + byte_size(value)}}
        attribute_values(rest, size, [attribute | acc])

      rest ->
        attribute_values(rest, size, acc)
    end
  end

  def find_parameter_value(binary, name) do
    find_parameter_value(binary, name, byte_size(binary))
  end

  defp find_parameter_value(<<>>, _name, _size), do: nil

  defp find_parameter_value(binary, name, size) do
    {parameter, rest} = take_parameter(binary, nil, [])

    case parameter_value(parameter, name) do
      nil -> find_parameter_value(rest, name, size)
      {start, finish} -> {size - byte_size(binary) + start, size - byte_size(binary) + finish}
    end
  end

  defp parameter_value(parameter, name) do
    case :binary.match(parameter, "=") do
      {equals, 1} ->
        key = binary_part(parameter, 0, equals)
        input = binary_part(parameter, equals + 1, byte_size(parameter) - equals - 1)
        input = skip_space(input)

        if String.trim(key) == name do
          {value, _rest} = take_value(input)
          start = byte_size(parameter) - byte_size(input) + quote_size(input)
          {start, start + byte_size(value)}
        end

      :nomatch ->
        nil
    end
  end

  defp take_parameter(<<>>, _quote, acc), do: {IO.iodata_to_binary(acc), <<>>}

  defp take_parameter(<<";", rest::binary>>, nil, acc) do
    {IO.iodata_to_binary(acc), rest}
  end

  defp take_parameter(<<byte, rest::binary>>, nil, acc) when byte in ~c"\"'" do
    take_parameter(rest, byte, [acc, byte])
  end

  defp take_parameter(<<byte, rest::binary>>, quote, acc) do
    next_quote = if byte == quote, do: nil, else: quote
    take_parameter(rest, next_quote, [acc, byte])
  end

  defp quote_size(<<quote, _rest::binary>>) when quote in ~c"\"'", do: 1
  defp quote_size(_binary), do: 0

  defp take_name(<<>>, acc), do: {IO.iodata_to_binary(acc), <<>>}

  defp take_name(<<byte, rest::binary>>, acc) when byte in ~c" \t\n\r/=>" do
    {IO.iodata_to_binary(acc), <<byte, rest::binary>>}
  end

  defp take_name(<<byte, rest::binary>>, acc) do
    take_name(rest, [acc, byte])
  end

  defp take_value(<<quote, rest::binary>>) when quote in ~c"\"'" do
    take_quoted(rest, quote, [])
  end

  defp take_value(binary), do: take_unquoted(binary, [])

  defp take_quoted(<<quote, rest::binary>>, quote, acc) do
    {IO.iodata_to_binary(acc), rest}
  end

  defp take_quoted(<<byte, rest::binary>>, quote, acc) do
    take_quoted(rest, quote, [acc, byte])
  end

  defp take_quoted(<<>>, _quote, acc), do: {IO.iodata_to_binary(acc), <<>>}

  defp take_unquoted(<<>>, acc), do: {IO.iodata_to_binary(acc), <<>>}

  defp take_unquoted(<<byte, rest::binary>>, acc) when byte in ~c" \t\n\r>" do
    {IO.iodata_to_binary(acc), <<byte, rest::binary>>}
  end

  defp take_unquoted(<<byte, rest::binary>>, acc) do
    take_unquoted(rest, [acc, byte])
  end

  defp skip_space(<<byte, rest::binary>>) when byte in ~c" \t\n\r" do
    skip_space(rest)
  end

  defp skip_space(binary), do: binary
end
