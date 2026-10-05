defmodule Crawler.Parser.JsParser.Scanner do
  @moduledoc false

  alias Crawler.Parser.JsParser.BodyContext
  alias Crawler.Parser.JsParser.ContextualKeywords
  alias Crawler.Parser.JsParser.ExpressionBoundary
  alias Crawler.Parser.JsParser.ForHeader
  alias Crawler.Parser.JsParser.Identifier

  @regex_prefix_keywords ~w(
    await case delete do else export extends in instanceof new return throw typeof void yield
  )
  @statement_heads ~w(if while for with switch catch)
  @block_heads ~w(do else finally try)
  @specifier_keywords ~w(import export from)
  @number ~r/^(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|(?:[0-9][0-9_]*(?:\.[0-9_]*)?|\.[0-9][0-9_]*)(?:[eE][+-]?[0-9_]+)?)[n]?/
  @line_terminators ["\n", "\r", <<0x2028::utf8>>, <<0x2029::utf8>>]
  @white_space [?\s, ?\t, 0x0B, ?\f, 0xA0, 0x1680, 0x202F, 0x205F, 0x3000, 0xFEFF]

  # Comments and regex literals become spaces of the same length, with
  # newlines kept, so later matches use original byte indexes. Quoted contents
  # and non-specifier identifiers are masked too; completed literal ranges
  # identify specifiers. Unicode line terminators become an LF and two spaces
  # to keep original byte indexes. ECMAScript whitespace becomes equal-byte-length spaces.
  def scan(source, goal \\ :module) do
    mask(source, [], %{
      state: :code,
      quote: nil,
      regex_allowed?: true,
      parens: [],
      braces: [],
      block_allowed?: true,
      body: BodyContext.new(),
      keywords: ContextualKeywords.new(goal),
      templates: [],
      interpolation_depth: 0,
      statement_header: nil,
      for_headers: [],
      size: byte_size(source),
      string_start: nil,
      strings: []
    })
  end

  defp mask(source, acc, context) do
    scan_token(source, acc, statement_context(source, context))
  end

  defp statement_context(
         source,
         %{state: :code, regex_allowed?: false, body: %{line_boundary?: true}} = context
       ) do
    depth = context.body.depth
    pending? = ContextualKeywords.header_pending?(context.keywords, context.body)

    if ContextualKeywords.expression_owned?(context.keywords, depth) and
         ExpressionBoundary.confirmed?(
           source,
           context.body,
           pending?,
           ContextualKeywords.field_key?(context.keywords, depth)
         ) do
      {_statement?, body} = BodyContext.operator(context.body, ?;)
      keywords = ContextualKeywords.operator(context.keywords, ?;, depth, length(body.ternaries))
      %{code_context(context, true, true) | body: body, keywords: keywords}
    else
      context
    end
  end

  defp statement_context(_source, context), do: context

  defp scan_token(<<"#!", rest::binary>>, acc, %{state: :code, size: size} = context)
       when byte_size(rest) + 2 == size do
    {line, rest} = split_line(rest)
    mask(rest, [spaces_keep_nl("#!" <> line) | acc], comment_context(context, line))
  end

  defp scan_token(<<>>, acc, context) do
    {IO.iodata_to_binary(Enum.reverse(acc)), Enum.reverse(context.strings)}
  end

  defp scan_token(<<char, rest::binary>>, acc, %{state: :code} = context)
       when char in [?\r, ?\n] do
    mask(rest, [<<char>> | acc], line_break_context(context))
  end

  defp scan_token(<<char::utf8, rest::binary>>, acc, %{state: :code} = context)
       when char in @white_space or char in 0x2000..0x200A do
    mask(rest, [spaces(byte_size(<<char::utf8>>)) | acc], context)
  end

  defp scan_token(<<char::utf8, rest::binary>>, acc, %{state: :code} = context)
       when char in [0x2028, 0x2029] do
    mask(rest, ["\n  " | acc], line_break_context(context))
  end

  defp scan_token(<<"//", rest::binary>>, acc, %{state: :code} = context) do
    {line, rest} = split_line(rest)
    mask(rest, [spaces_keep_nl("//" <> line) | acc], comment_context(context, line))
  end

  defp scan_token(<<"/*", rest::binary>>, acc, %{state: :code} = context) do
    {block, rest} = split_block(rest)
    mask(rest, [spaces_keep_nl("/*" <> block) | acc], comment_context(context, block))
  end

  defp scan_token(<<?/, rest::binary>>, acc, %{state: :code, regex_allowed?: true} = context) do
    case take_regex(rest, 0, false) do
      {:ok, n, rest} ->
        mask(rest, [spaces(n + 2) | acc], code_context(context, false))

      :no ->
        mask(rest, ["/" | acc], code_context(context, true))
    end
  end

  defp scan_token(<<?/, rest::binary>>, acc, %{state: :code} = context) do
    mask(rest, ["/" | acc], code_context(context, true))
  end

  defp scan_token(
         <<?`, rest::binary>>,
         acc,
         %{state: :code, interpolation_depth: interpolation_depth, templates: templates} = context
       ) do
    mask(rest, ["`" | acc], %{
      code_context(context, false)
      | state: :string,
        quote: ?`,
        interpolation_depth: 0,
        templates: [%{depth: interpolation_depth, grammar: nil} | templates],
        string_start: context.size - byte_size(rest)
    })
  end

  defp scan_token(<<quote, rest::binary>>, acc, %{state: :code} = context)
       when quote in [?", ?'] do
    context = %{
      context
      | keywords: ContextualKeywords.literal_key(context.keywords, context.body.depth)
    }

    mask(rest, [<<quote>> | acc], %{
      code_context(context, false)
      | state: :string,
        quote: quote,
        string_start: context.size - byte_size(rest)
    })
  end

  defp scan_token(<<"...", rest::binary>>, acc, %{state: :code} = context) do
    mask(rest, ["..." | acc], code_context(context, true))
  end

  defp scan_token(<<?., digit, _rest::binary>> = source, acc, %{state: :code} = context)
       when digit in ?0..?9,
       do: mask_number(source, acc, context)

  defp scan_token(<<?., rest::binary>>, acc, %{state: :code} = context) do
    mask(rest, ["." | acc], %{
      code_context(context, false)
      | body: BodyContext.property(context.body)
    })
  end

  defp scan_token(<<"?.", rest::binary>>, acc, %{state: :code} = context) do
    mask(rest, ["?." | acc], %{
      code_context(context, false)
      | body: BodyContext.property(context.body)
    })
  end

  defp scan_token(<<"??", rest::binary>>, acc, %{state: :code} = context) do
    mask(rest, ["??" | acc], code_context(context, true))
  end

  defp scan_token(<<char, _rest::binary>> = source, acc, %{state: :code} = context)
       when char in ?0..?9,
       do: mask_number(source, acc, context)

  defp scan_token(
         <<?(, rest::binary>>,
         acc,
         %{state: :code, parens: parens} = context
       ) do
    fallback = if context.statement_header, do: :stmt, else: :expr
    {kind, body} = BodyContext.open_paren(context.body, fallback)

    mask(rest, ["(" | acc], %{
      code_context(context, true)
      | parens: [kind | parens],
        body: body,
        keywords:
          ContextualKeywords.open_paren(
            context.keywords,
            kind,
            body.depth,
            context.body.last_word
          ),
        for_headers: ForHeader.open(context.for_headers, context.statement_header, body.depth)
    })
  end

  defp scan_token(<<?), rest::binary>>, acc, %{state: :code, parens: [kind | parens]} = context) do
    mask(rest, [")" | acc], %{
      code_context(context, kind == :stmt, kind == :stmt)
      | parens: parens,
        body: BodyContext.close_paren(context.body, kind),
        keywords: ContextualKeywords.close_paren(context.keywords, context.body.depth - 1),
        for_headers: ForHeader.close(context.for_headers, context.body.depth)
    })
  end

  defp scan_token(<<?), rest::binary>>, acc, %{state: :code} = context) do
    mask(rest, [")" | acc], code_context(context, false))
  end

  defp scan_token(
         <<?{, rest::binary>>,
         acc,
         %{state: :code, interpolation_depth: interpolation_depth, braces: braces} = context
       ) do
    fallback = if context.block_allowed? or not context.regex_allowed?, do: :stmt, else: :expr
    {kind, body} = BodyContext.open_brace(context.body, fallback)

    keywords =
      if ContextualKeywords.arrow_block?(context.keywords, context.body),
        do: ContextualKeywords.block_arrow(context.keywords, body.depth),
        else:
          ContextualKeywords.open_brace(
            context.keywords,
            kind,
            body.depth,
            cond do
              match?([{"class", _, _} | _], context.body.headers) -> :class
              kind == :expr -> :object
              true -> nil
            end
          )

    mask(rest, ["{" | acc], %{
      code_context(context, true, kind != :expr)
      | braces: [kind | braces],
        body: body,
        keywords: keywords,
        interpolation_depth: if(interpolation_depth > 0, do: interpolation_depth + 1, else: 0)
    })
  end

  defp scan_token(
         <<?}, rest::binary>>,
         acc,
         %{state: :code, interpolation_depth: 1, templates: [frame | templates]} = context
       ) do
    context = Map.merge(context, frame.grammar)

    mask(rest, ["}" | acc], %{
      code_context(context, false)
      | state: :string,
        quote: ?`,
        templates: [%{frame | grammar: nil} | templates],
        interpolation_depth: 0,
        string_start: nil
    })
  end

  defp scan_token(
         <<?}, rest::binary>>,
         acc,
         %{state: :code, interpolation_depth: interpolation_depth, braces: [kind | braces]} =
           context
       ) do
    body = BodyContext.close(context.body)
    statement? = kind == :stmt and not ForHeader.binding?(context.for_headers, body.depth)

    mask(rest, ["}" | acc], %{
      code_context(context, statement?, statement?)
      | braces: braces,
        body: body,
        keywords: ContextualKeywords.close_brace(context.keywords, body.depth),
        interpolation_depth: max(interpolation_depth - 1, 0)
    })
  end

  defp scan_token(<<?}, rest::binary>>, acc, %{state: :code} = context) do
    mask(rest, ["}" | acc], code_context(context, true, true))
  end

  defp scan_token(<<?], rest::binary>>, acc, %{state: :code} = context) do
    mask(rest, ["]" | acc], %{
      code_context(context, false)
      | body: BodyContext.close(context.body),
        keywords: ContextualKeywords.close_bracket(context.keywords, context.body.depth - 1)
    })
  end

  defp scan_token(<<?[, rest::binary>>, acc, %{state: :code} = context) do
    mask(rest, ["[" | acc], %{
      code_context(context, true)
      | body: BodyContext.open(context.body),
        keywords: ContextualKeywords.open_bracket(context.keywords, context.body.depth)
    })
  end

  defp scan_token(<<"=>", rest::binary>>, acc, %{state: :code} = context) do
    mask(rest, ["=>" | acc], %{
      code_context(context, true)
      | body: BodyContext.arrow(context.body),
        keywords:
          ContextualKeywords.arrow(
            context.keywords,
            context.body.depth,
            length(context.body.ternaries)
          )
    })
  end

  defp scan_token(<<operator::binary-size(2), rest::binary>>, acc, %{state: :code} = context)
       when operator in ["++", "--"] do
    mask(rest, [operator | acc], code_context(context, context.regex_allowed?))
  end

  defp scan_token(<<char, rest::binary>>, acc, %{state: :code} = context)
       when char in [?=, ?,, ?:, ?;, ?!, ?&, ?|, ??, ?~, ?^, ?%, ?*, ?+, ?-, ?<, ?>] do
    {statement_start?, body} = BodyContext.operator(context.body, char)

    mask(rest, [<<char>> | acc], %{
      code_context(context, true, statement_start?)
      | body: body,
        keywords:
          ContextualKeywords.operator(
            context.keywords,
            char,
            context.body.depth,
            length(body.ternaries)
          ),
        for_headers: ForHeader.operator(context.for_headers, context.body.depth, char)
    })
  end

  defp scan_token(<<?\\, char::utf8, rest::binary>>, acc, %{state: :string} = context) do
    mask(rest, [spaces_keep_nl(<<"\\", char::utf8>>) | acc], context)
  end

  defp scan_token(<<?\\, char, rest::binary>>, acc, %{state: :string} = context) do
    mask(rest, [spaces_keep_nl(<<"\\", char>>) | acc], context)
  end

  defp scan_token(
         <<"${", rest::binary>>,
         acc,
         %{state: :string, quote: ?`, templates: [frame | templates]} = context
       ) do
    grammar =
      Map.take(context, [:body, :keywords, :parens, :braces, :for_headers, :statement_header])

    mask(rest, ["${" | acc], %{
      code_context(context, true)
      | state: :code,
        quote: nil,
        interpolation_depth: 1,
        templates: [%{frame | grammar: grammar} | templates],
        string_start: nil
    })
  end

  defp scan_token(
         <<?`, rest::binary>>,
         acc,
         %{state: :string, quote: ?`, templates: [frame | templates]} = context
       ) do
    context = close_string(context, context.size - byte_size(rest) - 1)

    mask(rest, ["`" | acc], %{
      code_context(context, false)
      | state: :code,
        quote: nil,
        interpolation_depth: frame.depth,
        templates: templates
    })
  end

  defp scan_token(<<quote, rest::binary>>, acc, %{state: :string, quote: quote} = context) do
    context = close_string(context, context.size - byte_size(rest) - 1)

    mask(rest, [<<quote>> | acc], %{code_context(context, false) | state: :code, quote: nil})
  end

  defp scan_token(<<char::utf8, rest::binary>>, acc, %{state: :string} = context) do
    mask(rest, [spaces_keep_nl(<<char::utf8>>) | acc], context)
  end

  defp scan_token(<<char, rest::binary>>, acc, %{state: :string} = context) do
    mask(rest, [spaces_keep_nl(<<char>>) | acc], context)
  end

  defp scan_token(<<char::utf8, rest::binary>> = source, acc, %{state: :code} = context) do
    case Identifier.take(source) do
      {:ok, raw, name, rest} ->
        keyword? = raw == name and not context.body.property?

        masked =
          if keyword? and name in @specifier_keywords,
            do: raw,
            else: :binary.copy("_", byte_size(raw))

        mask(rest, [masked | acc], word_context(context, raw, keyword?, rest))

      :none ->
        mask(rest, [<<char::utf8>> | acc], context)
    end
  end

  defp scan_token(<<char, rest::binary>>, acc, context) do
    mask(rest, [<<char>> | acc], context)
  end

  defp mask_number(source, acc, context) do
    [{0, length}] = Regex.run(@number, source, return: :index)
    raw = binary_part(source, 0, length)
    rest = binary_part(source, length, byte_size(source) - length)
    keywords = ContextualKeywords.literal_key(context.keywords, context.body.depth)
    mask(rest, [raw | acc], %{code_context(context, false) | keywords: keywords})
  end

  defp code_context(context, regex_allowed?, block_allowed? \\ false) do
    %{
      context
      | regex_allowed?: regex_allowed?,
        block_allowed?: block_allowed?,
        body: BodyContext.reset(context.body),
        statement_header: nil
    }
  end

  defp line_break_context(context) do
    %{
      context
      | body: BodyContext.line_break(context.body, not context.regex_allowed?),
        keywords: ContextualKeywords.line_break(context.keywords, context.body.depth)
    }
  end

  defp comment_context(context, text) do
    if :binary.match(text, @line_terminators) == :nomatch,
      do: context,
      else: line_break_context(context)
  end

  defp word_context(context, word, keyword?, rest) do
    # `for await (` keeps the for-statement header.
    statement_header =
      cond do
        keyword? and word in @statement_heads -> word
        keyword? and context.statement_header == "for" and word == "await" -> "for"
        true -> nil
      end

    {for_of?, for_headers} =
      ForHeader.word(
        context.for_headers,
        context.body.depth,
        word,
        keyword? and not context.regex_allowed?,
        context.body.last_word
      )

    body = BodyContext.word(context.body, word, context.block_allowed?)

    keywords =
      ContextualKeywords.word(
        context.keywords,
        word,
        context.body.depth,
        not keyword?,
        if(context.body.line_boundary?, do: nil, else: context.body.last_word),
        rest
      )

    %{
      context
      | regex_allowed?:
          keyword? and ContextualKeywords.keyword?(keywords, word) and
            (word in @regex_prefix_keywords or for_of?),
        block_allowed?: keyword? and word in @block_heads,
        body: body,
        keywords: keywords,
        statement_header: statement_header,
        for_headers: for_headers
    }
  end

  defp split_line(rest) do
    case :binary.match(rest, @line_terminators) do
      {index, length} ->
        taken = index + length
        {binary_part(rest, 0, taken), binary_part(rest, taken, byte_size(rest) - taken)}

      :nomatch ->
        {rest, <<>>}
    end
  end

  defp split_block(rest) do
    case :binary.match(rest, "*/") do
      {index, _} ->
        taken = index + 2
        {binary_part(rest, 0, taken), binary_part(rest, taken, byte_size(rest) - taken)}

      :nomatch ->
        {rest, <<>>}
    end
  end

  defp take_regex(<<char::utf8, _rest::binary>>, _n, _class)
       when char in [?\n, ?\r, 0x2028, 0x2029],
       do: :no

  defp take_regex(<<>>, _n, _class), do: :no

  defp take_regex(<<?\\, _char, rest::binary>>, n, class) do
    take_regex(rest, n + 2, class)
  end

  defp take_regex(<<?\\>>, _n, _class), do: :no
  defp take_regex(<<?], rest::binary>>, n, true), do: take_regex(rest, n + 1, false)
  defp take_regex(<<?[, rest::binary>>, n, false), do: take_regex(rest, n + 1, true)
  defp take_regex(<<?/, rest::binary>>, n, false), do: {:ok, n, rest}
  defp take_regex(<<_char, rest::binary>>, n, class), do: take_regex(rest, n + 1, class)

  defp spaces(n) when n > 0, do: :binary.copy(<<?\s>>, n)
  defp spaces(_n), do: <<>>

  defp spaces_keep_nl(binary), do: spaces_keep_nl(binary, [])

  defp spaces_keep_nl(<<char::utf8, rest::binary>>, acc) when char in [0x2028, 0x2029] do
    spaces_keep_nl(rest, ["\n  " | acc])
  end

  defp spaces_keep_nl(<<byte, rest::binary>>, acc) do
    masked = if byte in [?\n, ?\r], do: <<byte>>, else: " "
    spaces_keep_nl(rest, [masked | acc])
  end

  defp spaces_keep_nl(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp close_string(context, stop) do
    if context.string_start do
      %{context | strings: [{context.string_start, stop} | context.strings], string_start: nil}
    else
      context
    end
  end
end
