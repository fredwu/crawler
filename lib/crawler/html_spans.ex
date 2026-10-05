defmodule Crawler.HTMLSpans do
  @moduledoc false

  alias Crawler.HTMLSpans.Context
  alias Crawler.HTMLSpans.Markup
  alias Crawler.HTMLSpans.ScriptData

  @name ~r/^<(\/?)([A-Za-z][^\t\n\f\r \/>]*)/
  @text_elements ~w(script style textarea title xmp iframe noembed noframes plaintext)
  @entity ~r/&#(?:[xX][0-9a-fA-F]+|[0-9]+);?|&[A-Za-z][A-Za-z0-9]*;?/

  def tags(body, opts \\ []), do: collect(body, 0, [], opts, [])

  def parser_source(body) do
    edits =
      body
      |> collect(0, [], [attributes: false, declarations: true, comments: true], [])
      |> Enum.flat_map(fn
        %{declaration?: true, span: span} -> [{span, "<!-- -->"}]
        %{comment?: true, span: span} -> parser_comment(body, span)
        _tag -> []
      end)

    rewrite(body, edits)
  end

  defp parser_comment(body, span) do
    source = slice(body, span)

    if source in ["<!-->", "<!--->"] or String.ends_with?(source, "--!>"),
      do: [{span, "<!-- -->"}],
      else: []
  end

  def base_tags(body) do
    body
    |> tags()
    |> Enum.filter(fn tag ->
      tag.name == "base" and not tag.closing? and tag.namespace == :html and
        not tag.in_template? and attribute(tag, "href") != nil
    end)
  end

  defp collect(body, offset, acc, opts, context) do
    case next_tag(body, offset, opts, context) do
      nil -> Enum.reverse(acc)
      {tag, next, context} -> collect(body, next, [tag | acc], opts, context)
    end
  end

  defp next_tag(body, offset, opts, context) do
    case Markup.next(body, offset, Context.foreign?(context)) do
      {start, length, kind} ->
        source = binary_part(body, start, length)
        consumed = start + length
        tail = remaining(body, consumed)

        case tag(source, start, opts) do
          nil ->
            non_tag(body, {start, length, kind}, opts, context)

          tag ->
            namespace = Context.namespace(tag, context)
            {content, skip} = content_span(tail, tag, consumed, namespace)

            tag =
              Map.merge(tag, %{
                content_span: content,
                namespace: namespace,
                in_template?: Context.in_template?(context)
              })

            {tag, consumed + skip, Context.advance(tag, namespace, context)}
        end

      nil ->
        nil
    end
  end

  defp non_tag(body, {start, length, kind}, opts, context) do
    consumed = start + length

    cond do
      kind == :declaration and Keyword.get(opts, :declarations, false) ->
        {%{declaration?: true, span: {start, length}}, consumed, context}

      kind == :comment and Keyword.get(opts, :comments, false) ->
        {%{comment?: true, span: {start, length}}, consumed, context}

      true ->
        next_tag(body, consumed, opts, context)
    end
  end

  defp tag(source, start, opts) do
    case Regex.run(@name, source, capture: :all_but_first) do
      [closing, name] ->
        %{
          name: String.downcase(name, :ascii),
          closing?: closing == "/",
          source: source,
          span: {start, byte_size(source)},
          self_closing?: self_closing?(source),
          attributes:
            if(Keyword.get(opts, :attributes, true), do: attributes(source, start), else: [])
        }

      nil ->
        nil
    end
  end

  defp self_closing?(source) do
    String.ends_with?(source, "/>") and
      not Enum.any?(attributes(source, 0, decode: false), & &1.terminal_slash?)
  end

  defp content_span(body, %{closing?: false, name: name}, offset, :html)
       when name in @text_elements do
    {length, consumed} = raw_end(body, name)
    {{offset, length}, consumed}
  end

  defp content_span(_body, _tag, _offset, _namespace), do: {nil, 0}

  defp raw_end(body, "plaintext"), do: {byte_size(body), byte_size(body)}
  defp raw_end(body, "script"), do: ScriptData.finish(body)

  defp raw_end(body, name) do
    case Regex.run(~r/<\/#{name}(?=[\t\n\f\r \/>])/i, body, return: :index) do
      [{start, _length}] ->
        case Markup.finish(body, start) do
          {finish, true} -> {start, finish}
          {_finish, false} -> {byte_size(body), byte_size(body)}
        end

      nil ->
        {byte_size(body), byte_size(body)}
    end
  end

  def attributes(source, offset \\ 0, opts \\ []) do
    source
    |> Markup.attributes()
    |> Enum.map(fn %{span: span, name_span: name, value_span: value_span} ->
      value = if value_span, do: slice(source, value_span), else: ""

      %{
        name: source |> slice(name) |> String.downcase(:ascii),
        value: value,
        decoded: if(Keyword.get(opts, :decode, true), do: decode(value), else: value),
        span: shift(span, offset),
        value_span: if(value_span, do: shift(value_span, offset)),
        terminal_slash?: terminal_slash?(source, value_span, value)
      }
    end)
  end

  defp terminal_slash?(source, {start, length}, value) do
    start + length == byte_size(source) - 1 and String.ends_with?(value, "/") and
      :binary.at(source, start - 1) not in [?", ?']
  end

  defp terminal_slash?(_source, _span, _value), do: false

  def decode(value) do
    source = "<i value=\"" <> String.replace(value, "\"", "&quot;") <> "\"></i>"
    {:ok, [{"i", [{"value", decoded}], _children}]} = Floki.parse_fragment(source)
    decoded
  end

  def decode_with_spans(value) do
    entities = Regex.scan(@entity, value, return: :index)

    {parts, segments, source_at, decoded_at} =
      Enum.reduce(entities, {[], [], 0, 0}, fn [{start, length}], acc ->
        {parts, segments, _source_at, decoded_at} = literal_segment(value, start, acc)
        entity = binary_part(value, start, length)
        after_entity = start + length

        next =
          if after_entity < byte_size(value),
            do: String.first(remaining(value, after_entity)),
            else: ""

        decoded = decode(entity <> next)
        decoded = binary_part(decoded, 0, byte_size(decoded) - byte_size(next))
        segment = {decoded_at, byte_size(decoded), start, length}
        {[parts, decoded], [segment | segments], after_entity, decoded_at + byte_size(decoded)}
      end)

    {parts, segments, _, _} =
      literal_segment(value, byte_size(value), {parts, segments, source_at, decoded_at})

    {IO.iodata_to_binary(parts), Enum.reverse(segments)}
  end

  def source_span(_segments, {0, 0}), do: {0, 0}

  def source_span(segments, {start, 0}) do
    {source_offset(segments, start, :finish), 0}
  end

  def source_span(segments, {start, length}) do
    first = source_offset(segments, start, :start)
    last = source_offset(segments, start + length, :finish)
    {first, last - first}
  end

  defp literal_segment(value, finish, {parts, segments, source_at, decoded_at}) do
    length = finish - source_at
    literal = binary_part(value, source_at, length)
    segment = {decoded_at, length, source_at, length}
    {[parts, literal], [segment | segments], finish, decoded_at + length}
  end

  defp source_offset(segments, offset, boundary) do
    {decoded_at, decoded_length, source_at, source_length} =
      Enum.find(segments, fn {start, length, _, _} ->
        if boundary == :start,
          do: offset >= start and offset < start + length,
          else: offset > start and offset <= start + length
      end)

    cond do
      decoded_length == source_length -> source_at + offset - decoded_at
      boundary == :start -> source_at
      true -> source_at + source_length
    end
  end

  def attribute(tag, name) do
    Enum.find(tag.attributes, &(&1.name == name))
  end

  def value(tag, name) do
    case attribute(tag, name) do
      nil -> nil
      attr -> attr.decoded
    end
  end

  @doc """
  Applies non-overlapping byte-span edits to the original source.

  Each edit is `{{start, length}, binary_replacement}`.
  Adjacent spans and boundary insertions are allowed. Insertions at the start
  of a replacement precede it; insertions at the same offset keep their input
  order. Invalid, overlapping, or out-of-range spans raise `ArgumentError`.
  """
  def rewrite(body, edits) do
    {parts, offset} =
      edits
      |> Enum.sort_by(&edit_position/1)
      |> Enum.reduce({[], 0}, fn {{start, length}, replacement}, {parts, offset} ->
        if start < offset or start + length > byte_size(body) do
          raise ArgumentError, "HTML edits must use non-overlapping spans within the source"
        end

        before = binary_part(body, offset, start - offset)
        {[replacement, before | parts], start + length}
      end)

    IO.iodata_to_binary([Enum.reverse(parts), remaining(body, offset)])
  end

  defp edit_position({{start, length}, replacement})
       when is_integer(start) and start >= 0 and is_integer(length) and length >= 0 and
              is_binary(replacement),
       do: {start, length}

  defp edit_position(_edit),
    do: raise(ArgumentError, "HTML edits must contain a byte span and a binary replacement")

  def slice(body, {start, length}), do: binary_part(body, start, length)

  defp shift({start, length}, offset), do: {start + offset, length}
  defp remaining(body, start), do: binary_part(body, start, byte_size(body) - start)
end
