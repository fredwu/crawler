defmodule Crawler.Parser.JsParser.Scanner do
  @moduledoc false

  @regex_prefix_keywords ~w(
    await case delete do else export in instanceof new return throw typeof void yield of
  )
  @statement_heads ~w(if while for with switch catch)

  # Comments and regex literals become spaces of the same length, with
  # newlines kept, so later matches use original byte indexes. Strings stay,
  # because a specifier is a string.
  def scan(source) do
    mask(source, [], %{
      state: :code,
      quote: nil,
      regex_allowed?: true,
      parens: [],
      templates: [],
      interpolation_depth: 0,
      statement_header?: false,
      size: byte_size(source),
      string_start: nil,
      strings: []
    })
  end

  defp mask(<<>>, acc, context) do
    context = if context.state == :string, do: close_string(context, context.size), else: context
    {IO.iodata_to_binary(Enum.reverse(acc)), Enum.reverse(context.strings)}
  end

  defp mask(<<char, rest::binary>>, acc, %{state: :code} = context)
       when char in [?\s, ?\t, ?\r, ?\n, ?\f] do
    mask(rest, [<<char>> | acc], context)
  end

  defp mask(<<"//", rest::binary>>, acc, %{state: :code} = context) do
    {line, rest} = split_line(rest)
    mask(rest, [spaces_keep_nl("//" <> line) | acc], context)
  end

  defp mask(<<"/*", rest::binary>>, acc, %{state: :code} = context) do
    {block, rest} = split_block(rest)
    mask(rest, [spaces_keep_nl("/*" <> block) | acc], context)
  end

  defp mask(<<?/, rest::binary>>, acc, %{state: :code, regex_allowed?: true} = context) do
    case take_regex(rest, 0, false) do
      {:ok, n, rest} ->
        mask(rest, [spaces(n + 2) | acc], %{
          context
          | regex_allowed?: false,
            statement_header?: false
        })

      :no ->
        mask(rest, ["/" | acc], %{context | regex_allowed?: true, statement_header?: false})
    end
  end

  defp mask(<<?/, rest::binary>>, acc, %{state: :code} = context) do
    mask(rest, ["/" | acc], %{context | regex_allowed?: true, statement_header?: false})
  end

  defp mask(
         <<?`, rest::binary>>,
         acc,
         %{state: :code, interpolation_depth: interpolation_depth, templates: templates} = context
       ) do
    mask(rest, ["`" | acc], %{
      context
      | state: :string,
        quote: ?`,
        regex_allowed?: false,
        statement_header?: false,
        interpolation_depth: 0,
        templates: [{?`, interpolation_depth} | templates],
        string_start: context.size - byte_size(rest)
    })
  end

  defp mask(<<quote, rest::binary>>, acc, %{state: :code} = context) when quote in [?", ?'] do
    mask(rest, [<<quote>> | acc], %{
      context
      | state: :string,
        quote: quote,
        regex_allowed?: false,
        statement_header?: false,
        string_start: context.size - byte_size(rest)
    })
  end

  defp mask(<<"...", rest::binary>>, acc, %{state: :code} = context) do
    mask(rest, ["..." | acc], %{context | regex_allowed?: true, statement_header?: false})
  end

  defp mask(<<?., rest::binary>>, acc, %{state: :code} = context) do
    mask(rest, ["." | acc], %{context | regex_allowed?: false, statement_header?: false})
  end

  defp mask(<<char, rest::binary>>, acc, %{state: :code} = context)
       when char in ?A..?Z or char in ?a..?z or char == ?_ or char == ?$ do
    {word, rest} = take_word(rest, <<char>>)
    # `for await (` is still the for-statement header. `await` must not clear it.
    statement_header? =
      word in @statement_heads or (context.statement_header? and word == "await")

    mask(rest, [word | acc], %{
      context
      | regex_allowed?: word in @regex_prefix_keywords,
        statement_header?: statement_header?
    })
  end

  defp mask(<<char, rest::binary>>, acc, %{state: :code} = context) when char in ?0..?9 do
    mask(rest, [<<char>> | acc], %{context | regex_allowed?: false, statement_header?: false})
  end

  defp mask(
         <<?(, rest::binary>>,
         acc,
         %{state: :code, statement_header?: true, parens: parens} = context
       ) do
    mask(rest, ["(" | acc], %{
      context
      | regex_allowed?: true,
        statement_header?: false,
        parens: [:stmt | parens]
    })
  end

  defp mask(<<?(, rest::binary>>, acc, %{state: :code, parens: parens} = context) do
    mask(rest, ["(" | acc], %{
      context
      | regex_allowed?: true,
        statement_header?: false,
        parens: [:expr | parens]
    })
  end

  defp mask(<<?), rest::binary>>, acc, %{state: :code, parens: [:stmt | parens]} = context) do
    mask(rest, [")" | acc], %{
      context
      | regex_allowed?: true,
        statement_header?: false,
        parens: parens
    })
  end

  defp mask(<<?), rest::binary>>, acc, %{state: :code, parens: [:expr | parens]} = context) do
    mask(rest, [")" | acc], %{
      context
      | regex_allowed?: false,
        statement_header?: false,
        parens: parens
    })
  end

  defp mask(<<?), rest::binary>>, acc, %{state: :code} = context) do
    mask(rest, [")" | acc], %{context | regex_allowed?: false, statement_header?: false})
  end

  defp mask(
         <<?{, rest::binary>>,
         acc,
         %{state: :code, interpolation_depth: interpolation_depth} = context
       )
       when interpolation_depth > 0 do
    mask(rest, ["{" | acc], %{
      context
      | regex_allowed?: true,
        statement_header?: false,
        interpolation_depth: interpolation_depth + 1
    })
  end

  defp mask(
         <<?}, rest::binary>>,
         acc,
         %{state: :code, interpolation_depth: 1, templates: [{quote, _} | _]} = context
       ) do
    mask(rest, ["}" | acc], %{
      context
      | state: :string,
        quote: quote,
        regex_allowed?: false,
        statement_header?: false,
        interpolation_depth: 0,
        string_start: context.size - byte_size(rest)
    })
  end

  defp mask(
         <<?}, rest::binary>>,
         acc,
         %{state: :code, interpolation_depth: interpolation_depth} = context
       )
       when interpolation_depth > 1 do
    mask(rest, ["}" | acc], %{
      context
      | regex_allowed?: true,
        statement_header?: false,
        interpolation_depth: interpolation_depth - 1
    })
  end

  defp mask(<<?], rest::binary>>, acc, %{state: :code} = context) do
    mask(rest, ["]" | acc], %{context | regex_allowed?: false, statement_header?: false})
  end

  defp mask(<<operator::binary-size(2), rest::binary>>, acc, %{state: :code} = context)
       when operator in ["++", "--"] do
    mask(rest, [operator | acc], %{context | statement_header?: false})
  end

  defp mask(<<char, rest::binary>>, acc, %{state: :code} = context)
       when char in [?[, ?{, ?}, ?=, ?,, ?:, ?;, ?!, ?&, ?|, ??, ?~, ?^, ?%, ?*, ?+, ?-, ?<, ?>] do
    mask(rest, [<<char>> | acc], %{context | regex_allowed?: true, statement_header?: false})
  end

  defp mask(<<?\\, char::utf8, rest::binary>>, acc, %{state: :string} = context) do
    mask(rest, [<<char::utf8>>, "\\" | acc], context)
  end

  defp mask(<<?\\, char, rest::binary>>, acc, %{state: :string} = context) do
    mask(rest, [<<char>>, "\\" | acc], context)
  end

  defp mask(<<"${", rest::binary>>, acc, %{state: :string, quote: ?`} = context) do
    context = close_string(context, context.size - byte_size(rest) - 2)

    mask(rest, ["${" | acc], %{
      context
      | state: :code,
        quote: nil,
        regex_allowed?: true,
        statement_header?: false,
        interpolation_depth: 1
    })
  end

  defp mask(
         <<?`, rest::binary>>,
         acc,
         %{state: :string, quote: ?`, templates: [{?`, saved} | templates]} = context
       ) do
    context = close_string(context, context.size - byte_size(rest) - 1)

    mask(rest, ["`" | acc], %{
      context
      | state: :code,
        quote: nil,
        regex_allowed?: false,
        statement_header?: false,
        interpolation_depth: saved,
        templates: templates
    })
  end

  defp mask(<<quote, rest::binary>>, acc, %{state: :string, quote: quote} = context) do
    context = close_string(context, context.size - byte_size(rest) - 1)

    mask(rest, [<<quote>> | acc], %{
      context
      | state: :code,
        quote: nil,
        regex_allowed?: false,
        statement_header?: false
    })
  end

  defp mask(<<char::utf8, rest::binary>>, acc, context) do
    mask(rest, [<<char::utf8>> | acc], context)
  end

  defp mask(<<char, rest::binary>>, acc, context) do
    mask(rest, [<<char>> | acc], context)
  end

  defp take_word(<<char, rest::binary>>, acc)
       when char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char == ?_ or char == ?$ do
    take_word(rest, acc <> <<char>>)
  end

  defp take_word(rest, acc), do: {acc, rest}

  defp split_line(rest) do
    case :binary.match(rest, "\n") do
      {index, _} ->
        taken = index + 1
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

  defp take_regex(<<"\n", _rest::binary>>, _n, _class), do: :no
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

  defp spaces_keep_nl(binary) do
    for <<byte <- binary>>, into: <<>> do
      if byte == ?\n, do: <<?\n>>, else: <<?\s>>
    end
  end

  defp close_string(context, stop) do
    %{context | strings: [{context.string_start, stop} | context.strings], string_start: nil}
  end
end
