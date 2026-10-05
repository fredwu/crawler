defmodule Crawler.Snapper.LinkReplacer.Html do
  @moduledoc false

  alias Crawler.HTMLReferences
  alias Crawler.HTMLRefresh
  alias Crawler.HTMLSpans
  alias Crawler.MediaType
  alias Crawler.Parser.Srcset
  alias Crawler.Snapper.LinkReplacer.Css

  def replace(body, variant, offline, opts) do
    edits =
      body
      |> HTMLSpans.tags()
      |> Enum.reject(&(&1.closing? or &1.in_template?))
      |> Enum.flat_map(&replace_tag(&1, variant, offline, opts))

    HTMLSpans.rewrite(body, edits)
  end

  defp replace_tag(tag, variant, offline, opts) do
    attrs = Enum.map(tag.attributes, &{&1.name, &1.decoded})
    names = HTMLReferences.attributes(tag.name, attrs, opts, tag.namespace)

    tag.attributes
    |> Enum.uniq_by(& &1.name)
    |> Enum.filter(&(&1.name in names))
    |> Enum.flat_map(fn attr ->
      replacement = replace_value(tag, attr, variant, offline)

      if attr.value_span && replacement != attr.value do
        [{attr.value_span, replacement}]
      else
        []
      end
    end)
  end

  defp replace_value(
         _tag,
         %{name: name, decoded: variant, terminal_slash?: terminal},
         variant,
         offline
       )
       when name in ~w(href xlink:href src poster data) do
    if terminal, do: "\"" <> offline <> "\"", else: offline
  end

  defp replace_value(_tag, %{name: name, value: value}, variant, offline)
       when name in ~w(srcset imagesrcset) do
    Srcset.replace(value, variant, offline)
  end

  defp replace_value(_tag, %{name: "style", value: value}, variant, offline) do
    Css.replace(value, variant, offline)
  end

  defp replace_value(_tag, %{name: "content", value: value}, variant, offline) do
    HTMLRefresh.replace(value, variant, offline)
  end

  defp replace_value(_tag, attr, _variant, _offline), do: attr.value

  def drop_base(body, opts) do
    if MediaType.html?(opts[:content_type]) do
      edits = body |> HTMLSpans.base_tags() |> Enum.flat_map(&base_edits/1)
      HTMLSpans.rewrite(body, edits)
    else
      body
    end
  end

  defp base_edits(tag) do
    {hrefs, others} = Enum.split_with(tag.attributes, &(&1.name == "href"))

    if others == [],
      do: [{tag.span, ""}],
      else: Enum.map(hrefs, &{&1.span, ""})
  end

  def drop_rewritten_integrity(body, tokens, opts) do
    if MediaType.html?(opts[:content_type]) do
      tokens = MapSet.new(tokens)

      edits =
        body
        |> HTMLSpans.tags()
        |> Enum.filter(&rewritten_resource?(&1, tokens))
        |> Enum.flat_map(fn tag ->
          for attr <- tag.attributes, attr.name == "integrity", do: {attr.span, ""}
        end)

      HTMLSpans.rewrite(body, edits)
    else
      body
    end
  end

  defp rewritten_resource?(tag, tokens) do
    attrs = Enum.map(tag.attributes, &{&1.name, &1.decoded})
    attr = if tag.name == "script", do: "src", else: "href"

    not tag.closing? and not tag.in_template? and tag.namespace == :html and
      HTMLReferences.integrity_resource?(tag.name, attrs) and
      MapSet.member?(tokens, HTMLSpans.value(tag, attr))
  end
end
