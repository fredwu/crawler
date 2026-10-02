defmodule Crawler.Snapper.LinkReplacer.Css do
  @moduledoc false

  alias Crawler.Parser.CssParser
  alias Crawler.Snapper.LinkReplacer.QuotedLink

  def replace(body, variant, offline, opts \\ []) do
    {body, saved} = lift_quoted_data(body, opts)

    body
    |> replace_image_set(variant, offline, opts)
    |> replace_urls(variant, offline, opts)
    |> replace_imports(variant, offline, opts)
    |> restore_quoted_data(saved)
  end

  # Splice from the end. A rewritten path still contains the original
  # filename, so a later substring search would change that copy and skip
  # the rule that still has the short name.
  defp replace_image_set(body, variant, offline, opts) do
    body
    |> CssParser.image_set_spans()
    |> Enum.reverse()
    |> Enum.reduce(body, fn {start, inner}, body ->
      splice(body, start, inner, replace_image_set_quotes(inner, variant, offline, opts))
    end)
  end

  defp splice(body, _start, same, same), do: body

  defp splice(body, start, inner, updated) do
    length = byte_size(inner)
    head = binary_part(body, 0, start)
    tail = binary_part(body, start + length, byte_size(body) - start - length)

    head <> updated <> tail
  end

  defp replace_image_set_quotes(region, variant, offline, opts) do
    region
    |> QuotedLink.replace(variant, offline, opts)
    |> then(fn region ->
      Regex.replace(~r/(^|[\s,(])#{Regex.escape(variant)}(?=[\s,)]|$)/, region, fn _, prefix ->
        prefix <> offline
      end)
    end)
  end

  defp replace_urls(body, variant, offline, opts) do
    quote_opts =
      Keyword.merge(opts,
        prefix: "(?i:url)\\(\\s*",
        suffix: "\\s*\\)",
        render: fn _, quote, _, target -> "url(" <> quote <> target <> quote <> ")" end
      )

    body
    |> QuotedLink.replace(variant, offline, quote_opts)
    |> String.replace(~r/(?i:url)\(\s*#{Regex.escape(variant)}\s*\)/, "url(#{offline})")
  end

  defp replace_imports(body, variant, offline, opts) do
    QuotedLink.replace(body, variant, offline, Keyword.put(opts, :prefix, "(?i:@import)\\s+"))
  end

  # A quoted data URL is one token. Replacers must not change the payload
  # when it contains another file name.
  defp lift_quoted_data(body, opts) do
    spans = QuotedLink.data_spans(body, opts)

    Enum.reduce(Enum.with_index(spans), {body, []}, fn {{at, len}, i}, {body, saved} ->
      quoted = binary_part(body, at, len)
      token = <<0>> <> "D#{i}" <> <<0>>
      head = binary_part(body, 0, at)
      tail = binary_part(body, at + len, byte_size(body) - at - len)
      {head <> token <> tail, [{token, quoted} | saved]}
    end)
  end

  defp restore_quoted_data(body, saved) do
    Enum.reduce(saved, body, fn {token, quoted}, body ->
      String.replace(body, token, quoted)
    end)
  end
end
