defmodule Crawler.Analysis.Lexical do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.Analysis.Limits
  alias Crawler.Analysis.SourceRegion
  alias Crawler.HTMLReferences
  alias Crawler.HTMLRefresh
  alias Crawler.HTMLSpans
  alias Crawler.HTTP.DocumentHeaders
  alias Crawler.ImportMap.JSON
  alias Crawler.MediaType
  alias Crawler.Parser.CssParser
  alias Crawler.Parser.JsParser
  alias Crawler.Parser.SourceMap
  alias Crawler.Parser.SpeculationRules
  alias Crawler.Parser.Srcset
  alias Crawler.XMLSpans

  def run(source, opts, limits, budget) do
    state = %{
      regions: %{},
      next: 0,
      bytes: 0,
      scans: %{},
      limits: limits,
      opts: opts,
      budget: budget
    }

    with {:ok, budget} <- metadata_budget(opts, limits, state.budget),
         {:ok, root, state} <-
           region(source, kind(opts), nil, nil, nil, %{}, 0, %{state | budget: budget}) do
      {:ok, root, state.regions, %{scans: state.scans, regions: state.next, bytes: state.bytes},
       state.budget}
    else
      {:error, reason, _budget} -> {:error, reason}
      error -> error
    end
  end

  defp metadata_budget(opts, limits, budget) do
    headers = opts[:headers] || []

    bytes =
      Enum.reduce(headers, 0, fn
        {name, value}, acc when is_binary(value) ->
          acc + byte_size(value) + if(is_binary(name), do: byte_size(name), else: 0)

        _header, acc ->
          acc
      end)

    with :ok <- Limits.check(length(headers), limits.max_facts, :headers),
         :ok <- Limits.check(bytes, limits.max_total_bytes, :header_bytes),
         do: Crawler.Analysis.adopt(budget, headers)
  end

  def kind(opts) do
    cond do
      opts[:fetch_kind] in [:manifest, :speculation_rules, :source_map] ->
        :json

      MediaType.css?(opts[:content_type]) ->
        :css

      MediaType.javascript?(opts[:content_type]) ->
        {:javascript, opts[:javascript_goal] || :module}

      true ->
        MediaType.document_mode(opts[:content_type]) || :html
    end
  end

  defp region(source, kind, parent, span, mapping, metadata, depth, state) do
    with :ok <- Limits.check(byte_size(source), state.limits.max_bytes, :source_bytes),
         {:ok, budget} <- Budget.charge(state.budget, Budget.cost(:region), regions: 1),
         :ok <- Limits.check(state.next + 1, state.limits.max_regions, :source_regions),
         :ok <- Limits.check(depth, state.limits.max_depth, :source_depth),
         {:ok, facts, budget} <-
           scan(source, kind, Map.put(metadata, :root?, parent == nil), %{state | budget: budget}) do
      id = state.next

      item = %SourceRegion{
        id: id,
        source: source,
        kind: kind,
        parent: parent,
        span: span,
        mapping: mapping,
        metadata: metadata,
        facts: facts
      }

      scans = Map.update(state.scans, kind, 1, &(&1 + 1))

      state = %{
        state
        | budget: budget,
          next: id + 1,
          bytes: state.bytes + byte_size(source),
          scans: scans,
          regions: Map.put(state.regions, id, item)
      }

      with {:ok, item, state} <- children(item, depth, state) do
        {:ok, id, %{state | regions: Map.put(state.regions, id, item)}}
      end
    else
      {:error, :invalid_json, budget} ->
        with {:ok, budget} <- Budget.refund(budget, budget.retained - state.budget.retained),
             do: {:error, :invalid_json, budget}

      {:error, reason, _budget} ->
        {:error, reason}

      error ->
        error
    end
  end

  defp scan(source, :html, metadata, state) do
    with {:ok, headers, budget} <- header_tags(metadata, state),
         {:ok, tags, budget} <- HTMLSpans.tags_result(source, [], budget),
         {:ok, budget} <- Budget.charge(budget, Budget.cost(:list_cell, length(headers))) do
      {:ok, %{tags: headers ++ tags, instructions: []}, budget}
    end
  end

  defp scan(source, :xml, metadata, state) do
    with {:ok, facts, budget} <-
           XMLSpans.analyze_result(
             source,
             [
               content_type: state.opts[:content_type],
               document_text: true,
               max_bytes: state.limits.max_bytes,
               max_depth: state.limits.max_xml_depth,
               max_attributes: state.limits.max_xml_attributes,
               max_tokens: state.limits.max_xml_tokens
             ],
             state.budget
           ) do
      if MediaType.xhtml?(state.opts[:content_type]) do
        with {:ok, headers, budget} <- header_tags(metadata, %{state | budget: budget}),
             {:ok, budget} <- Budget.charge(budget, Budget.cost(:list_cell, length(headers))),
             do: {:ok, %{facts | tags: headers ++ facts.tags}, budget}
      else
        {:ok, facts, budget}
      end
    end
  end

  defp scan(source, {:javascript, goal}, _metadata, state) when goal in [:module, :script] do
    with {:ok, scan, budget} <- JsParser.Scanner.scan_result(source, goal, state.budget),
         {:ok, notes, budget} <- SourceMap.lexical_notes_result(source, scan, budget),
         do: {:ok, %{scan: scan, source_map_notes: notes}, budget}
  end

  defp scan(_source, {:javascript, _goal}, _metadata, _state), do: {:error, :invalid_script_goal}

  defp scan(source, :css, metadata, state) do
    with {:ok, facts, budget} <-
           CssParser.Scanner.analyze_result(
             source,
             [mode: Map.get(metadata, :css_mode, :stylesheet)],
             state.budget
           ),
         {:ok, notes, budget} <- SourceMap.lexical_notes_result(source, facts, budget),
         do: {:ok, Map.put(facts, :source_map_notes, notes), budget}
  end

  defp scan(source, kind, _metadata, state)
       when kind in [:json, :import_map, :speculation_rules, :source_map] do
    case JSON.decode_located_result(source, state.budget) do
      {:error, {:limit, key}, budget}
      when key in [
             :max_input_bytes,
             :max_depth,
             :max_tokens,
             :max_string_bytes,
             :max_number_bytes
           ] ->
        {:error, {:limit, {:json, key}}, budget}

      result ->
        result
    end
  end

  defp scan(source, :attribute, metadata, state) do
    case metadata.name do
      name when name in ["srcset", "imagesrcset"] ->
        Srcset.spans_result(source, state.budget)

      "content" ->
        scratch = byte_size(source) + Budget.cost(:token)

        with {:ok, budget} <- Budget.reserve(state.budget, scratch) do
          facts =
            case HTMLRefresh.target(source) do
              nil -> []
              %{url: url, span: {at, len}} -> [{at, len, url}]
            end

          with {:ok, budget} <-
                 Budget.charge(budget, Budget.cost(:token, length(facts)), facts: length(facts)),
               {:ok, budget} <- Budget.release(budget, scratch),
               do: {:ok, facts, budget}
        end

      _name ->
        with {:ok, budget} <- Budget.charge(state.budget, Budget.cost(:token), facts: 1),
             do: {:ok, [{0, byte_size(source), source}], budget}
    end
  end

  defp header_tags(%{root?: true}, state) do
    headers = state.opts[:headers] || []

    bytes =
      Enum.reduce(headers, 0, fn
        {name, value}, acc when is_binary(value) ->
          acc + byte_size(value) + if(is_binary(name), do: byte_size(name), else: 0)

        _header, acc ->
          acc
      end)

    with :ok <- Limits.check(length(headers), state.limits.max_facts, :headers),
         :ok <- Limits.check(bytes, state.limits.max_total_bytes, :header_bytes),
         {:ok, elements, budget} <- DocumentHeaders.elements_result(headers, state.budget),
         {:ok, rules, budget} <- SpeculationRules.header_urls_result(headers, budget),
         {:ok, budget} <- Budget.charge(budget, Budget.cost(:token, length(rules))) do
      elements =
        elements ++
          Enum.map(rules, &{"link", [{"href", &1}, {"crawler-speculation-rules", "true"}], []})

      elements
      |> Enum.reduce_while({:ok, [], budget, 0}, fn {name, attrs, _children},
                                                    {:ok, tags, budget, index} ->
        with {:ok, budget} <-
               Budget.charge(
                 budget,
                 Budget.cost(:tag) + Budget.cost(:attribute, length(attrs) + 1),
                 facts: length(attrs) + 2
               ) do
          attrs =
            Enum.map(attrs ++ [{"crawler-from-header", "true"}], fn {name, value} ->
              %{
                name: name,
                decoded: value,
                span: nil,
                value_span: nil,
                value: value,
                namespace_uri: nil
              }
            end)

          tag = %{
            name: name,
            attributes: attrs,
            span: {-index - 1, 0},
            namespace: :html,
            closing?: false,
            in_template?: false,
            in_shadow_root?: false,
            self_closing?: true,
            content_span: nil,
            xml_base: nil,
            header?: true
          }

          {:cont, {:ok, [tag | tags], budget, index + 1}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, tags, budget, _index} -> {:ok, Enum.reverse(tags), budget}
        error -> error
      end
    end
  end

  defp header_tags(_metadata, state), do: {:ok, [], state.budget}

  defp children(%{kind: kind} = item, depth, state) when kind in [:html, :xml] do
    tags = Enum.reject(item.facts.tags, &(&1.closing? or &1.in_template?))

    Enum.reduce_while(tags, {:ok, item, state}, fn tag, {:ok, item, state} ->
      case tag_children(item, tag, depth, state) do
        {:ok, ids, state} -> {:cont, {:ok, %{item | children: [ids | item.children]}, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, item, state} ->
        {:ok, %{item | children: item.children |> Enum.reverse() |> List.flatten()}, state}

      error ->
        error
    end
  end

  defp children(%{kind: kind} = item, depth, state)
       when kind == :css or elem(kind, 0) == :javascript do
    notes = Enum.filter(item.facts.source_map_notes, &(&1.kind == :mapping))

    result =
      if item.parent == nil,
        do: SourceMap.header_reference_result(state.opts, state.budget),
        else: {:ok, nil, state.budget}

    with {:ok, header, budget} <- result do
      source_map_children(item, depth, %{state | budget: budget}, notes, header)
    end
  end

  defp children(item, _depth, state), do: {:ok, item, state}

  defp source_map_children(item, depth, state, notes, header) do
    notes =
      if is_binary(header) do
        note = List.last(notes)

        [
          %{
            raw: header,
            at: if(note, do: note.at, else: byte_size(item.source)),
            len: if(note, do: note.len, else: 0),
            header?: note == nil
          }
        ]
      else
        Enum.map(notes, &Map.put(&1, :header?, false))
      end

    item = %{item | facts: Map.put(item.facts, :source_map_urls, Enum.map(notes, & &1.raw))}

    Enum.reduce_while(notes, {:ok, item, state}, fn note, {:ok, item, state} ->
      case source_map_child(note, item, depth, state) do
        {:ok, id, state} ->
          {:cont, {:ok, %{item | children: item.children ++ [id]}, state}}

        {:error, :invalid_json, budget} ->
          with {:ok, budget} <- Budget.refund(budget, budget.retained - state.budget.retained) do
            {:cont, {:ok, item, %{state | budget: budget}}}
          else
            error -> {:halt, error}
          end

        {:skip, budget} ->
          {:cont, {:ok, item, %{state | budget: budget}}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp source_map_child(note, item, depth, state) do
    case SourceMap.decode_data_result(note.raw, state.budget) do
      {:ok, payload, meta, encoding, budget} ->
        metadata = %{
          data_url: note.raw,
          header?: note.header?,
          directive_kind: if(item.kind == :css, do: :css, else: :javascript)
        }

        region(
          payload,
          :source_map,
          item.id,
          {note.at, note.len},
          {:data, meta, encoding},
          metadata,
          depth + 1,
          %{state | budget: budget}
        )

      result ->
        result
    end
  end

  defp tag_children(item, tag, depth, state) do
    hold = Crawler.Analysis.policy_scratch(tag)

    with {:ok, budget} <- Budget.reserve(state.budget, hold),
         {:ok, budget} <-
           Budget.charge(
             budget,
             Budget.cost(:tag) + Budget.cost(:list_cell, 4 * length(tag.attributes))
           ) do
      attrs = HTMLSpans.active_attributes(tag, item.kind)
      tag = Map.put(tag, :active_attributes, Enum.map(attrs, &{&1.name, &1.decoded}))

      with {:ok, attr_ids, state} <-
             attr_children(item, tag, attrs, depth, %{state | budget: budget}),
           {:ok, text_ids, state} <- text_child(item, tag, depth, state),
           {:ok, budget} <- Budget.release(state.budget, hold) do
        {:ok, attr_ids ++ text_ids, %{state | budget: budget}}
      end
    end
  end

  defp attr_children(item, tag, attrs, depth, state) do
    Enum.reduce_while(attrs, {:ok, [], state}, fn attr, {:ok, ids, state} ->
      kind = attribute_kind(tag, attr)

      if kind == nil or (not is_tuple(attr.value_span) and not tag[:header?]) do
        {:cont, {:ok, ids, state}}
      else
        attribute_region(item, tag, attr, kind, depth, ids, state)
      end
    end)
    |> case do
      {:ok, ids, state} -> {:ok, Enum.reverse(ids), state}
      error -> error
    end
  end

  defp attribute_region(item, tag, attr, kind, depth, ids, state) do
    with {:ok, _check} <- Budget.count(state.budget, :regions),
         {:ok, source, mapping, budget} <- attribute_source(item, attr, state.budget) do
      state = %{state | budget: budget}
      metadata = %{tag: tag, name: attr.name, attribute: attr, css_mode: :declarations}

      case region(source, kind, item.id, attr.value_span, mapping, metadata, depth + 1, state) do
        {:ok, id, state} -> {:cont, {:ok, [id | ids], state}}
        error -> {:halt, error}
      end
    else
      error -> {:halt, error}
    end
  end

  defp attribute_kind(tag, %{name: "srcdoc"}) do
    if tag.name == "iframe" and tag.namespace == :html, do: :html, else: :attribute
  end

  defp attribute_kind(_tag, %{name: name}) do
    cond do
      name == "style" or HTMLReferences.presentation_attribute?(name) ->
        :css

      name in ~w(href xlink:href src srcset imagesrcset content data poster background) ->
        :attribute

      true ->
        nil
    end
  end

  defp attribute_source(_item, %{span: nil} = attr, budget), do: {:ok, attr.decoded, nil, budget}

  defp attribute_source(%{kind: :html, source: source}, attr, budget) do
    raw = HTMLSpans.slice(source, attr.value_span)

    with {:ok, {decoded, segments}, budget} <- HTMLSpans.decode_with_spans_result(raw, budget),
         {:ok, budget} <- Budget.charge(budget, Budget.cost(:segment, length(segments))) do
      {start, _length} = attr.value_span

      mapping =
        Enum.map(segments, fn {at, len, source_at, source_len} ->
          %{decoded_span: {at, len}, span: {start + source_at, source_len}, kind: :attribute}
        end)

      {:ok, decoded, mapping, budget}
    end
  end

  defp attribute_source(%{kind: :xml}, attr, budget) do
    with {:ok, budget} <- Budget.charge(budget, Budget.cost(:segment, length(attr.segments))) do
      mapping =
        Enum.map(attr.segments, fn {at, len, source_at, source_len} ->
          %{decoded_span: {at, len}, span: {source_at, source_len}, kind: :attribute}
        end)

      {:ok, attr.decoded, mapping, budget}
    end
  end

  defp text_child(item, tag, depth, state) do
    kind = text_kind(tag)

    if kind == nil or tag.content_span == nil do
      {:ok, [], state}
    else
      {source, mapping} = text_source(item, tag)
      metadata = %{tag: tag, inline_source: true, css_mode: :stylesheet}

      case region(source, kind, item.id, tag.content_span, mapping, metadata, depth + 1, state) do
        {:ok, id, state} ->
          {:ok, [id], state}

        {:error, :invalid_json, budget} when kind in [:import_map, :speculation_rules] ->
          {:ok, [], %{state | budget: budget}}

        error ->
          error
      end
    end
  end

  defp text_kind(%{namespace: namespace} = tag) when namespace in [:html, :svg] do
    attrs = tag.active_attributes

    cond do
      tag.name == "style" and HTMLReferences.css_style_element?(attrs) ->
        :css

      tag.name == "script" and namespace == :html and HTMLReferences.import_map?(attrs) ->
        :import_map

      tag.name == "script" and namespace == :html and HTMLReferences.speculation_rules?(attrs) and
          HTMLReferences.attribute(attrs, "src") == nil ->
        :speculation_rules

      tag.name == "script" and inline_script?(tag, attrs) ->
        {:javascript, HTMLReferences.script_goal(attrs)}

      true ->
        nil
    end
  end

  defp text_kind(_tag), do: nil

  defp inline_script?(%{namespace: :html}, attrs),
    do: HTMLReferences.script_source(attrs) == :inline

  defp inline_script?(%{namespace: :svg}, attrs),
    do: HTMLReferences.svg_script_source(attrs) == :inline

  defp text_source(%{kind: :html, source: source}, tag),
    do: {HTMLSpans.slice(source, tag.content_span), :identity}

  defp text_source(%{kind: :xml}, tag), do: {tag.content, tag.content_segments}
end
