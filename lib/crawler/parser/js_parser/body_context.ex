defmodule Crawler.Parser.JsParser.BodyContext do
  @moduledoc false

  def new do
    %{
      headers: [],
      next: nil,
      prefix?: false,
      property?: false,
      depth: 0,
      line_boundary?: false,
      last_word: nil,
      pending_label?: false,
      case_labels: [],
      ternaries: []
    }
  end

  def reset(context) do
    %{
      context
      | next: nil,
        prefix?: false,
        property?: false,
        line_boundary?: false,
        last_word: nil,
        pending_label?: false
    }
  end

  def line_break(context, expression_complete?) do
    boundary? = expression_complete? or context.last_word in ["return", "yield"]
    %{context | line_boundary?: context.line_boundary? or boundary?}
  end

  def word(context, word, statement_start?) do
    declaration? = statement_start? or context.prefix? or context.line_boundary?

    prefix? =
      not context.property? and
        (word == "export" or (word in ["async", "default"] and declaration?))

    %{
      reset(context)
      | headers: track_header(context, word, declaration?),
        prefix?: prefix?,
        last_word: if(context.property?, do: nil, else: word),
        pending_label?:
          not context.property? and word not in ["case", "default"] and
            (statement_start? or context.line_boundary?),
        case_labels: track_case_label(context, word, declaration?)
    }
  end

  defp track_header(context, word, declaration?) do
    if word in ["function", "class"] and not context.property? do
      kind = if declaration?, do: :stmt, else: :expression_body
      [{word, kind, context.depth} | context.headers]
    else
      context.headers
    end
  end

  defp track_case_label(context, word, declaration?) do
    if word in ["case", "default"] and declaration? and not context.property?,
      do: [context.depth | context.case_labels],
      else: context.case_labels
  end

  def property(context), do: %{reset(context) | property?: true}
  def arrow(context), do: %{reset(context) | next: :expression_body}

  def operator(context, operator) do
    {statement_start?, context} = statement_boundary(context, operator)

    headers =
      if operator in [?=, ?,, ?:, ?;] do
        Enum.reject(context.headers, fn {_word, _kind, depth} -> depth == context.depth end)
      else
        context.headers
      end

    {statement_start?, %{reset(context) | headers: headers}}
  end

  defp statement_boundary(context, ??),
    do: {false, %{context | ternaries: [context.depth | context.ternaries]}}

  defp statement_boundary(%{ternaries: [depth | rest], depth: depth} = context, ?:) do
    {false, %{context | ternaries: rest}}
  end

  defp statement_boundary(%{case_labels: [depth | rest], depth: depth} = context, ?:) do
    {true, %{context | case_labels: rest}}
  end

  defp statement_boundary(%{pending_label?: true} = context, ?:), do: {true, context}

  defp statement_boundary(context, operator), do: {operator == ?;, context}

  def open_paren(
        %{headers: [{"function", kind, depth} | headers], depth: depth} = context,
        _fallback
      ) do
    {{:function, kind}, %{open(context) | headers: headers}}
  end

  def open_paren(context, fallback), do: {fallback, open(context)}

  def close_paren(context, {:function, kind}), do: %{close(context) | next: kind}
  def close_paren(context, _kind), do: close(context)

  def open_brace(%{next: kind} = context, _fallback) when not is_nil(kind) do
    {kind, open(context)}
  end

  def open_brace(
        %{headers: [{"class", kind, depth} | headers], depth: depth} = context,
        _fallback
      ) do
    {kind, %{open(context) | headers: headers}}
  end

  def open_brace(%{line_boundary?: true} = context, _fallback), do: {:stmt, open(context)}

  def open_brace(context, fallback), do: {fallback, open(context)}

  def open(context), do: %{reset(context) | depth: context.depth + 1}

  def close(context) do
    depth = max(context.depth - 1, 0)

    headers =
      Enum.reject(context.headers, fn {_word, _kind, header_depth} -> header_depth > depth end)

    %{
      reset(context)
      | depth: depth,
        headers: headers,
        case_labels: Enum.filter(context.case_labels, &(&1 <= depth)),
        ternaries: Enum.filter(context.ternaries, &(&1 <= depth))
    }
  end
end
