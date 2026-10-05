defmodule Crawler.Parser.HtmlParser do
  @moduledoc """
  Parses HTML files.
  """

  alias Crawler.HTMLReferences
  alias Crawler.HTMLSpans

  @doc """
  Parses HTML files.

  ## Examples

      iex> HtmlParser.parse(
      iex>   "<a href='http://hello.world'>Link</a>",
      iex>   %{}
      iex> )
      [{"a", [{"href", "http://hello.world"}], ["Link"]}]

      iex> HtmlParser.parse(
      iex>   "<script type='text/javascript'>js</script>",
      iex>   %{assets: ["js"]}
      iex> )
      [{"script", [{"type", "text/javascript"}], ["js"]}]
  """
  def parse(body, opts) do
    tags = HTMLSpans.tags(body)
    {source, saved, identity} = prepare_source(body, tags)
    {:ok, document} = source |> HTMLSpans.parser_source() |> Floki.parse_document()
    {_document, children_by_source} = restore_nodes(document, saved, identity, %{})

    tags
    |> reference_tags(body, opts)
    |> Enum.map(fn tag ->
      {start, _length} = tag.span

      children =
        if tag.content_span,
          do: tag.children,
          else: Map.get(children_by_source, Integer.to_string(start), [])

      {tag.name, tag.attributes, children}
    end)
  end

  def references(body, opts) do
    body
    |> HTMLSpans.tags()
    |> reference_tags(body, opts)
  end

  defp reference_tags(tags, body, opts) do
    tags
    |> Enum.reject(&(&1.closing? or &1.in_template?))
    |> Enum.map(fn tag ->
      attrs =
        tag.attributes |> Enum.map(&{&1.name, &1.decoded}) |> HTMLReferences.active_attributes()

      children = if tag.content_span, do: [HTMLSpans.slice(body, tag.content_span)], else: []
      Map.merge(tag, %{attributes: attrs, children: children})
    end)
    |> Enum.filter(fn tag ->
      HTMLReferences.attributes(tag.name, tag.attributes, opts, tag.namespace) != [] or
        (tag.namespace == :html and
           ((tag.name == "script" and HTMLReferences.enabled?(opts, "js")) or
              (tag.name == "style" and HTMLReferences.enabled?(opts, "css"))))
    end)
  end

  defp prepare_source(body, tags) do
    prefix = text_prefix(body, "CRAWLER_RAW_TEXT_")
    names = for tag <- tags, attr <- tag.attributes, into: MapSet.new(), do: attr.name
    identity = identity_attribute(names, "data-crawler-source")

    {edits, saved} =
      tags
      |> Enum.filter(& &1.content_span)
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn {tag, index}, saved ->
        token = prefix <> Integer.to_string(index) <> "_"

        {{tag.content_span, token},
         Map.put(saved, token, HTMLSpans.slice(body, tag.content_span))}
      end)

    attributes = Enum.flat_map(tags, &parser_attribute_edits(&1, identity))
    {HTMLSpans.rewrite(body, edits ++ attributes), saved, identity}
  end

  defp parser_attribute_edits(%{closing?: true}, _identity), do: []

  defp parser_attribute_edits(tag, identity) do
    {edits, _names} =
      Enum.map_reduce(tag.attributes, MapSet.new(), fn attr, names ->
        edit =
          cond do
            MapSet.member?(names, attr.name) ->
              [{attr.span, ""}]

            unquoted_value?(tag, attr) ->
              [{attr.value_span, "\"" <> String.replace(attr.value, "\"", "&quot;") <> "\""}]

            true ->
              []
          end

        {edit, MapSet.put(names, attr.name)}
      end)

    {start, _length} = tag.span
    position = start + 1 + byte_size(tag.name)
    marker = " " <> identity <> "=\"" <> Integer.to_string(start) <> "\""
    [{{position, 0}, marker} | List.flatten(edits)]
  end

  defp unquoted_value?(_tag, %{value_span: nil}), do: false

  defp unquoted_value?(%{span: {start, _}, source: source}, %{value_span: {at, _}}),
    do: :binary.at(source, at - start - 1) not in [?", ?']

  defp text_prefix(body, prefix) do
    if String.contains?(body, prefix), do: text_prefix(body, prefix <> "_"), else: prefix
  end

  defp identity_attribute(names, name) do
    if MapSet.member?(names, name), do: identity_attribute(names, name <> "-"), else: name
  end

  defp restore_nodes(document, saved, identity, sources) do
    Enum.map_reduce(document, sources, fn
      {tag, attrs, children}, sources ->
        {children, sources} = restore_nodes(children, saved, identity, sources)

        case List.keytake(attrs, identity, 0) do
          {{_identity, position}, attrs} ->
            {{tag, attrs, children}, Map.put(sources, position, children)}

          nil ->
            {{tag, attrs, children}, sources}
        end

      text, sources when is_binary(text) ->
        text =
          Enum.reduce(saved, text, fn {token, source}, text ->
            String.replace(text, token, source)
          end)

        {text, sources}

      node, sources ->
        {node, sources}
    end)
  end
end
