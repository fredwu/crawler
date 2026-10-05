defmodule Crawler.HTMLRefresh do
  @moduledoc false

  alias Crawler.HTMLSpans

  @delay ~r/^[\t\n\f\r ]*(?:[0-9]+[0-9.]*|\.[0-9.]*)/
  @separator ~r/^[\t\n\f\r ]*[;,]?[\t\n\f\r ]*/
  @prefix ~r/^url[\t\n\f\r ]*=[\t\n\f\r ]*/i

  def target(value) when is_binary(value) do
    with [{0, length}] <- Regex.run(@delay, value, return: :index),
         rest <- binary_part(value, length, byte_size(value) - length),
         true <- rest != "" and separator?(rest) do
      start = length + match_length(@separator, rest)
      rest = binary_part(value, start, byte_size(value) - start)
      start = start + match_length(@prefix, rest)
      target_at(value, start)
    else
      _ -> nil
    end
  end

  def target(_value), do: nil

  def replace(value, variant, offline) do
    {decoded, segments} = HTMLSpans.decode_with_spans(value)

    case target(decoded) do
      %{url: ^variant, span: span} ->
        HTMLSpans.rewrite(value, [{HTMLSpans.source_span(segments, span), offline}])

      _ ->
        value
    end
  end

  defp separator?(<<char, _rest::binary>>), do: char in [9, 10, 12, 13, 32, ?;, ?,]

  defp target_at(value, start) when start >= byte_size(value), do: nil

  defp target_at(value, start) do
    rest = binary_part(value, start, byte_size(value) - start)

    {start, length} =
      case rest do
        <<quote, tail::binary>> when quote in [?", ?'] ->
          length =
            case :binary.match(tail, <<quote>>) do
              {at, _} -> at
              :nomatch -> byte_size(tail)
            end

          {start + 1, length}

        _ ->
          {start, byte_size(rest)}
      end

    url = binary_part(value, start, length)
    if String.trim(url) == "", do: nil, else: %{url: url, span: {start, length}}
  end

  defp match_length(pattern, value) do
    case Regex.run(pattern, value, return: :index) do
      [{0, length}] -> length
      _ -> 0
    end
  end
end
