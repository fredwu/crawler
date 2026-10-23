defmodule Crawler.HTMLSpans do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.HTMLSpans.Context
  alias Crawler.HTMLSpans.Markup
  alias Crawler.HTMLSpans.ScriptData
  alias Crawler.MediaType

  @name ~r/^<(\/?)([A-Za-z][^\t\n\f\r \/>]*)/
  @text_elements ~w(script style textarea title xmp iframe noembed noframes plaintext)
  @entity ~r/&#(?:[xX][0-9a-fA-F]+|[0-9]+);?|&[A-Za-z][A-Za-z0-9]*;?/

  def tags(body, opts \\ []), do: collect(body, 0, [], opts, [])

  def tags_result(body, opts, budget), do: collect_result(body, 0, [], opts, [], budget)

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
    {:ok, tags, _budget} = collect_result(body, offset, acc, opts, context, Budget.unlimited())
    tags
  end

  @doc """
  Reduces canonical tags without retaining their scanner records.

  The callback receives a borrowed tag and returns `{:cont, acc, budget}`,
  `{:halt, acc, budget}`, or an error. It must charge any retained projections
  separately. Tag and attribute storage is released after the callback; live
  scanner context remains charged until it closes or the reduction ends.
  """
  def reduce_tags_result(body, opts, budget, acc, fun) do
    reduce_tags(body, 0, opts, [], budget, acc, fun, :borrow, 0)
  end

  defp collect_result(body, offset, acc, opts, context, budget) do
    collect = fn tag, tags, budget -> {:cont, [tag | tags], budget} end

    with {:ok, acc, budget} <-
           reduce_tags(body, offset, opts, context, budget, acc, collect, :retain, 0) do
      scratch = Budget.cost(:list_cell, length(acc))

      with {:ok, budget} <- Budget.reserve(budget, scratch) do
        tags = Enum.reverse(acc)
        with {:ok, budget} <- Budget.release(budget, scratch), do: {:ok, tags, budget}
      end
    end
  end

  defp reduce_tags(body, offset, opts, context, budget, acc, fun, mode, context_bytes) do
    before = budget.retained

    case next_tag(body, offset, opts, context, budget) do
      {:ok, nil, budget} ->
        with {:ok, budget, _context_bytes} <-
               release_tag(mode, budget.retained - before, context_bytes, [], budget),
             do: {:ok, acc, budget}

      {:ok, {tag, next, context}, budget} ->
        allocated = budget.retained - before

        case fun.(tag, acc, budget) do
          {:cont, acc, budget} ->
            with {:ok, budget, context_bytes} <-
                   release_tag(mode, allocated, context_bytes, context, budget) do
              reduce_tags(body, next, opts, context, budget, acc, fun, mode, context_bytes)
            end

          {:halt, acc, budget} ->
            with {:ok, budget, _context_bytes} <-
                   release_tag(mode, allocated, context_bytes, [], budget),
                 do: {:ok, acc, budget}

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp release_tag(:retain, _allocated, _context_bytes, _context, budget),
    do: {:ok, budget, 0}

  defp release_tag(:borrow, allocated, context_bytes, context, budget) do
    next_context_bytes =
      Enum.reduce(context, 0, fn node, bytes ->
        bytes + Budget.cost(:context) + Budget.cost(:binary) + byte_size(node.name)
      end)

    with {:ok, budget} <- Budget.refund(budget, allocated + context_bytes - next_context_bytes),
         do: {:ok, budget, next_context_bytes}
  end

  defp next_tag(body, offset, opts, context, budget) do
    project = fn source, attribute, name_span, budget ->
      project_attribute(source, attribute, 0, opts, {:tag, name_span}, budget)
    end

    case Markup.next_result(body, offset, Context.foreign?(context), project, budget) do
      {:ok, {start, length, :tag, attributes}, budget} ->
        source = binary_part(body, start, length)
        consumed = start + length

        with {:ok, budget} <- Budget.reserve(budget, Budget.cost(:tag, 2)),
             {:ok, tag, budget} <- tag(source, start, opts, attributes, budget),
             {:ok, budget} <- Budget.charge(budget, Budget.cost(:context)) do
          namespace = Context.namespace(tag, context)
          {content, skip} = content_span(remaining(body, consumed), tag, consumed, namespace)

          tag =
            Map.merge(tag, %{
              content_span: content,
              namespace: namespace,
              in_template?: Context.in_template?(context),
              in_shadow_root?: Context.in_shadow_root?(context)
            })

          next_context = Context.advance(tag, namespace, context)
          tag = Map.delete(tag, :context_attributes)

          with {:ok, budget} <- Budget.release(budget, Budget.cost(:tag, 2)),
               do: {:ok, {tag, consumed + skip, next_context}, budget}
        end

      {:ok, {start, length, kind, _attributes}, budget} ->
        non_tag(body, {start, length, kind}, opts, context, budget)

      {:ok, nil, budget} ->
        {:ok, nil, budget}

      {:error, _reason} = error ->
        error
    end
  end

  defp non_tag(body, {start, length, kind}, opts, context, budget) do
    consumed = declaration_end(body, start, length, kind)

    cond do
      kind == :declaration and Keyword.get(opts, :declarations, false) ->
        with {:ok, budget} <- Budget.charge(budget, Budget.cost(:tag), facts: 1),
             do:
               {:ok,
                {%{
                   declaration?: true,
                   span: {start, consumed - start},
                   in_template?: Context.in_template?(context)
                 }, consumed, context}, budget}

      kind == :comment and Keyword.get(opts, :comments, false) ->
        with {:ok, budget} <- Budget.charge(budget, Budget.cost(:tag), facts: 1),
             do: {:ok, {%{comment?: true, span: {start, length}}, consumed, context}, budget}

      true ->
        next_tag(body, consumed, opts, context, budget)
    end
  end

  defp tag(source, start, opts, attributes, budget) do
    [{_closing_at, closing_length}, {name_start, name_length}] =
      Regex.run(@name, source, capture: :all_but_first, return: :index)

    with {:ok, name, budget} <- downcase_result(source, {name_start, name_length}, budget) do
      {:ok,
       %{
         name: name,
         closing?: closing_length != 0,
         source: source,
         span: {start, byte_size(source)},
         self_closing?:
           String.ends_with?(source, "/>") and
             not Enum.any?(attributes, & &1.terminal_slash?),
         attributes: if(Keyword.get(opts, :attributes, true), do: attributes, else: []),
         context_attributes: attributes
       }, budget}
    end
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
    {:ok, attributes, _budget} = attributes_result(source, offset, opts, Budget.unlimited())
    attributes
  end

  def attributes_result(source, offset, opts, budget) do
    project = fn body, attribute, _finish, budget ->
      project_attribute(body, attribute, offset, opts, :attributes, budget)
    end

    Markup.attributes_result(source, project, budget)
  end

  defp project_attribute(
         source,
         %{span: span, name_span: name_span, value_span: value_span},
         offset,
         opts,
         mode,
         budget
       ) do
    length = if value_span, do: elem(value_span, 1), else: 0

    with {:ok, name, budget} <- downcase_result(source, name_span, budget),
         {:ok, budget} <- Budget.charge(budget, Budget.cost(:binary) + min(length, 64)) do
      value = if value_span, do: slice(source, value_span), else: ""

      decode? =
        case mode do
          {:tag, name_span} ->
            Keyword.get(opts, :attributes, true) or
              (name == "encoding" and annotation_xml?(source, name_span) and String.valid?(value))

          :attributes ->
            Keyword.get(opts, :decode, true)
        end

      with {:ok, decoded, budget} <- attribute_decode(value, decode?, budget) do
        {:ok,
         %{
           name: name,
           value: value,
           decoded: decoded,
           span: shift(span, offset),
           value_span: if(value_span, do: shift(value_span, offset)),
           terminal_slash?: terminal_slash?(source, value_span, value, mode)
         }, budget}
      end
    end
  end

  defp annotation_xml?(source, {_start, 14} = span),
    do: source |> slice(span) |> String.downcase(:ascii) == "annotation-xml"

  defp annotation_xml?(_source, _span), do: false

  defp attribute_decode(value, true, budget), do: decode_result(value, budget)
  defp attribute_decode(value, false, budget), do: {:ok, value, budget}

  defp terminal_slash?(source, {start, length}, value, mode) do
    finish = start + length

    terminal? =
      if is_tuple(mode),
        do: finish < byte_size(source) and :binary.at(source, finish) == ?>,
        else: finish == byte_size(source) - 1

    terminal? and String.ends_with?(value, "/") and :binary.at(source, start - 1) not in [?", ?']
  end

  defp terminal_slash?(_source, _span, _value, _mode), do: false

  defp downcase_result(source, {_start, length} = span, budget) do
    reservation = Budget.cost(:binary) + length * 33

    with {:ok, budget} <- Budget.reserve(budget, reservation) do
      result = source |> slice(span) |> String.downcase(:ascii)

      with {:ok, budget} <-
             Budget.settle(budget, reservation, Budget.cost(:binary) + byte_size(result)),
           do: {:ok, result, budget}
    end
  end

  def decode(value) do
    {:ok, decoded, _budget} = decode_result(value, Budget.unlimited())
    decoded
  end

  def decode_result(value, budget) do
    reservation = 2048 + byte_size(value) * 160

    with {:ok, budget} <- Budget.reserve(budget, reservation) do
      source = "<i value=\"" <> String.replace(value, "\"", "&quot;") <> "\"></i>"
      {:ok, [{"i", [{"value", decoded}], _children}]} = Floki.parse_fragment(source)

      with {:ok, budget} <-
             Budget.settle(budget, reservation, Budget.cost(:binary) + byte_size(decoded)),
           do: {:ok, decoded, budget}
    end
  end

  def decode_with_spans(value) do
    {:ok, result, _budget} = decode_with_spans_result(value, Budget.unlimited())
    result
  end

  def decode_with_spans_result(value, budget),
    do: decode_segments(value, {[], [], 0, 0}, budget)

  defp decode_segments(value, {parts, segments, source_at, decoded_at} = acc, budget) do
    case Regex.run(@entity, value, offset: source_at, return: :index) do
      [{start, length}] ->
        with {:ok, {parts, segments, _source_at, decoded_at}, budget} <-
               literal_segment_result(value, start, acc, budget),
             {:ok, budget} <- Budget.charge(budget, Budget.cost(:segment), facts: 1) do
          after_entity = start + length
          lookahead_reservation = 256 + 32 * (byte_size(value) - after_entity) + length

          with {:ok, budget} <- Budget.reserve(budget, lookahead_reservation) do
            entity = binary_part(value, start, length)

            next =
              if after_entity < byte_size(value),
                do: String.first(remaining(value, after_entity)),
                else: ""

            with {:ok, decoded, budget} <- decode_result(entity <> next, budget),
                 {:ok, budget} <- Budget.release(budget, lookahead_reservation) do
              decoded = binary_part(decoded, 0, byte_size(decoded) - byte_size(next))
              segment = {decoded_at, byte_size(decoded), start, length}

              decode_segments(
                value,
                {[parts, decoded], [segment | segments], after_entity,
                 decoded_at + byte_size(decoded)},
                budget
              )
            end
          end
        end

      nil ->
        with {:ok, {parts, segments, _, _}, budget} <-
               literal_segment_result(
                 value,
                 byte_size(value),
                 {parts, segments, source_at, decoded_at},
                 budget
               ) do
          reservation =
            Budget.cost(:binary) + byte_size(value) * 3 +
              Budget.cost(:list_cell, length(segments))

          with {:ok, budget} <- Budget.reserve(budget, reservation) do
            decoded = IO.iodata_to_binary(parts)
            result = {decoded, Enum.reverse(segments)}

            with {:ok, budget} <-
                   Budget.settle(budget, reservation, Budget.cost(:binary) + byte_size(decoded)),
                 do: {:ok, result, budget}
          end
        end
    end
  end

  defp literal_segment_result(value, finish, {parts, segments, source_at, decoded_at}, budget) do
    length = finish - source_at

    with {:ok, budget} <- Budget.charge(budget, Budget.cost(:segment) + min(length, 64), facts: 1) do
      literal = binary_part(value, source_at, length)
      segment = {decoded_at, length, source_at, length}
      {:ok, {[parts, literal], [segment | segments], finish, decoded_at + length}, budget}
    end
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

  @doc false
  def active_attribute_name(attr, :html), do: attr.name

  def active_attribute_name(attr, :xml) do
    cond do
      Map.get(attr, :namespace_uri) == nil and lowercase_ascii?(attr.name) ->
        attr.name

      Map.get(attr, :namespace_uri) == "http://www.w3.org/1999/xlink" and attr.name == "href" ->
        "xlink:href"

      true ->
        nil
    end
  end

  @doc false
  def active_attributes(tag, kind \\ nil) do
    kind = active_attribute_mode(tag, kind)

    if kind == :html do
      Enum.uniq_by(tag.attributes, & &1.name)
    else
      Enum.flat_map(tag.attributes, &active_xml_attribute/1)
    end
  end

  defp active_xml_attribute(attr) do
    case active_attribute_name(attr, :xml) do
      nil -> []
      name when name == attr.name -> [attr]
      name -> [%{attr | name: name}]
    end
  end

  @doc false
  def active_attribute(tag, name, kind \\ nil) do
    kind = active_attribute_mode(tag, kind)
    Enum.find(tag.attributes, &(active_attribute_name(&1, kind) == name))
  end

  defp active_attribute_mode(tag, kind) do
    cond do
      tag[:header?] -> :html
      kind != nil -> kind
      Map.has_key?(tag, :namespace_uri) -> :xml
      true -> :html
    end
  end

  defp lowercase_ascii?(<<>>), do: true
  defp lowercase_ascii?(<<char, _rest::binary>>) when char in ?A..?Z, do: false
  defp lowercase_ascii?(<<_char, rest::binary>>), do: lowercase_ascii?(rest)

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
         true <- byte_size(name) == 14 and String.downcase(name, :ascii) == "xml-stylesheet",
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

    if byte_size(name) == 14 and String.downcase(name, :ascii) == "xml-stylesheet",
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

  defp take_pi_name(source, offset, size, <<>>) do
    finish = pi_name_end(source, offset, size)
    {binary_part(source, offset, finish - offset), finish}
  end

  defp pi_name_end(_source, offset, size) when offset >= size, do: offset

  defp pi_name_end(source, offset, size) do
    if :binary.at(source, offset) in @pi_stop,
      do: offset,
      else: pi_name_end(source, offset + 1, size)
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
