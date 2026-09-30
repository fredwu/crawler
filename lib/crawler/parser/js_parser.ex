defmodule Crawler.Parser.JsParser do
  @moduledoc """
  Finds static JavaScript module specifiers.
  """

  # A specifier statement may start after a newline, a semicolon, or `}`.
  # A quote cannot, so the match does not enter a string.
  @from ~r/(?:^|[\n;}])\s*(?:import|export)\b[^'";]*?\bfrom\s*(["'`])([^"'`]+)\1/
  @side_effect ~r/(?:^|[\n;}])\s*import\s*(["'`])([^"'`]+)\1/
  # A property call such as `obj.import("./x")` is not the import keyword.
  # The argument must end the call or start the options object. `+` does not.
  @dynamic ~r/(?<!\.)\bimport\s*\(\s*(["'`])([^"'`]+)\1\s*[,)]/

  @before_regex ~w(
    await case delete do else export in instanceof new return throw typeof void yield of
  )
  @stmt_head ~w(if while for with switch catch)

  def elements(body) when is_binary(body) do
    Enum.map(specs(body), &{"link", [{"href", &1}], []})
  end

  def elements(_body), do: []

  def specs(body) when is_binary(body) do
    body
    |> spans()
    |> Enum.map(fn {_at, _len, spec} -> spec end)
    |> Enum.uniq()
  end

  def specs(_body), do: []

  @doc false
  def spans(body) when is_binary(body) do
    masked = mask_noise(body)
    ranges = string_ranges(masked)

    [@from, @side_effect, @dynamic]
    |> Enum.flat_map(&span_matches(&1, body, masked, ranges))
    |> Enum.filter(fn {_at, _len, spec} -> local?(spec) end)
  end

  def spans(_body), do: []

  defp span_matches(regex, original, masked, ranges) do
    regex
    |> Regex.scan(masked, return: :index)
    |> Enum.flat_map(fn [{at, len}, _quote, {spec_at, spec_len}] ->
      if keyword_in_code?(masked, at, len, ranges) and not property_import?(masked, at, len) do
        [{spec_at, spec_len, binary_part(original, spec_at, spec_len)}]
      else
        []
      end
    end)
  end

  # `obj. import("./x")` and `obj./* c */import("./x")` are property calls.
  # Comments are spaces here, so skip those spaces before checking for `.`.
  defp property_import?(source, at, len) do
    case :binary.match(binary_part(source, at, len), "import") do
      {index, _length} -> previous_non_space(source, at + index) == ?.
      :nomatch -> false
    end
  end

  defp previous_non_space(_source, index) when index <= 0, do: nil

  defp previous_non_space(source, index) do
    case :binary.at(source, index - 1) do
      byte when byte in [?\s, ?\t, ?\n, ?\r, ?\f] -> previous_non_space(source, index - 1)
      byte -> byte
    end
  end

  # The specifier itself is a string. Reject the match only when the
  # import or export keyword is inside one.
  defp keyword_in_code?(source, at, len, ranges) do
    key_at =
      case :binary.match(binary_part(source, at, len), ["import", "export"]) do
        {index, _length} -> at + index
        :nomatch -> at
      end

    not inside_string?(ranges, key_at)
  end

  defp inside_string?(ranges, index) do
    Enum.any?(ranges, fn {start, stop} -> index >= start and index < stop end)
  end

  defp string_ranges(source) do
    source
    |> ranges(0, %{state: :code, quote: nil, start: nil, acc: [], templates: [], interp: 0})
    |> Enum.reverse()
  end

  defp ranges(<<>>, index, %{state: :string, start: start, acc: acc}) do
    [{start, index} | acc]
  end

  defp ranges(<<>>, _index, %{acc: acc}), do: acc

  defp ranges(
         <<?`, rest::binary>>,
         index,
         %{state: :code, interp: interp, templates: templates} = ctx
       ) do
    ranges(rest, index + 1, %{
      ctx
      | state: :string,
        quote: ?`,
        start: index + 1,
        interp: 0,
        templates: [{?`, interp} | templates]
    })
  end

  defp ranges(<<quote, rest::binary>>, index, %{state: :code} = ctx) when quote in [?", ?'] do
    ranges(rest, index + 1, %{ctx | state: :string, quote: quote, start: index + 1})
  end

  defp ranges(<<?\\, char::utf8, rest::binary>>, index, %{state: :string} = ctx) do
    ranges(rest, index + 1 + byte_size(<<char::utf8>>), ctx)
  end

  defp ranges(<<?\\, _char, rest::binary>>, index, %{state: :string} = ctx) do
    ranges(rest, index + 2, ctx)
  end

  defp ranges(
         <<"${", rest::binary>>,
         index,
         %{state: :string, quote: ?`, start: start, acc: acc} = ctx
       ) do
    ranges(rest, index + 2, %{
      ctx
      | state: :code,
        quote: nil,
        start: nil,
        interp: 1,
        acc: [{start, index} | acc]
    })
  end

  defp ranges(
         <<?`, rest::binary>>,
         index,
         %{
           state: :string,
           quote: ?`,
           start: start,
           acc: acc,
           templates: [{?`, saved} | templates]
         } = ctx
       ) do
    ranges(rest, index + 1, %{
      ctx
      | state: :code,
        quote: nil,
        start: nil,
        interp: saved,
        templates: templates,
        acc: [{start, index} | acc]
    })
  end

  defp ranges(
         <<quote, rest::binary>>,
         index,
         %{state: :string, quote: quote, start: start, acc: acc} = ctx
       ) do
    ranges(rest, index + 1, %{
      ctx
      | state: :code,
        quote: nil,
        start: nil,
        acc: [{start, index} | acc]
    })
  end

  defp ranges(<<?{, rest::binary>>, index, %{state: :code, interp: interp} = ctx)
       when interp > 0 do
    ranges(rest, index + 1, %{ctx | interp: interp + 1})
  end

  defp ranges(
         <<?}, rest::binary>>,
         index,
         %{state: :code, interp: 1, templates: [{quote, _} | _]} = ctx
       ) do
    ranges(rest, index + 1, %{ctx | state: :string, quote: quote, start: index + 1, interp: 0})
  end

  defp ranges(<<?}, rest::binary>>, index, %{state: :code, interp: interp} = ctx)
       when interp > 1 do
    ranges(rest, index + 1, %{ctx | interp: interp - 1})
  end

  defp ranges(<<char::utf8, rest::binary>>, index, ctx) do
    ranges(rest, index + byte_size(<<char::utf8>>), ctx)
  end

  defp ranges(<<_char, rest::binary>>, index, ctx) do
    ranges(rest, index + 1, ctx)
  end

  defp local?(spec) do
    scheme = String.downcase(spec)

    not String.contains?(spec, "${") and
      (String.starts_with?(spec, ".") or
         String.starts_with?(spec, "/") or
         String.starts_with?(scheme, "http://") or
         String.starts_with?(scheme, "https://") or
         String.starts_with?(spec, "//"))
  end

  # Comments and regex literals become spaces of the same length, with
  # newlines kept, so later matches use original byte indexes. Strings stay,
  # because a specifier is a string.
  defp mask_noise(source) do
    mask(source, [], %{
      state: :code,
      quote: nil,
      ok: true,
      parens: [],
      templates: [],
      interp: 0,
      expect: false
    })
  end

  defp mask(<<>>, acc, _ctx), do: IO.iodata_to_binary(Enum.reverse(acc))

  defp mask(<<char, rest::binary>>, acc, %{state: :code} = ctx)
       when char in [?\s, ?\t, ?\r, ?\n, ?\f] do
    mask(rest, [<<char>> | acc], ctx)
  end

  defp mask(<<"//", rest::binary>>, acc, %{state: :code} = ctx) do
    {line, rest} = split_line(rest)
    mask(rest, [spaces_keep_nl("//" <> line) | acc], ctx)
  end

  defp mask(<<"/*", rest::binary>>, acc, %{state: :code} = ctx) do
    {block, rest} = split_block(rest)
    mask(rest, [spaces_keep_nl("/*" <> block) | acc], ctx)
  end

  defp mask(<<?/, rest::binary>>, acc, %{state: :code, ok: true} = ctx) do
    case take_regex(rest, 0, false) do
      {:ok, n, rest} -> mask(rest, [spaces(n + 2) | acc], %{ctx | ok: false, expect: false})
      :no -> mask(rest, ["/" | acc], %{ctx | ok: true, expect: false})
    end
  end

  defp mask(<<?/, rest::binary>>, acc, %{state: :code} = ctx) do
    mask(rest, ["/" | acc], %{ctx | ok: true, expect: false})
  end

  defp mask(
         <<?`, rest::binary>>,
         acc,
         %{state: :code, interp: interp, templates: templates} = ctx
       ) do
    mask(rest, ["`" | acc], %{
      ctx
      | state: :string,
        quote: ?`,
        ok: false,
        expect: false,
        interp: 0,
        templates: [{?`, interp} | templates]
    })
  end

  defp mask(<<quote, rest::binary>>, acc, %{state: :code} = ctx) when quote in [?", ?'] do
    mask(rest, [<<quote>> | acc], %{ctx | state: :string, quote: quote, ok: false, expect: false})
  end

  defp mask(<<"...", rest::binary>>, acc, %{state: :code} = ctx) do
    mask(rest, ["..." | acc], %{ctx | ok: true, expect: false})
  end

  defp mask(<<?., rest::binary>>, acc, %{state: :code} = ctx) do
    mask(rest, ["." | acc], %{ctx | ok: false, expect: false})
  end

  defp mask(<<char, rest::binary>>, acc, %{state: :code} = ctx)
       when char in ?A..?Z or char in ?a..?z or char == ?_ or char == ?$ do
    {word, rest} = take_word(rest, <<char>>)
    # `for await (` is still the for-statement header. `await` must not clear it.
    expect = word in @stmt_head or (ctx.expect and word == "await")
    mask(rest, [word | acc], %{ctx | ok: word in @before_regex, expect: expect})
  end

  defp mask(<<char, rest::binary>>, acc, %{state: :code} = ctx) when char in ?0..?9 do
    mask(rest, [<<char>> | acc], %{ctx | ok: false, expect: false})
  end

  defp mask(<<?(, rest::binary>>, acc, %{state: :code, expect: true, parens: parens} = ctx) do
    mask(rest, ["(" | acc], %{ctx | ok: true, expect: false, parens: [:stmt | parens]})
  end

  defp mask(<<?(, rest::binary>>, acc, %{state: :code, parens: parens} = ctx) do
    mask(rest, ["(" | acc], %{ctx | ok: true, expect: false, parens: [:expr | parens]})
  end

  defp mask(<<?), rest::binary>>, acc, %{state: :code, parens: [:stmt | parens]} = ctx) do
    mask(rest, [")" | acc], %{ctx | ok: true, expect: false, parens: parens})
  end

  defp mask(<<?), rest::binary>>, acc, %{state: :code, parens: [:expr | parens]} = ctx) do
    mask(rest, [")" | acc], %{ctx | ok: false, expect: false, parens: parens})
  end

  defp mask(<<?), rest::binary>>, acc, %{state: :code} = ctx) do
    mask(rest, [")" | acc], %{ctx | ok: false, expect: false})
  end

  defp mask(<<?{, rest::binary>>, acc, %{state: :code, interp: interp} = ctx) when interp > 0 do
    mask(rest, ["{" | acc], %{ctx | ok: true, expect: false, interp: interp + 1})
  end

  defp mask(
         <<?}, rest::binary>>,
         acc,
         %{state: :code, interp: 1, templates: [{quote, _} | _]} = ctx
       ) do
    mask(rest, ["}" | acc], %{
      ctx
      | state: :string,
        quote: quote,
        ok: false,
        expect: false,
        interp: 0
    })
  end

  defp mask(<<?}, rest::binary>>, acc, %{state: :code, interp: interp} = ctx) when interp > 1 do
    mask(rest, ["}" | acc], %{ctx | ok: true, expect: false, interp: interp - 1})
  end

  defp mask(<<?], rest::binary>>, acc, %{state: :code} = ctx) do
    mask(rest, ["]" | acc], %{ctx | ok: false, expect: false})
  end

  defp mask(<<char, rest::binary>>, acc, %{state: :code} = ctx)
       when char in [?[, ?{, ?}, ?=, ?,, ?:, ?;, ?!, ?&, ?|, ??, ?~, ?^, ?%, ?*, ?+, ?-, ?<, ?>] do
    mask(rest, [<<char>> | acc], %{ctx | ok: true, expect: false})
  end

  defp mask(<<?\\, char::utf8, rest::binary>>, acc, %{state: :string} = ctx) do
    mask(rest, [<<char::utf8>>, "\\" | acc], ctx)
  end

  defp mask(<<?\\, char, rest::binary>>, acc, %{state: :string} = ctx) do
    mask(rest, [<<char>>, "\\" | acc], ctx)
  end

  defp mask(<<"${", rest::binary>>, acc, %{state: :string, quote: ?`} = ctx) do
    mask(rest, ["${" | acc], %{ctx | state: :code, quote: nil, ok: true, expect: false, interp: 1})
  end

  defp mask(
         <<?`, rest::binary>>,
         acc,
         %{state: :string, quote: ?`, templates: [{?`, saved} | templates]} = ctx
       ) do
    mask(rest, ["`" | acc], %{
      ctx
      | state: :code,
        quote: nil,
        ok: false,
        expect: false,
        interp: saved,
        templates: templates
    })
  end

  defp mask(<<quote, rest::binary>>, acc, %{state: :string, quote: quote} = ctx) do
    mask(rest, [<<quote>> | acc], %{ctx | state: :code, quote: nil, ok: false, expect: false})
  end

  defp mask(<<char::utf8, rest::binary>>, acc, ctx) do
    mask(rest, [<<char::utf8>> | acc], ctx)
  end

  defp mask(<<char, rest::binary>>, acc, ctx) do
    mask(rest, [<<char>> | acc], ctx)
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
end
