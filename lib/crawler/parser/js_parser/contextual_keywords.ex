defmodule Crawler.Parser.JsParser.ContextualKeywords do
  @moduledoc false

  alias Crawler.Parser.JsParser.ClassField
  alias Crawler.Parser.JsParser.MethodHeader

  @white_space [0x09, 0x0B, 0x0C, 0x20, 0xA0, 0x1680, 0x202F, 0x205F, 0x3000, 0xFEFF]

  def new(goal \\ :module) when goal in [:script, :module] do
    %{
      scopes: [scope(:root, 0, if(goal == :module, do: ["await"], else: []))],
      function: nil,
      method: nil,
      fields: [],
      computed: [],
      members: [],
      containers: [],
      property_head: nil,
      pending_body: nil,
      parens: [],
      arrow: nil
    }
  end

  def keyword?(%{scopes: [frame | _]}, word) when word in ["await", "yield"],
    do: word in frame.forced

  def keyword?(_context, _word), do: true

  def word(context, word, depth, property?, previous, rest) do
    next = next_token(rest)
    context = field_key(context, depth)

    method =
      MethodHeader.word(
        context.method,
        word,
        depth,
        context.property_head == depth,
        next,
        class_container?(context, depth)
      )

    function =
      if word == "function" and not property? and not MethodHeader.ready?(method, depth + 1),
        do: %{depth: depth, forced: if(previous == "async", do: ["await"], else: [])},
        else: context.function

    arrow =
      if next == :arrow and not property?,
        do: scope(:arrow, depth, if(previous == "async", do: ["await"], else: [])),
        else: nil

    %{
      context
      | function: function,
        method: method,
        arrow: arrow,
        property_head: nil
    }
  end

  def literal_key(context, depth) do
    context = field_key(context, depth)

    %{
      context
      | method: MethodHeader.key(context.method, depth, context.property_head == depth),
        property_head: nil
    }
  end

  def line_break(context, depth) do
    method = MethodHeader.line_break(context.method, depth)

    property_head =
      if context.method != nil and method == nil and container?(context, depth),
        do: depth,
        else: context.property_head

    %{context | method: method, property_head: property_head}
  end

  def open_paren(context, {:function, _kind}, depth, _previous) do
    forced =
      cond do
        MethodHeader.ready?(context.method, depth) -> context.method.forced
        context.function != nil -> context.function.forced
        true -> []
      end

    enter_function(context, depth, forced)
  end

  def open_paren(context, _kind, depth, previous) do
    if MethodHeader.ready?(context.method, depth) do
      enter_function(context, depth, context.method.forced)
    else
      candidate = scope(:arrow, depth, if(previous == "async", do: ["await"], else: []))
      %{context | parens: [candidate | context.parens]}
    end
  end

  defp enter_function(context, depth, forced) do
    member? = MethodHeader.ready?(context.method, depth) and class_container?(context, depth - 1)
    frame = Map.put(scope(:function, depth, forced), :member?, member?)
    fields = if member?, do: ClassField.finish(context.fields, depth - 1), else: context.fields

    %{
      context
      | scopes: [frame | context.scopes],
        fields: fields,
        function: nil,
        method: nil,
        parens: [{:function, frame, context.scopes} | context.parens]
    }
  end

  def close_paren(%{parens: [{:function, frame, scopes} | parens]} = context, depth) do
    %{
      context
      | scopes: scopes,
        parens: parens,
        pending_body: %{frame | depth: depth + 1}
    }
  end

  def close_paren(%{parens: [candidate | parens]} = context, depth) do
    %{close(context, depth) | parens: parens, arrow: %{candidate | depth: depth}}
  end

  def close_paren(context, depth), do: close(context, depth)

  def open_brace(%{pending_body: frame} = context, _kind, depth, _container?)
      when not is_nil(frame),
      do: %{
        context
        | scopes: [%{frame | depth: depth} | context.scopes],
          pending_body: nil,
          members: if(frame.member?, do: [depth | context.members], else: context.members)
      }

  def open_brace(context, _kind, depth, kind) when kind in [:object, :class],
    do: open_container(context, depth, kind)

  def open_brace(context, _kind, depth, nil) do
    if class_container?(context, depth - 1) and match?(%{phase: :static}, context.method),
      do: %{
        context
        | members: [depth | context.members],
          method: nil,
          fields: ClassField.finish(context.fields, depth - 1)
      },
      else: context
  end

  defp open_container(context, depth, kind),
    do: %{
      context
      | containers: [%{depth: depth, kind: kind} | context.containers],
        property_head: depth
    }

  defp container?(context, depth),
    do: Enum.any?(context.containers, &(&1.depth == depth))

  defp class_container?(context, depth),
    do: Enum.any?(context.containers, &(&1.depth == depth and &1.kind == :class))

  def open_bracket(context, depth) do
    context = field_key(context, depth)
    header = MethodHeader.key(context.method, depth, context.property_head == depth)

    if MethodHeader.ready?(header, depth + 1) do
      %{context | computed: [header | context.computed], method: nil, property_head: nil}
    else
      context
    end
  end

  def close_bracket(context, depth) do
    context = close(context, depth)

    case context.computed do
      [%{depth: ^depth} = header | computed] -> %{context | method: header, computed: computed}
      _ -> context
    end
  end

  def close_brace(context, depth) do
    member? = (depth + 1) in context.members
    context = close(context, depth)
    %{context | property_head: if(member?, do: depth, else: nil)}
  end

  def arrow(context, depth, conditions) do
    frame = Map.put(context.arrow || scope(:arrow, depth, []), :conditions, conditions)
    %{context | scopes: [%{frame | depth: depth} | context.scopes], pending_body: nil, arrow: nil}
  end

  def arrow_block?(
        %{pending_body: nil, scopes: [%{kind: :arrow, depth: depth} | _]},
        %{depth: depth, next: :expression_body}
      ),
      do: true

  def arrow_block?(_context, _body), do: false

  def block_arrow(%{scopes: [frame | scopes]} = context, depth),
    do: %{context | scopes: [%{frame | depth: depth, kind: :function} | scopes]}

  def operator(context, operator, depth, conditions) do
    context = end_arrow(context, operator, depth, conditions)

    function =
      case {context.function, operator} do
        {%{depth: ^depth} = header, ?*} -> %{header | forced: ["yield" | header.forced]}
        {_header, op} when op in [?=, ?,, ?:, ?;] -> nil
        {header, _op} -> header
      end

    %{
      context
      | function: function,
        fields: ClassField.operator(context.fields, operator, depth),
        method:
          MethodHeader.operator(context.method, operator, depth, context.property_head == depth),
        arrow: nil,
        property_head:
          if(operator in [?;, ?,] and container?(context, depth), do: depth, else: nil)
    }
  end

  def close(context, depth) do
    depth = max(depth, 0)

    %{
      context
      | scopes: Enum.filter(context.scopes, &(&1.depth <= depth)),
        containers: Enum.filter(context.containers, &(&1.depth <= depth)),
        computed: Enum.filter(context.computed, &(&1.depth <= depth)),
        fields: ClassField.close(context.fields, depth),
        members: Enum.filter(context.members, &(&1 <= depth)),
        method: MethodHeader.close(context.method, depth),
        property_head: nil
    }
  end

  def expression_owned?(context, depth) do
    match?([%{kind: :arrow, depth: ^depth} | _], context.scopes) or
      ClassField.active?(context.fields, depth)
  end

  def field_key?(context, depth), do: ClassField.key?(context.fields, depth)

  def header_pending?(context, body) do
    depth = body.depth

    context.pending_body != nil or context.function != nil or
      match?(%{depth: ^depth, phase: phase} when phase in [:prefix, :static], context.method) or
      (Enum.any?(body.headers, fn {_word, _kind, depth} -> depth == body.depth end) and
         not ClassField.key?(context.fields, body.depth))
  end

  defp field_key(context, depth) do
    if context.property_head == depth and class_container?(context, depth),
      do: %{context | fields: ClassField.start(context.fields, depth)},
      else: context
  end

  defp end_arrow(
         %{scopes: [%{kind: :arrow, depth: depth} = frame | scopes]} = context,
         op,
         depth,
         conditions
       ) do
    if op in [?;, ?,] or (op == ?: and frame.conditions > conditions),
      do: end_arrow(%{context | scopes: scopes}, op, depth, conditions),
      else: context
  end

  defp end_arrow(context, _operator, _depth, _conditions), do: context
  defp scope(kind, depth, forced), do: %{kind: kind, depth: depth, forced: forced}

  defp next_token(<<char::utf8, rest::binary>>)
       when char in @white_space or char in 0x2000..0x200A or char in [0x0A, 0x0D, 0x2028, 0x2029],
       do: next_token(rest)

  defp next_token(<<"/*", rest::binary>>) do
    case :binary.match(rest, "*/") do
      {at, 2} -> next_token(binary_part(rest, at + 2, byte_size(rest) - at - 2))
      :nomatch -> nil
    end
  end

  defp next_token(<<"//", rest::binary>>) do
    case :binary.match(rest, ["\n", "\r", <<0x2028::utf8>>, <<0x2029::utf8>>]) do
      {at, length} -> next_token(binary_part(rest, at + length, byte_size(rest) - at - length))
      :nomatch -> nil
    end
  end

  defp next_token(<<"=>", _rest::binary>>), do: :arrow
  defp next_token(<<char, _rest::binary>>), do: char
  defp next_token(<<>>), do: nil
end
