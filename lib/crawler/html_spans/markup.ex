defmodule Crawler.HTMLSpans.Markup do
  @moduledoc false

  @opening ~r/<(?=[!?]|\/?[A-Za-z])/
  @space ~c" \t\n\f\r"

  def next(body, offset, foreign?) do
    tail = binary_part(body, offset, byte_size(body) - offset)

    case Regex.run(@opening, tail, return: :index) do
      [{start, 1}] ->
        start = offset + start

        case markup_finish(body, start, foreign?) do
          {finish, kind} -> {start, finish - start, kind}
          nil -> nil
        end

      nil ->
        nil
    end
  end

  def finish(body, start) do
    {finish, complete?, _attributes} = read(body, start)
    {finish, complete?}
  end

  def attributes(source) do
    {_finish, _complete?, attributes} = read(source, 0)
    attributes
  end

  defp read(body, start) do
    after_opening = if starts_with?(body, start, "</"), do: start + 2, else: start + 1
    offset = take_name(body, after_opening)
    read_attributes(body, offset, [])
  end

  defp markup_finish(body, start, foreign?) do
    cond do
      starts_with?(body, start, "<!--") ->
        {comment_finish(body, start + 4), :comment}

      foreign? and starts_with?(body, start, "<![CDATA[") ->
        {terminated(body, start + 9, "]]>"), :cdata}

      starts_with?(body, start, "<!") or starts_with?(body, start, "<?") ->
        {terminated(body, start + 2, ">"), :declaration}

      true ->
        case finish(body, start) do
          {finish, true} -> {finish, :tag}
          {_finish, false} -> nil
        end
    end
  end

  defp comment_finish(body, offset) do
    cond do
      starts_with?(body, offset, ">") -> offset + 1
      starts_with?(body, offset, "->") -> offset + 2
      true -> terminated(body, offset, ["-->", "--!>"])
    end
  end

  defp read_attributes(body, offset, acc) do
    start = skip_separators(body, offset)

    cond do
      start >= byte_size(body) ->
        {start, false, Enum.reverse(acc)}

      :binary.at(body, start) == ?> ->
        {start + 1, true, Enum.reverse(acc)}

      true ->
        name_end = take_name(body, start + 1)
        after_name = skip_space(body, name_end)
        {value_span, finish} = attribute_value(body, after_name)
        finish = if is_nil(value_span), do: name_end, else: finish

        attribute = %{
          span: {offset, finish - offset},
          name_span: {start, name_end - start},
          value_span: value_span
        }

        read_attributes(body, finish, [attribute | acc])
    end
  end

  defp attribute_value(body, offset) do
    if offset < byte_size(body) and :binary.at(body, offset) == ?= do
      start = skip_space(body, offset + 1)
      read_value(body, start)
    else
      {nil, offset}
    end
  end

  defp read_value(body, start) when start >= byte_size(body), do: {{start, 0}, start}

  defp read_value(body, start) do
    case :binary.at(body, start) do
      quote when quote in [?", ?'] ->
        value_start = start + 1
        value_end = quoted_end(body, value_start, quote)
        finish = if value_end < byte_size(body), do: value_end + 1, else: value_end
        {{value_start, value_end - value_start}, finish}

      _byte ->
        finish = unquoted_end(body, start)
        {{start, finish - start}, finish}
    end
  end

  defp take_name(body, offset) when offset >= byte_size(body), do: offset

  defp take_name(body, offset) do
    if :binary.at(body, offset) in (@space ++ ~c"/=>"),
      do: offset,
      else: take_name(body, offset + 1)
  end

  defp skip_separators(body, offset) when offset >= byte_size(body), do: offset

  defp skip_separators(body, offset) do
    if :binary.at(body, offset) in (@space ++ ~c"/"),
      do: skip_separators(body, offset + 1),
      else: offset
  end

  defp skip_space(body, offset) when offset >= byte_size(body), do: offset

  defp skip_space(body, offset) do
    if :binary.at(body, offset) in @space, do: skip_space(body, offset + 1), else: offset
  end

  defp unquoted_end(body, offset) when offset >= byte_size(body), do: offset

  defp unquoted_end(body, offset) do
    if :binary.at(body, offset) in (@space ++ ~c">"),
      do: offset,
      else: unquoted_end(body, offset + 1)
  end

  defp quoted_end(body, offset, quote) do
    case :binary.match(body, <<quote>>, scope: {offset, byte_size(body) - offset}) do
      {at, 1} -> at
      :nomatch -> byte_size(body)
    end
  end

  defp terminated(body, offset, terminator) do
    case :binary.match(body, terminator, scope: {offset, byte_size(body) - offset}) do
      {at, length} -> at + length
      :nomatch -> byte_size(body)
    end
  end

  defp starts_with?(body, start, prefix) do
    length = byte_size(prefix)
    start + length <= byte_size(body) and binary_part(body, start, length) == prefix
  end
end
