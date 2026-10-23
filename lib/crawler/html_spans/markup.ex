defmodule Crawler.HTMLSpans.Markup do
  @moduledoc false

  @opening ~r/<(?=[!?]|\/?[A-Za-z])/
  @space ~c" \t\n\f\r"

  alias Crawler.Analysis.Budget

  def next(body, offset, foreign?) do
    {:ok, result, _budget} = next_result(body, offset, foreign?, :discard, Budget.unlimited())
    if result, do: {elem(result, 0), elem(result, 1), elem(result, 2)}
  end

  def next_result(body, offset, foreign?, project, budget) do
    tail = binary_part(body, offset, byte_size(body) - offset)

    case Regex.run(@opening, tail, return: :index) do
      [{start, 1}] -> markup_finish(body, offset + start, foreign?, project, budget)
      nil -> {:ok, nil, budget}
    end
  end

  def finish(body, start) do
    {:ok, {finish, complete?, _attributes}, _budget} =
      read_result(body, start, :discard, Budget.unlimited())

    {finish, complete?}
  end

  def attributes(source) do
    {:ok, attributes, _budget} = attributes_result(source, &raw_attribute/4, Budget.unlimited())
    attributes
  end

  def attributes_result(source, project, budget) do
    with {:ok, {_finish, _complete?, attributes}, budget} <-
           read_result(source, 0, project, budget),
         do: {:ok, attributes, budget}
  end

  defp read_result(body, start, project, budget) do
    after_opening = if starts_with?(body, start, "</"), do: start + 2, else: start + 1
    offset = take_name(body, after_opening)
    read_attributes(body, offset, [], project, {after_opening, offset - after_opening}, budget)
  end

  defp markup_finish(body, start, foreign?, project, budget) do
    cond do
      starts_with?(body, start, "<!--") ->
        {:ok, {start, comment_finish(body, start + 4) - start, :comment, []}, budget}

      foreign? and starts_with?(body, start, "<![CDATA[") ->
        {:ok, {start, terminated(body, start + 9, "]]>") - start, :cdata, []}, budget}

      starts_with?(body, start, "<!") or starts_with?(body, start, "<?") ->
        {:ok, {start, terminated(body, start + 2, ">") - start, :declaration, []}, budget}

      true ->
        with {:ok, budget} <- Budget.charge(budget, Budget.cost(:tag), facts: 1),
             {:ok, {finish, complete?, attributes}, budget} <-
               read_result(body, start, project, budget) do
          result = if complete?, do: {start, finish - start, :tag, attributes}
          {:ok, result, budget}
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

  defp read_attributes(body, offset, acc, project, name_span, budget) do
    start = skip_separators(body, offset)

    cond do
      start >= byte_size(body) ->
        finish_attributes(start, false, acc, budget)

      :binary.at(body, start) == ?> ->
        finish_attributes(start + 1, true, acc, budget)

      project == :discard ->
        {_attribute, finish} = read_attribute(body, offset, start)
        read_attributes(body, finish, acc, project, name_span, budget)

      true ->
        with {:ok, budget} <- Budget.charge(budget, Budget.cost(:attribute), facts: 1),
             {:ok, budget} <- Budget.reserve(budget, Budget.cost(:attribute)) do
          {attribute, finish} = read_attribute(body, offset, start)

          with {:ok, attribute, budget} <- project.(body, attribute, name_span, budget),
               {:ok, budget} <- Budget.release(budget, Budget.cost(:attribute)) do
            read_attributes(body, finish, [attribute | acc], project, name_span, budget)
          end
        end
    end
  end

  defp finish_attributes(finish, complete?, acc, budget) do
    scratch = Budget.cost(:list_cell, length(acc))

    with {:ok, budget} <- Budget.reserve(budget, scratch) do
      attributes = Enum.reverse(acc)

      with {:ok, budget} <- Budget.release(budget, scratch),
           do: {:ok, {finish, complete?, attributes}, budget}
    end
  end

  defp read_attribute(body, offset, start) do
    name_end = take_name(body, start + 1)
    after_name = skip_space(body, name_end)
    {value_span, finish} = attribute_value(body, after_name)
    finish = if is_nil(value_span), do: name_end, else: finish

    {%{
       span: {offset, finish - offset},
       name_span: {start, name_end - start},
       value_span: value_span
     }, finish}
  end

  defp raw_attribute(_body, attribute, _finish, budget), do: {:ok, attribute, budget}

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
