defmodule Crawler.HTMLSpans do
  @moduledoc false

  alias Crawler.HTMLSpans.Context
  alias Crawler.HTMLSpans.Markup
  alias Crawler.HTMLSpans.ScriptData
  alias Crawler.MediaType

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
        not tag.in_template? and not tag.in_shadow_root? and attribute(tag, "href") != nil
    end)
  end

  def css_xml_stylesheets(body) when is_binary(body) do
    body
    |> collect(0, [], [declarations: true], [])
    |> Enum.flat_map(fn
      %{declaration?: true, in_template?: false, span: {start, _length}} ->
        css_xml_stylesheet(body, start)

      _other ->
        []
    end)
  end

  def css_xml_stylesheets(_body), do: []

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
                in_template?: Context.in_template?(context),
                in_shadow_root?: Context.in_shadow_root?(context)
              })

            {tag, consumed + skip, Context.advance(tag, namespace, context)}
        end

      nil ->
        nil
    end
  end

  defp non_tag(body, {start, length, kind}, opts, context) do
    consumed = declaration_end(body, start, length, kind)

    cond do
      kind == :declaration and Keyword.get(opts, :declarations, false) ->
        {%{
           declaration?: true,
           span: {start, consumed - start},
           in_template?: Context.in_template?(context)
         }, consumed, context}

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

  defp content_span(body, %{closing?: false, self_closing?: false, name: name}, offset, :svg)
       when name in ["script", "style"] do
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

  @pi_space ~c" \t\n\f\r"
  @pi_stop @pi_space ++ ~c"?>="

  defp css_xml_stylesheet(body, start) do
    case xml_stylesheet_boundary(body, start) do
      {:pi, finish} ->
        sheets_in(start, binary_part(body, start, finish - start))

      _other ->
        []
    end
  end

  defp sheets_in(start, source) do
    case xml_stylesheet(source) do
      %{"type" => type, "href" => href} ->
        css_sheet(start, type, href)

      _other ->
        []
    end
  end

  defp css_sheet(start, type, href) do
    if MediaType.css?(type.value) do
      {href_start, href_length} = href.span
      [%{href: href.value, type: type.value, href_span: {start + href_start, href_length}}]
    else
      []
    end
  end

  # Resume after an xml-stylesheet. Quoted values can contain ">" and "?>",
  # so the HTML declaration end is too early and those bytes are not markup.
  # "?>" outside quotes ends the instruction. ">" outside quotes does not:
  # resume after it, do not read a sheet, and leave the next instruction.
  # A quote that never closes runs to the end of the page.
  defp declaration_end(body, start, length, :declaration) do
    case xml_stylesheet_boundary(body, start) do
      {_kind, finish} when finish > start + length -> finish
      _other -> start + length
    end
  end

  defp declaration_end(_body, start, length, _kind), do: start + length

  defp xml_stylesheet_boundary(body, start) do
    size = byte_size(body)

    with true <- start + 2 <= size,
         "<?" <- binary_part(body, start, 2),
         {name, offset} <- take_pi_name(body, start + 2, size, <<>>),
         true <- String.downcase(name, :ascii) == "xml-stylesheet",
         {kind, finish} when kind in [:pi, :gt, :open] <- pi_boundary(body, offset, size, nil) do
      {kind, finish}
    else
      _miss -> nil
    end
  end

  defp pi_boundary(body, offset, size, delimiter) when offset < size do
    byte = :binary.at(body, offset)

    cond do
      delimiter == nil and byte == ?? and offset + 1 < size and
          :binary.at(body, offset + 1) == ?> ->
        {:pi, offset + 2}

      delimiter == nil and byte == ?> ->
        {:gt, offset + 1}

      delimiter == nil and byte in ~c"\"'" ->
        pi_boundary(body, offset + 1, size, byte)

      delimiter != nil and byte == delimiter ->
        pi_boundary(body, offset + 1, size, nil)

      true ->
        pi_boundary(body, offset + 1, size, delimiter)
    end
  end

  defp pi_boundary(_body, _offset, size, delimiter) when is_integer(delimiter), do: {:open, size}

  defp pi_boundary(_body, _offset, _size, _delimiter), do: nil

  defp xml_stylesheet(<<"<?", _rest::binary>> = source) do
    {name, offset} = take_pi_name(source, 2, byte_size(source), <<>>)

    if String.downcase(name, :ascii) == "xml-stylesheet",
      do: read_pseudo_attributes(source, offset, %{}),
      else: nil
  end

  defp xml_stylesheet(_source), do: nil

  defp read_pseudo_attributes(source, offset, acc) do
    offset = skip_pi_space(source, offset)
    size = byte_size(source)

    cond do
      offset >= size ->
        acc

      :binary.at(source, offset) in ~c"?>" ->
        acc

      true ->
        case read_pseudo_attribute(source, offset) do
          {name, value, span, next} ->
            acc = Map.put_new(acc, String.downcase(name, :ascii), %{value: value, span: span})
            read_pseudo_attributes(source, next, acc)

          :error ->
            acc
        end
    end
  end

  defp read_pseudo_attribute(source, offset) do
    size = byte_size(source)

    case take_pi_name(source, offset, size, <<>>) do
      {"", _offset} ->
        :error

      {name, offset} ->
        offset = skip_pi_space(source, offset)

        if offset < size and :binary.at(source, offset) == ?= do
          read_pseudo_value(source, skip_pi_space(source, offset + 1), name)
        else
          :error
        end
    end
  end

  defp read_pseudo_value(source, offset, name) when offset < byte_size(source) do
    delimiter = :binary.at(source, offset)

    if delimiter in ~c"\"'" do
      value_start = offset + 1
      scope = {value_start, byte_size(source) - value_start}

      case :binary.match(source, <<delimiter>>, scope: scope) do
        {finish, 1} ->
          value = binary_part(source, value_start, finish - value_start)
          {name, value, {value_start, finish - value_start}, finish + 1}

        :nomatch ->
          :error
      end
    else
      :error
    end
  end

  defp read_pseudo_value(_source, _offset, _name), do: :error

  defp take_pi_name(_source, offset, size, acc) when offset >= size, do: {acc, offset}

  defp take_pi_name(source, offset, size, acc) do
    char = :binary.at(source, offset)

    if char in @pi_stop,
      do: {acc, offset},
      else: take_pi_name(source, offset + 1, size, <<acc::binary, char>>)
  end

  defp skip_pi_space(source, offset) when offset >= byte_size(source), do: offset

  defp skip_pi_space(source, offset) do
    if :binary.at(source, offset) in @pi_space,
      do: skip_pi_space(source, offset + 1),
      else: offset
  end

  defp shift({start, length}, offset), do: {start + offset, length}
  defp remaining(body, start), do: binary_part(body, start, byte_size(body) - start)
end
