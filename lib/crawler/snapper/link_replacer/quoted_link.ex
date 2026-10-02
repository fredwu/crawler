defmodule Crawler.Snapper.LinkReplacer.QuotedLink do
  @moduledoc false

  @entity_quotes [
    {"&quot;", "&quot;"},
    {"&apos;", "&apos;"},
    {"&#0*34;", "&#34;"},
    {"(?i:&#x0*22;)", "&#x22;"},
    {"&#0*39;", "&#39;"},
    {"(?i:&#x0*27;)", "&#x27;"}
  ]

  def replace(body, variant, offline, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "")
    suffix = Keyword.get(opts, :suffix, "")
    render = Keyword.get(opts, :render, &render/4)
    escaped = Regex.escape(variant)
    literal = Regex.compile!("(#{prefix})([\"'])#{escaped}\\2(#{suffix})")

    body =
      Regex.replace(literal, body, fn _, before, quote, after_quote ->
        render.(before, quote, after_quote, offline)
      end)

    entities = if Keyword.get(opts, :entity_quotes, true), do: @entity_quotes, else: []

    Enum.reduce(entities, body, fn {pattern, quote}, body ->
      pattern = Regex.compile!("(#{prefix})#{pattern}#{escaped}#{pattern}(#{suffix})")

      Regex.replace(pattern, body, fn _, before, after_quote ->
        render.(before, quote, after_quote, offline)
      end)
    end)
  end

  def data_spans(body, opts) do
    entities =
      if Keyword.get(opts, :entity_quotes, true) do
        Enum.flat_map(@entity_quotes, fn {pattern, _quote} -> entity_data_spans(body, pattern) end)
      else
        []
      end

    body
    |> literal_data_spans()
    |> Kernel.++(entities)
    |> Enum.sort_by(fn {at, length} -> {at, -length} end)
    |> Enum.reduce([], &keep_outer_span/2)
  end

  defp literal_data_spans(body) do
    ~r/"(?:\\.|[^"])*"|'(?:\\.|[^'])*'/s
    |> Regex.scan(body, return: :index)
    |> Enum.flat_map(fn [{at, length}] ->
      inner = binary_part(body, at + 1, max(length - 2, 0))
      if data_url?(inner), do: [{at, length}], else: []
    end)
  end

  defp entity_data_spans(body, quote) do
    quote
    |> then(&Regex.compile!("(#{&1})(.*?)#{&1}", "s"))
    |> Regex.scan(body, return: :index)
    |> Enum.flat_map(fn [{at, length}, _quote, {inner_at, inner_length}] ->
      inner = binary_part(body, inner_at, inner_length)
      if data_url?(inner), do: [{at, length}], else: []
    end)
  end

  defp keep_outer_span({at, _length}, [{outer_at, outer_length} | _] = spans)
       when at < outer_at + outer_length,
       do: spans

  defp keep_outer_span(span, spans), do: [span | spans]

  defp data_url?(url), do: String.match?(url, ~r/^\s*data:/i)

  defp render(before, quote, after_quote, offline) do
    before <> quote <> offline <> quote <> after_quote
  end
end
