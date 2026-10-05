defmodule Crawler.Parser.CssParser.Value do
  @moduledoc false

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
    {char, length, normalized} = quote_info(body)
    {value, tail, closed?} = string(drop(body, length), char, [])
    consumed = byte_size(body) - byte_size(tail)
    token = Map.put(token(offset, consumed, value, normalized), :closed?, closed?)
    {token, tail, offset + consumed, closed? or tail == ""}
  end

  def bare(body, offset) do
    {value, tail, _valid?} = unquoted(body, :candidate, [])
    consumed = byte_size(body) - byte_size(tail)
    {token(offset, consumed, value, ""), tail, offset + consumed}
  end

  def url(body, offset) do
    {body, offset} = whitespace(body, offset)
    quoted? = quote_info(body) != nil

    {token, tail, finish, valid?} =
      if quoted? do
        quoted(body, offset)
      else
        {value, tail, valid?} = unquoted(body, :url, [])
        length = byte_size(body) - byte_size(tail)
        {token(offset, length, value, ""), tail, offset + length, valid?}
      end

    complete_url(token, tail, finish, valid?, quoted?)
  end

  defp complete_url(token, tail, finish, true, quoted?) do
    {tail, finish, comments} =
      if quoted? do
        trivia(tail, finish)
      else
        {tail, finish} = whitespace(tail, finish)
        {tail, finish, []}
      end

    case tail do
      <<")", rest::binary>> ->
        {token, rest, finish + 1, comments}

      "" ->
        {token, "", finish, comments}

      _ ->
        discard_url(tail, finish, comments)
    end
  end

  defp complete_url(_token, tail, finish, false, _quoted?), do: discard_url(tail, finish, [])

  defp discard_url(tail, finish, comments) do
    rest = bad_url(tail)
    {nil, rest, finish + byte_size(tail) - byte_size(rest), comments}
  end

  def trivia(body, offset), do: trivia(body, offset, [])

  defp trivia(<<"/*", rest::binary>>, offset, comments) do
    length = comment_length(rest) + 2
    trivia(drop(rest, length - 2), offset + length, [{offset, length} | comments])
  end

  defp trivia(<<byte, rest::binary>>, offset, comments) when byte in [?\s, ?\t, ?\n, ?\r, ?\f] do
    trivia(rest, offset + 1, comments)
  end

  defp trivia(body, offset, comments), do: {body, offset, comments}

  defp whitespace(<<byte, rest::binary>>, offset) when byte in [?\s, ?\t, ?\n, ?\r, ?\f] do
    whitespace(rest, offset + 1)
  end

  defp whitespace(body, offset), do: {body, offset}

  defp string(<<>>, _quote, acc), do: {finish(acc), "", false}
  defp string(<<"\\">>, _quote, acc), do: {finish(acc), "", false}

  defp string(<<"\\\r\n", rest::binary>>, quote, acc), do: string(rest, quote, acc)

  defp string(<<"\\", byte, rest::binary>>, quote, acc) when byte in [?\n, ?\r, ?\f] do
    string(rest, quote, acc)
  end

  defp string(<<"\\", _rest::binary>> = body, quote, acc) do
    {decoded, rest} = Identifier.decode_escape(body)
    string(rest, quote, [decoded | acc])
  end

  defp string(<<byte, _rest::binary>> = body, _quote, acc) when byte in [?\n, ?\r, ?\f],
    do: {finish(acc), body, false}

  defp string(body, expected, acc) do
    case quote_info(body) do
      {^expected, length, _normalized} ->
        {finish(acc), drop(body, length), true}

      _ ->
        <<byte, rest::binary>> = body
        string(rest, expected, [byte | acc])
    end
  end

  defp unquoted(<<>>, _kind, acc), do: {finish(acc), "", true}
  defp unquoted(<<"\\">>, :url, acc), do: {finish([<<0xFFFD::utf8>> | acc]), "", true}

  defp unquoted(<<"\\", byte, _rest::binary>> = body, :url, acc)
       when byte in [?\n, ?\r, ?\f],
       do: {finish(acc), body, false}

  defp unquoted(<<byte, _rest::binary>> = body, :url, acc)
       when byte in [?", ?', ?(] or non_printable(byte),
       do: {finish(acc), body, false}

  defp unquoted(<<"\\", _rest::binary>> = body, kind, acc) do
    {decoded, rest} = Identifier.decode_escape(body)
    unquoted(rest, kind, [decoded | acc])
  end

  defp unquoted(<<byte, _rest::binary>> = body, _kind, acc)
       when byte in [?\s, ?\t, ?\n, ?\r, ?\f, ?)],
       do: {finish(acc), body, true}

  defp unquoted(<<byte, _rest::binary>> = body, :candidate, acc) when byte in [?\,, ?(],
    do: {finish(acc), body, true}

  defp unquoted(<<byte, rest::binary>>, kind, acc), do: unquoted(rest, kind, [byte | acc])

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

  defp finish(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp drop(body, length), do: binary_part(body, length, byte_size(body) - length)
end
