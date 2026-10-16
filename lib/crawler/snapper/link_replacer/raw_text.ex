defmodule Crawler.Snapper.LinkReplacer.RawText do
  @moduledoc false

  alias Crawler.HTMLReferences
  alias Crawler.HTMLSpans
  alias Crawler.ImportMap
  alias Crawler.MediaType
  alias Crawler.Parser
  alias Crawler.Snapper.LinkReplacer.Tokens

  def protect(body, opts) do
    if MediaType.css?(opts[:content_type]) or MediaType.javascript?(opts[:content_type]) do
      {body, []}
    else
      document = Parser.with_document_base(body, opts)
      base = document[:referrer_url] || document[:url]
      tags = body |> HTMLSpans.tags() |> Enum.filter(& &1.content_span)
      maps = maps_before(tags, body, opts, base)
      prefix = Tokens.prefix([body], "R")

      tags
      |> Enum.zip(maps)
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce({body, []}, &protect_region(&1, &2, opts, prefix, base))
    end
  end

  def restore(body, saved, rewrite) do
    Enum.reduce(saved, body, fn {token, source, source_opts}, body ->
      source = if source_opts, do: rewrite.(source, source_opts), else: source
      String.replace(body, token, source)
    end)
  end

  defp protect_region({{tag, map}, index}, {body, saved}, opts, prefix, base) do
    {start, length} = tag.content_span
    source = binary_part(body, start, length)
    source_opts = source_options(tag, opts, map, base)
    token = Tokens.at(prefix, index)
    head = binary_part(body, 0, start)
    tail = binary_part(body, start + length, byte_size(body) - start - length)

    {head <> token <> tail, [{token, source, source_opts} | saved]}
  end

  defp maps_before(tags, body, opts, base) do
    {maps, _map} =
      Enum.map_reduce(tags, ImportMap.empty(), fn tag, map ->
        next =
          if import_map_tag?(tag, opts) do
            ImportMap.merge_source(HTMLSpans.slice(body, tag.content_span), map, base || "")
          else
            map
          end

        {map, next}
      end)

    maps
  end

  defp import_map_tag?(tag, opts) do
    tag.name == "script" and tag.namespace == :html and not tag.in_template? and
      not tag.in_shadow_root? and HTMLReferences.enabled?(opts, "js") and
      HTMLReferences.import_map?(tuple_attrs(tag))
  end

  defp source_options(%{in_template?: true}, _opts, _map, _base), do: nil

  defp source_options(tag, opts, map, base) do
    attrs = tuple_attrs(tag)

    cond do
      tag.name == "style" and HTMLReferences.enabled?(opts, "css") and
          HTMLReferences.css_style_element?(attrs) ->
        style_source(tag, base)

      speculation_inline?(tag, attrs) ->
        speculation_source(base)

      tag.name == "script" and tag.namespace == :svg and HTMLReferences.enabled?(opts, "js") and
          HTMLReferences.svg_script_source(attrs) == :inline ->
        inline_script_options(attrs, map, base)

      tag.name == "script" and tag.namespace != :svg and HTMLReferences.enabled?(opts, "js") and
          HTMLReferences.script_source(attrs) == :inline ->
        inline_script_options(attrs, map, base)

      true ->
        nil
    end
  end

  defp style_source(%{namespace: :svg}, base) do
    put_referrer(
      %{content_type: "text/css", svg_style: true, inline_source: true, headers: []},
      base
    )
  end

  defp style_source(_tag, base) do
    put_referrer(%{content_type: "text/css", inline_source: true, headers: []}, base)
  end

  defp speculation_inline?(tag, attrs) do
    tag.name == "script" and tag.namespace == :html and
      HTMLReferences.speculation_rules?(attrs) and
      is_nil(HTMLReferences.attribute(attrs, "src"))
  end

  defp speculation_source(base) do
    put_referrer(
      %{
        content_type: "application/speculationrules+json",
        fetch_kind: :speculation_rules,
        document_base: base
      },
      base
    )
  end

  defp inline_script_options(attrs, map, base) do
    put_referrer(
      %{
        content_type: "application/javascript",
        javascript_goal: HTMLReferences.script_goal(attrs),
        import_map: map,
        document_base: base,
        inline_source: true,
        headers: []
      },
      base
    )
  end

  defp put_referrer(opts, base) when is_binary(base), do: Map.put(opts, :referrer_url, base)
  defp put_referrer(opts, _base), do: opts

  defp tuple_attrs(tag), do: Enum.map(tag.attributes, &{&1.name, &1.decoded})
end
