defmodule Crawler.Charset do
  @moduledoc false

  alias Crawler.MediaType

  @utf8_bom <<0xEF, 0xBB, 0xBF>>
  @utf16be_bom <<0xFE, 0xFF>>
  @utf16le_bom <<0xFF, 0xFE>>
  @replacement <<0xEF, 0xBF, 0xBD>>
  @prescan_bytes 1024

  @windows_1252 %{
    0x80 => 0x20AC,
    0x82 => 0x201A,
    0x83 => 0x0192,
    0x84 => 0x201E,
    0x85 => 0x2026,
    0x86 => 0x2020,
    0x87 => 0x2021,
    0x88 => 0x02C6,
    0x89 => 0x2030,
    0x8A => 0x0160,
    0x8B => 0x2039,
    0x8C => 0x0152,
    0x8E => 0x017D,
    0x91 => 0x2018,
    0x92 => 0x2019,
    0x93 => 0x201C,
    0x94 => 0x201D,
    0x95 => 0x2022,
    0x96 => 0x2013,
    0x97 => 0x2014,
    0x98 => 0x02DC,
    0x99 => 0x2122,
    0x9A => 0x0161,
    0x9B => 0x203A,
    0x9C => 0x0153,
    0x9E => 0x017E,
    0x9F => 0x0178
  }

  def decode(body, opts) when is_binary(body) do
    if textual?(opts[:content_type]), do: transcode(body, opts), else: body
  end

  def decode(body, _opts), do: body

  defp textual?(type) do
    MediaType.text?(type) or MediaType.javascript?(type) or MediaType.xhtml?(type)
  end

  defp transcode(body, opts) do
    decoded =
      case bom(body) do
        {:utf8, rest} ->
          to_utf8(rest)

        {:utf16, endian, rest} ->
          to_utf16(rest, endian)

        :none ->
          label = http_charset(opts[:headers]) || meta_charset(body, opts[:content_type])
          decode_label(body, label || "utf-8")
      end

    if MediaType.html?(opts[:content_type]), do: declare_utf8(decoded), else: decoded
  end

  defp bom(<<@utf8_bom, rest::binary>>), do: {:utf8, rest}
  defp bom(<<@utf16be_bom, rest::binary>>), do: {:utf16, :big, rest}
  defp bom(<<@utf16le_bom, rest::binary>>), do: {:utf16, :little, rest}
  defp bom(_body), do: :none

  defp http_charset(headers) when is_list(headers) do
    Enum.find_value(headers, &header_charset/1)
  end

  defp http_charset(_headers), do: nil

  defp header_charset({name, value}) do
    if ascii_lower(to_string(name)) == "content-type" do
      charset_param(to_string(value))
    end
  end

  defp header_charset(_header), do: nil

  defp charset_param(value) when is_binary(value) do
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
    if ascii_lower(String.trim(key)) == "charset", do: usable_label(clean_label(value))
  end

  defp usable_label(label) do
    if known_label?(label), do: label
  end

  defp meta_charset(body, content_type) do
    if MediaType.html?(content_type) do
      body
      |> prescan_chunk()
      |> ascii_lower()
      |> find_meta(0)
    end
  end

  defp prescan_chunk(body) do
    binary_part(body, 0, min(byte_size(body), @prescan_bytes))
  end

  defp find_meta(binary, offset) when offset >= byte_size(binary), do: nil

  defp find_meta(binary, offset) do
    comment = match_at(binary, "<!--", offset)
    meta = match_at(binary, "<meta", offset)

    cond do
      earlier?(comment, meta) ->
        {start, _size} = comment
        find_meta(binary, skip_comment(binary, start + 4))

      meta == :nomatch ->
        nil

      true ->
        {start, size} = meta
        read_meta(binary, start + size)
    end
  end

  defp match_at(binary, pattern, offset) do
    :binary.match(binary, pattern, scope: {offset, byte_size(binary) - offset})
  end

  defp earlier?({comment, _}, {meta, _}), do: comment < meta
  defp earlier?({_comment, _}, :nomatch), do: true
  defp earlier?(_comment, _meta), do: false

  defp skip_comment(binary, offset) do
    case match_at(binary, "-->", offset) do
      :nomatch -> byte_size(binary)
      {start, size} -> start + size
    end
  end

  defp read_meta(binary, next) do
    if meta_tag?(binary, next) do
      {tag, after_tag} = read_tag(binary, next, nil, [])
      meta_label(binary, tag, after_tag)
    else
      find_meta(binary, next)
    end
  end

  defp meta_label(binary, tag, after_tag) do
    case attrs_charset(tag) do
      label when is_binary(label) ->
        if known_label?(label), do: label, else: find_meta(binary, after_tag)

      _ ->
        find_meta(binary, after_tag)
    end
  end

  defp meta_tag?(binary, position) do
    position >= byte_size(binary) or :binary.at(binary, position) in ~c" \t\n\r/>"
  end

  defp read_tag(binary, position, _quote, acc) when position >= byte_size(binary) do
    {IO.iodata_to_binary(acc), position}
  end

  defp read_tag(binary, position, nil, acc) do
    case :binary.at(binary, position) do
      ?> ->
        {IO.iodata_to_binary(acc), position + 1}

      quote when quote in ~c"\"'" ->
        read_tag(binary, position + 1, quote, [acc, quote])

      byte ->
        read_tag(binary, position + 1, nil, [acc, byte])
    end
  end

  defp read_tag(binary, position, quote, acc) do
    byte = :binary.at(binary, position)
    next_quote = if byte == quote, do: nil, else: quote
    read_tag(binary, position + 1, next_quote, [acc, byte])
  end

  defp attrs_charset(tag) do
    attrs = parse_attrs(tag, %{})

    case charset_attr(attrs["charset"]) do
      label when is_binary(label) ->
        label

      _ ->
        if attrs["http-equiv"] == "content-type" do
          charset_param(";" <> (attrs["content"] || ""))
        end
    end
  end

  defp charset_attr(value) when is_binary(value) and value != "" do
    case clean_label(value) do
      label when is_binary(label) -> label
      _ -> nil
    end
  end

  defp charset_attr(_value), do: nil

  defp parse_attrs(<<>>, acc), do: acc
  defp parse_attrs(<<">", _rest::binary>>, acc), do: acc

  defp parse_attrs(<<byte, rest::binary>>, acc) when byte in ~c" \t\n\r/" do
    parse_attrs(rest, acc)
  end

  defp parse_attrs(binary, acc) do
    {name, rest} = take_name(binary, [])
    rest = skip_space(rest)

    case rest do
      <<"=", rest::binary>> ->
        rest = skip_space(rest)
        {value, rest} = take_value(rest)
        parse_attrs(rest, Map.put(acc, name, value))

      rest ->
        parse_attrs(rest, acc)
    end
  end

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

  defp clean_label(value) when is_binary(value) do
    value = value |> trim_space() |> trim_quotes() |> trim_space() |> ascii_lower()

    cond do
      not String.valid?(value) -> "utf-8"
      value == "" -> nil
      true -> value
    end
  end

  defp clean_label(_value), do: nil

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

  defp decode_label(body, label) do
    case encoding(label) do
      :utf8 -> to_utf8(body)
      :windows_1252 -> windows_1252(body)
      {:utf16, endian} -> to_utf16(body, endian)
      :unknown -> to_utf8(body)
    end
  end

  defp encoding("utf-8"), do: :utf8
  defp encoding("utf8"), do: :utf8
  defp encoding("windows-1252"), do: :windows_1252
  defp encoding("iso-8859-1"), do: :windows_1252
  defp encoding("latin1"), do: :windows_1252
  defp encoding("latin-1"), do: :windows_1252
  defp encoding("ascii"), do: :windows_1252
  defp encoding("us-ascii"), do: :windows_1252
  defp encoding("utf-16"), do: {:utf16, :big}
  defp encoding("utf-16be"), do: {:utf16, :big}
  defp encoding("utf-16le"), do: {:utf16, :little}
  defp encoding(_label), do: :unknown

  defp known_label?(label) when is_binary(label), do: encoding(label) != :unknown
  defp known_label?(_label), do: false

  defp to_utf8(body), do: replace_invalid(body, :utf8, [])
  defp to_utf16(body, endian), do: replace_invalid(body, {:utf16, endian}, [])

  defp replace_invalid(<<>>, _encoding, acc), do: IO.iodata_to_binary(acc)

  defp replace_invalid(body, encoding, acc) do
    case :unicode.characters_to_binary(body, encoding, :utf8) do
      utf8 when is_binary(utf8) ->
        IO.iodata_to_binary([acc, utf8])

      {:error, good, rest} ->
        replace_invalid(drop_bad(rest, encoding), encoding, [acc, good, @replacement])

      {:incomplete, good, _rest} ->
        IO.iodata_to_binary([acc, good, @replacement])
    end
  end

  defp drop_bad(<<_, rest::binary>>, :utf8), do: rest
  defp drop_bad(<<_, _, rest::binary>>, {:utf16, _endian}), do: rest
  defp drop_bad(_rest, _encoding), do: <<>>

  defp windows_1252(body) do
    for <<byte <- body>>, into: "" do
      <<win_codepoint(byte)::utf8>>
    end
  end

  defp win_codepoint(byte) when byte <= 0x7F or byte >= 0xA0, do: byte
  defp win_codepoint(byte), do: Map.get(@windows_1252, byte, 0xFFFD)

  # The saved document is UTF-8. A meta that still names another encoding
  # would make a browser open a different path from the file that was fetched.
  defp declare_utf8(body), do: declare_utf8(body, ascii_lower(body), 0, [])

  defp declare_utf8(body, _lowered, offset, acc) when offset >= byte_size(body) do
    IO.iodata_to_binary(acc)
  end

  defp declare_utf8(body, lowered, offset, acc) do
    case next_meta_span(lowered, offset) do
      nil ->
        IO.iodata_to_binary([acc, binary_part(body, offset, byte_size(body) - offset)])

      {start, stop} ->
        chunk = binary_part(body, offset, start - offset)
        tag = binary_part(body, start, stop - start)
        declare_utf8(body, lowered, stop, [acc, chunk, rewrite_tag(tag)])
    end
  end

  defp next_meta_span(binary, offset) when offset >= byte_size(binary), do: nil

  defp next_meta_span(binary, offset) do
    comment = match_at(binary, "<!--", offset)
    meta = match_at(binary, "<meta", offset)

    cond do
      earlier?(comment, meta) ->
        {start, _size} = comment
        next_meta_span(binary, skip_comment(binary, start + 4))

      meta == :nomatch ->
        nil

      true ->
        {start, size} = meta
        pos = start + size

        if meta_tag?(binary, pos) do
          {start, tag_boundary(binary, pos)}
        else
          next_meta_span(binary, pos)
        end
    end
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

  defp rewrite_tag(tag) do
    tag = if content_type_meta?(tag), do: rewrite_content_charset(tag), else: tag
    rewrite_charset_attr(tag)
  end

  defp content_type_meta?(tag) do
    tag |> ascii_lower() |> parse_attrs(%{}) |> Map.get("http-equiv") == "content-type"
  end

  defp rewrite_charset_attr(tag) do
    case find_attr_value(ascii_lower(tag), "charset") do
      {start, finish} -> replace_label(tag, start, finish)
      _ -> tag
    end
  end

  defp rewrite_content_charset(tag) do
    case find_attr_value(ascii_lower(tag), "content") do
      nil ->
        tag

      {start, finish} ->
        value = binary_part(tag, start, finish - start)
        splice(tag, start, finish, rewrite_charset_param(value))
    end
  end

  defp rewrite_charset_param(value) do
    case find_attr_value(ascii_lower(value), "charset") do
      {start, finish} -> replace_label(value, start, finish)
      _ -> value
    end
  end

  defp replace_label(binary, start, finish) do
    label = binary |> binary_part(start, finish - start) |> clean_label()

    if known_non_utf8?(label) do
      splice(binary, start, finish, "utf-8")
    else
      binary
    end
  end

  defp known_non_utf8?(label) when is_binary(label) do
    encoding(label) not in [:utf8, :unknown]
  end

  defp known_non_utf8?(_label), do: false

  defp splice(binary, start, finish, replacement) do
    head = binary_part(binary, 0, start)
    tail = binary_part(binary, finish, byte_size(binary) - finish)
    head <> replacement <> tail
  end

  defp find_attr_value(binary, name), do: find_attr_value(binary, name, 0, nil)

  defp find_attr_value(binary, _name, offset, _quote) when offset >= byte_size(binary) do
    nil
  end

  defp find_attr_value(binary, name, offset, quote) when is_integer(quote) do
    next = if :binary.at(binary, offset) == quote, do: nil, else: quote
    find_attr_value(binary, name, offset + 1, next)
  end

  defp find_attr_value(binary, name, offset, nil) do
    byte = :binary.at(binary, offset)

    cond do
      byte in ~c"\"'" ->
        find_attr_value(binary, name, offset + 1, byte)

      match_name?(binary, name, offset) ->
        case span_after_equals(binary, offset + byte_size(name)) do
          nil -> find_attr_value(binary, name, offset + 1, nil)
          span -> span
        end

      true ->
        find_attr_value(binary, name, offset + 1, nil)
    end
  end

  defp match_name?(binary, name, offset) do
    size = byte_size(name)
    finish = offset + size

    finish <= byte_size(binary) and binary_part(binary, offset, size) == name and
      boundary_before?(binary, offset) and boundary_after?(binary, finish)
  end

  defp boundary_before?(_binary, 0), do: true

  defp boundary_before?(binary, offset) do
    :binary.at(binary, offset - 1) in ~c" \t\n\r/;>"
  end

  defp boundary_after?(binary, offset) when offset >= byte_size(binary), do: true

  defp boundary_after?(binary, offset) do
    :binary.at(binary, offset) in ~c" \t\n\r=/>"
  end

  defp span_after_equals(binary, offset) do
    offset = skip_index(binary, offset)

    if offset < byte_size(binary) and :binary.at(binary, offset) == ?= do
      inner_span(binary, skip_index(binary, offset + 1))
    end
  end

  defp inner_span(binary, offset) when offset >= byte_size(binary), do: nil

  defp inner_span(binary, offset) do
    byte = :binary.at(binary, offset)

    if byte in ~c"\"'" do
      quoted_span(binary, offset + 1, byte)
    else
      {offset, unquoted_end(binary, offset)}
    end
  end

  defp quoted_span(binary, offset, _quote) when offset >= byte_size(binary) do
    {offset, offset}
  end

  defp quoted_span(binary, offset, quote) do
    size = byte_size(binary) - offset

    case :binary.match(binary, <<quote>>, scope: {offset, size}) do
      {finish, 1} -> {offset, finish}
      :nomatch -> {offset, byte_size(binary)}
    end
  end

  defp unquoted_end(binary, offset) when offset >= byte_size(binary), do: offset

  defp unquoted_end(binary, offset) do
    if :binary.at(binary, offset) in ~c" \t\n\r>" do
      offset
    else
      unquoted_end(binary, offset + 1)
    end
  end

  defp skip_index(binary, offset) when offset >= byte_size(binary), do: offset

  defp skip_index(binary, offset) do
    if :binary.at(binary, offset) in ~c" \t\n\r" do
      skip_index(binary, offset + 1)
    else
      offset
    end
  end

  defp ascii_lower(binary) when is_binary(binary) do
    for <<byte <- binary>>, into: <<>> do
      if byte in ?A..?Z, do: <<byte + 32>>, else: <<byte>>
    end
  end
end
