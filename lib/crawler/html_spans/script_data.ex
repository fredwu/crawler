defmodule Crawler.HTMLSpans.ScriptData do
  @moduledoc false

  alias Crawler.HTMLSpans.Markup

  @boundary ~c"\t\n\f\r />"

  def finish(body), do: scan(body, 0, :data, 0)

  defp scan(body, offset, _mode, _dashes) when offset >= byte_size(body),
    do: {byte_size(body), byte_size(body)}

  defp scan(body, offset, :data, _dashes) do
    case :binary.match(body, "<", scope: {offset, byte_size(body) - offset}) do
      {start, 1} -> data_less_than(body, start)
      :nomatch -> {byte_size(body), byte_size(body)}
    end
  end

  defp scan(body, offset, mode, dashes) do
    case :binary.at(body, offset) do
      ?- -> scan(body, offset + 1, mode, min(dashes + 1, 2))
      ?> when dashes == 2 -> scan(body, offset + 1, :data, 0)
      ?< -> escaped_less_than(body, offset, mode)
      _byte -> scan(body, offset + 1, mode, 0)
    end
  end

  defp data_less_than(body, start) do
    cond do
      starts_with?(body, start, "<!--") -> scan(body, start + 4, :escaped, 2)
      starts_with?(body, start, "</") -> closing_tag(body, start, :data)
      true -> scan(body, start + 1, :data, 0)
    end
  end

  defp escaped_less_than(body, start, :escaped) do
    if starts_with?(body, start, "</") do
      closing_tag(body, start, :escaped)
    else
      escape_marker(body, start + 1, :escaped, :double_escaped)
    end
  end

  defp escaped_less_than(body, start, :double_escaped) do
    if starts_with?(body, start, "</") do
      escape_marker(body, start + 2, :double_escaped, :escaped)
    else
      scan(body, start + 1, :double_escaped, 0)
    end
  end

  defp closing_tag(body, start, mode) do
    {finish, script?} = script_name(body, start + 2)

    if script? do
      case Markup.finish(body, start) do
        {consumed, true} -> {start, consumed}
        {_consumed, false} -> {byte_size(body), byte_size(body)}
      end
    else
      scan(body, finish, mode, 0)
    end
  end

  defp escape_marker(body, offset, mode, next_mode) do
    {finish, script?} = script_name(body, offset)

    if script?,
      do: scan(body, finish + 1, next_mode, 0),
      else: scan(body, finish, mode, 0)
  end

  defp script_name(body, offset) do
    finish = alpha_end(body, offset)

    script? =
      finish - offset == 6 and finish < byte_size(body) and
        :binary.at(body, finish) in @boundary and
        String.downcase(binary_part(body, offset, 6), :ascii) == "script"

    {finish, script?}
  end

  defp alpha_end(body, offset) when offset >= byte_size(body), do: offset

  defp alpha_end(body, offset) do
    byte = :binary.at(body, offset)

    if byte in ?A..?Z or byte in ?a..?z,
      do: alpha_end(body, offset + 1),
      else: offset
  end

  defp starts_with?(body, start, prefix) do
    length = byte_size(prefix)
    start + length <= byte_size(body) and binary_part(body, start, length) == prefix
  end
end
