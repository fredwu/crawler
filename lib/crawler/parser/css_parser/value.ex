defmodule Crawler.Parser.CssParser.Value do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.Parser.CssParser.Buffer
  alias Crawler.Parser.CssParser.Identifier

  @entity_quote ~r/^&(?:quot|apos|#0*(?:34|39)|#x0*(?:22|27));/i
  @double_quote ~r/^&(?:quot|#0*34|#x0*22);$/i

  defguardp non_printable(byte) when byte in 0..8 or byte == 11 or byte in 14..31 or byte == 127

  def quote_info(<<char, _rest::binary>>) when char in [?", ?'], do: {char, 1, <<char>>}
  def quote_info(_body), do: nil

  def source_quote(<<char, _rest::binary>>) when char in [?", ?'], do: <<char>>

  def source_quote(body) do
    case Regex.run(@entity_quote, body) do
      [entity] ->
        char = if Regex.match?(@double_quote, entity), do: ?", else: ?'
        normalized_quote(entity, char)

      nil ->
        ""
    end
  end

  def quoted(body, offset) do
    {token, tail, finish, valid?, _budget} = quoted(body, offset, Budget.unlimited())
    {token, tail, finish, valid?}
  end

  def quoted(body, offset, budget) do
    budget = token_budget(budget)
    {char, length, normalized} = quote_info(body)
    {value, tail, closed?, budget} = string(drop(body, length), char, Buffer.new(budget))
    consumed = byte_size(body) - byte_size(tail)
    token = Map.put(token(offset, consumed, value, normalized), :closed?, closed?)
    {token, tail, offset + consumed, closed? or tail == "", budget}
  end

  def bare(body, offset) do
    {token, tail, finish, _budget} = bare(body, offset, Budget.unlimited())
    {token, tail, finish}
  end

  def bare(body, offset, budget) do
    budget = token_budget(budget)
    {value, tail, _valid?, budget} = unquoted(body, :candidate, Buffer.new(budget))
    consumed = byte_size(body) - byte_size(tail)
    {token(offset, consumed, value, ""), tail, offset + consumed, budget}
  end

  def url(body, offset) do
    {token, tail, finish, comments, _budget} = url(body, offset, Budget.unlimited())
    {token, tail, finish, comments}
  end

  def url(body, offset, budget, comments \\ []) do
    {body, offset} = whitespace(body, offset)
    quoted? = quote_info(body) != nil

    {token, tail, finish, valid?, budget} =
      if quoted? do
        quoted(body, offset, budget)
      else
        budget = token_budget(budget)
        {value, tail, valid?, budget} = unquoted(body, :url, Buffer.new(budget))
        length = byte_size(body) - byte_size(tail)
        {token(offset, length, value, ""), tail, offset + length, valid?, budget}
      end

    complete_url(token, tail, finish, valid?, quoted?, comments, budget)
  end

  defp complete_url(token, tail, finish, true, quoted?, comments, budget) do
    {tail, finish, comments, budget} =
      if quoted? do
        trivia(tail, finish, budget, comments)
      else
        {tail, finish} = whitespace(tail, finish)
        {tail, finish, comments, budget}
      end

    case tail do
      <<")", rest::binary>> ->
        {token, rest, finish + 1, comments, budget}

      "" ->
        {token, "", finish, comments, budget}

      _ ->
        discard_url(tail, finish, comments, budget)
    end
  end

  defp complete_url(_token, tail, finish, false, _quoted?, comments, budget),
    do: discard_url(tail, finish, comments, budget)

  defp discard_url(tail, finish, comments, budget) do
    bytes = Budget.cost(:frame, 2)
    budget = take!(Budget.reserve(budget, bytes))
    rest = bad_url(tail)
    budget = take!(Budget.release(budget, bytes))
    {nil, rest, finish + byte_size(tail) - byte_size(rest), comments, budget}
  end

  def trivia(body, offset) do
    {tail, finish, comments, _budget} = trivia(body, offset, Budget.unlimited())
    {tail, finish, comments}
  end

  def trivia(body, offset, budget, comments \\ [])

  def trivia(<<"/*", rest::binary>>, offset, budget, comments) do
    budget =
      take!(Budget.charge(budget, Budget.cost(:segment) + Budget.cost(:list_cell), facts: 1))

    length = comment_length(rest) + 2
    trivia(drop(rest, length - 2), offset + length, budget, [{offset, length} | comments])
  end

  def trivia(<<byte, rest::binary>>, offset, budget, comments)
      when byte in [?\s, ?\t, ?\n, ?\r, ?\f] do
    trivia(rest, offset + 1, budget, comments)
  end

  def trivia(body, offset, budget, comments), do: {body, offset, comments, budget}

  defp whitespace(<<byte, rest::binary>>, offset) when byte in [?\s, ?\t, ?\n, ?\r, ?\f] do
    whitespace(rest, offset + 1)
  end

  defp whitespace(body, offset), do: {body, offset}

  defp string(<<>>, _quote, buffer), do: finish(buffer, "", false)
  defp string(<<"\\">>, _quote, buffer), do: finish(buffer, "", false)

  defp string(<<"\\\r\n", rest::binary>>, quote, buffer), do: string(rest, quote, buffer)

  defp string(<<"\\", byte, rest::binary>>, quote, buffer) when byte in [?\n, ?\r, ?\f] do
    string(rest, quote, buffer)
  end

  defp string(<<"\\", _rest::binary>> = body, quote, buffer) do
    {buffer, rest} = Buffer.escaped(buffer, body)
    string(rest, quote, buffer)
  end

  defp string(<<byte, _rest::binary>> = body, _quote, buffer) when byte in [?\n, ?\r, ?\f],
    do: finish(buffer, body, false)

  defp string(body, expected, buffer) do
    case quote_info(body) do
      {^expected, length, _normalized} ->
        finish(buffer, drop(body, length), true)

      _ ->
        <<byte, rest::binary>> = body
        string(rest, expected, Buffer.push(buffer, byte))
    end
  end

  defp unquoted(<<>>, _kind, buffer), do: finish(buffer, "", true)
  defp unquoted(<<"\\">>, :url, buffer), do: finish(Buffer.replacement(buffer), "", true)

  defp unquoted(<<"\\", byte, _rest::binary>> = body, :url, buffer)
       when byte in [?\n, ?\r, ?\f],
       do: finish(buffer, body, false)

  defp unquoted(<<byte, _rest::binary>> = body, :url, buffer)
       when byte in [?", ?', ?(] or non_printable(byte),
       do: finish(buffer, body, false)

  defp unquoted(<<"\\", _rest::binary>> = body, kind, buffer) do
    {buffer, rest} = Buffer.escaped(buffer, body)
    unquoted(rest, kind, buffer)
  end

  defp unquoted(<<byte, _rest::binary>> = body, _kind, buffer)
       when byte in [?\s, ?\t, ?\n, ?\r, ?\f, ?)],
       do: finish(buffer, body, true)

  defp unquoted(<<byte, _rest::binary>> = body, :candidate, buffer) when byte in [?\,, ?(],
    do: finish(buffer, body, true)

  defp unquoted(<<byte, rest::binary>>, kind, buffer),
    do: unquoted(rest, kind, Buffer.push(buffer, byte))

  defp bad_url(<<>>), do: ""
  defp bad_url(<<")", rest::binary>>), do: rest

  defp bad_url(<<"\\", byte, rest::binary>>) when byte in [?\n, ?\r, ?\f],
    do: bad_url(rest)

  defp bad_url(<<"\\", _rest::binary>> = body) do
    {_decoded, rest} = Identifier.decode_escape(body)
    bad_url(rest)
  end

  defp bad_url(<<_byte, rest::binary>>), do: bad_url(rest)

  defp token(start, length, value, quote) do
    %{start: start, length: length, value: value, quote: quote}
  end

  defp normalized_quote(entity, char) do
    cond do
      String.contains?(String.downcase(entity), "#x") ->
        if char == ?", do: "&#x22;", else: "&#x27;"

      String.contains?(entity, "#") ->
        if char == ?", do: "&#34;", else: "&#39;"

      true ->
        entity
    end
  end

  defp comment_length(body) do
    case :binary.match(body, "*/") do
      {start, length} -> start + length
      :nomatch -> byte_size(body)
    end
  end

  defp finish(buffer, tail, valid?) do
    {value, budget} = Buffer.finish(buffer)
    {value, tail, valid?, budget}
  end

  defp token_budget(budget), do: take!(Budget.charge(budget, Budget.cost(:token), facts: 1))
  defp take!({:ok, budget}), do: budget
  defp take!({:error, reason}), do: throw({:css_budget, reason})
  defp drop(body, length), do: binary_part(body, length, byte_size(body) - length)
end
