defmodule Crawler.Snapper.LinkReplacer.Css do
  @moduledoc false

  alias Crawler.Parser.CssParser

  def replace(body, variant, offline, opts \\ []) do
    opts = Keyword.put_new(opts, :entity_quotes, true)

    body
    |> CssParser.spans(opts)
    |> Enum.reverse()
    |> Enum.reduce(body, fn token, body ->
      if token.value == variant do
        head = binary_part(body, 0, token.start)

        tail =
          binary_part(
            body,
            token.start + token.length,
            byte_size(body) - token.start - token.length
          )

        head <> token.quote <> offline <> closing_quote(token) <> tail
      else
        body
      end
    end)
  end

  defp closing_quote(%{closed?: false}), do: ""
  defp closing_quote(%{quote: quote}), do: quote
end
