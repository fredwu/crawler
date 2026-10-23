defmodule Crawler.Analysis.Render do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.Analysis.Limits
  alias Crawler.HTMLSpans
  alias Crawler.Parser.SourceMap
  alias Crawler.URL

  def run(analysis, occurrences, resolver, opts) when is_function(resolver, 1) do
    with {:ok, occurrences, budget} <- render_input(analysis, occurrences) do
      state = %{
        analysis: analysis,
        edits: %{},
        changed: MapSet.new(),
        local: MapSet.new(),
        selections: %{},
        count: 0,
        options: Map.new(opts),
        batches: 0,
        budget: budget,
        quote_mappings: %{},
        quote_mapping_bytes: 0
      }

      with :ok <-
             Limits.check(length(occurrences), analysis.limits.max_occurrences, :occurrences),
           :ok <- compatible_interpretations(analysis, occurrences),
           {:ok, state} <- resolve_all(occurrences, resolver, state),
           {:ok, state} <- structural_edits(occurrences, state),
           {:ok, edits, state} <- region_edits(analysis.root, state),
           {:ok, body, state} <- batch(analysis.regions[analysis.root].source, edits, state),
           {:ok, budget} <- Budget.release(state.budget, state.quote_mapping_bytes) do
        {:ok, body,
         %{batches: state.batches + 1, edits: state.count, budget: Budget.snapshot(budget)}}
      end
    end
  end

  defp render_input(analysis, %{occurrences: refs} = collection) when is_list(refs) do
    with {:ok, budget} <- Crawler.Analysis.continuation_budget(analysis, collection),
         true <-
           budget.counts.occurrences >= length(refs) || {:error, :invalid_budget_continuation},
         do: {:ok, refs, budget}
  end

  defp render_input(analysis, refs) when is_list(refs) do
    with {:ok, budget} <- Budget.count(analysis.budget, :occurrences, length(refs)),
         {:ok, budget} <- Crawler.Analysis.adopt(budget, refs),
         do: {:ok, refs, budget}
  end

  defp render_input(_analysis, _refs), do: {:error, :invalid_occurrences}

  defp compatible_interpretations(%{mode: :json}, occurrences) do
    roles = occurrences |> Enum.map(& &1.source_role) |> Enum.uniq()

    if length(roles) <= 1 and
         Enum.all?(roles, &(&1 in [:manifest, :speculation_rules, :source_map])),
       do: :ok,
       else: {:error, :incompatible_interpretations}
  end

  defp compatible_interpretations(_analysis, _occurrences), do: :ok

  defp resolve_all(occurrences, resolver, state) do
    Enum.reduce_while(occurrences, {:ok, state}, fn occurrence, {:ok, state} ->
      resolve_occurrence(occurrence, resolver, state)
    end)
  end

  defp resolve_occurrence(occurrence, resolver, state) do
    if valid_occurrence?(occurrence, state.analysis) do
      case resolved_edit(occurrence, resolver.(occurrence), state) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    else
      {:halt, {:error, :invalid_occurrence}}
    end
  end

  defp valid_occurrence?(occurrence, analysis) do
    if occurrence.source_revision != analysis.revision or occurrence.source_mode != analysis.mode do
      false
    else
      valid_region_occurrence?(occurrence, analysis)
    end
  end

  defp valid_region_occurrence?(occurrence, analysis) do
    case analysis.regions[occurrence.region] do
      nil ->
        false

      region ->
        case occurrence.span do
          nil ->
            true

          {at, len} ->
            is_integer(at) and at >= 0 and is_integer(len) and len >= 0 and
              at + len <= byte_size(region.source)

          _other ->
            false
        end
    end
  end

  defp resolved_edit(occurrence, :keep, state), do: selection(occurrence, :keep, state)
  defp resolved_edit(_occurrence, {:error, reason}, _state), do: {:error, reason}
  defp resolved_edit(%{target: nil}, {:local, _path}, _state), do: {:error, :unbound_local_target}

  defp resolved_edit(occurrence, {:local, path}, state) when is_binary(path) do
    resolved_target(occurrence, path, true, state)
  end

  defp resolved_edit(occurrence, {:online, url}, state) when is_binary(url) do
    resolved_target(occurrence, url, false, state)
  end

  defp resolved_edit(_occurrence, _result, _state), do: {:error, :invalid_resolution}

  defp resolved_target(occurrence, value, local?, state) do
    hold = 512 * (byte_size(value) + byte_size(occurrence.fragment || "") + 1) + 512

    with {:ok, state} <- selection(occurrence, if(local?, do: :local, else: :online), state),
         {:ok, budget} <- Budget.reserve(state.budget, hold) do
      result = if local?, do: {:ok, value}, else: safe_online(value)

      with {:ok, value} <- result do
        value = with_fragment(value, occurrence.fragment)

        with {:ok, budget} <-
               Budget.settle(budget, hold, byte_size(value) + Budget.cost(:binary)),
             do: change(occurrence, value, local?, %{state | budget: budget})
      end
    end
  end

  defp selection(occurrence, kind, state) do
    with {:ok, budget} <- Budget.charge(state.budget, Budget.cost(:map_entry)) do
      {:ok, %{state | budget: budget, selections: Map.put(state.selections, occurrence.id, kind)}}
    end
  end

  defp change(%{span: nil}, _value, _local, state), do: {:ok, state}

  defp change(occurrence, value, local?, state) do
    if not String.valid?(value) do
      {:error, :invalid_resolution}
    else
      change_valid(occurrence, value, local?, state)
    end
  end

  defp change_valid(occurrence, value, local?, state) do
    if value == occurrence.value do
      {:ok, state}
    else
      hold = 32 * byte_size(value) + 512

      with {:ok, budget} <- Budget.reserve(state.budget, hold),
           {:ok, span, replacement, state} <-
             encoded_replacement(occurrence, value, %{state | budget: budget}),
           {:ok, budget} <-
             Budget.settle(state.budget, hold, byte_size(replacement) + Budget.cost(:binary)),
           {:ok, state} <- add(occurrence.region, {span, replacement}, %{state | budget: budget}) do
        state = %{state | changed: MapSet.put(state.changed, occurrence.id)}

        state =
          if local?, do: %{state | local: MapSet.put(state.local, occurrence.id)}, else: state

        {:ok, state}
      end
    end
  end

  defp encoded_replacement(%{encoding: {:css, quote, closed?}} = occurrence, value, state)
       when quote in ["\"", "'"] do
    region = state.analysis.regions[occurrence.region]

    if is_list(region.mapping) and region.metadata[:attribute] do
      css_attribute_replacement(region, occurrence.span, value, quote, closed?, state)
    else
      {:ok, occurrence.span, encode(value, occurrence.encoding, region.source), state}
    end
  end

  defp encoded_replacement(occurrence, value, state),
    do:
      {:ok, occurrence.span,
       encode(value, occurrence.encoding, state.analysis.regions[occurrence.region].source),
       state}

  defp css_attribute_replacement(region, {at, length}, value, quote, closed?, state) do
    suffix = if closed?, do: 1, else: 0

    valid =
      length >= 1 + suffix and binary_part(region.source, at, 1) == quote and
        (not closed? or binary_part(region.source, at + length - 1, 1) == quote)

    if valid do
      parent = state.analysis.regions[region.parent]

      with {:ok, index, state} <- quote_mapping_index(region, state),
           {:ok, opening} <- quote_source_span(index, at, byte_size(parent.source)),
           {:ok, closing} <-
             if(closed?,
               do: quote_source_span(index, at + length - 1, byte_size(parent.source)),
               else: {:ok, nil}
             ),
           {:ok, state} <-
             normalize_quote_edits(region.parent, parent.source, opening, closing, state) do
        {:ok, {at + 1, length - 1 - suffix}, css_escape(value, quote), state}
      end
    else
      {:error, :invalid_css_quote_span}
    end
  end

  defp quote_mapping_index(region, state) do
    case Map.fetch(state.quote_mappings, region.id) do
      {:ok, index} ->
        {:ok, index, state}

      :error ->
        bytes = Budget.cost(:context) + 8 * length(region.mapping)

        with {:ok, budget} <- Budget.reserve(state.budget, bytes) do
          index = List.to_tuple(region.mapping)

          {:ok, index,
           %{
             state
             | budget: budget,
               quote_mappings: Map.put(state.quote_mappings, region.id, index),
               quote_mapping_bytes: state.quote_mapping_bytes + bytes
           }}
        end
    end
  end

  defp quote_source_span(index, offset, size),
    do: quote_source_span(index, offset, size, 0, tuple_size(index) - 1)

  defp quote_source_span(_index, _offset, _size, left, right) when left > right,
    do: {:error, :unmapped_source_span}

  defp quote_source_span(index, offset, size, left, right) do
    middle = div(left + right, 2)
    %{decoded_span: {at, length}, span: {source_at, source_length}} = elem(index, middle)

    cond do
      offset < at ->
        quote_source_span(index, offset, size, left, middle - 1)

      offset >= at + length ->
        quote_source_span(index, offset, size, middle + 1, right)

      source_at < 0 or source_length < 0 or source_at + source_length > size ->
        {:error, :unmapped_source_span}

      length == source_length ->
        {:ok, {source_at + offset - at, 1}}

      length == 1 ->
        {:ok, {source_at, source_length}}

      true ->
        {:error, :split_entity_span}
    end
  end

  defp normalize_quote_edits(parent, source, {_, length} = opening, closing, state) do
    hold = 512 + 256 * length

    with {:ok, budget} <- Budget.reserve(state.budget, hold) do
      quote = source |> HTMLSpans.slice(opening) |> Crawler.Parser.CssParser.Value.source_quote()

      if quote == "" do
        {:error, :invalid_css_quote_span}
      else
        edits =
          Enum.reject([opening, closing], &(&1 == nil or HTMLSpans.slice(source, &1) == quote))

        if edits == [] do
          with {:ok, budget} <- Budget.release(budget, hold), do: {:ok, %{state | budget: budget}}
        else
          with {:ok, budget} <-
                 Budget.settle(budget, hold, byte_size(quote) + Budget.cost(:binary)) do
            add_quote_spans(edits, parent, quote, state, budget)
          end
        end
      end
    end
  end

  defp add_quote_spans(edits, parent, quote, state, budget) do
    Enum.reduce_while(edits, {:ok, %{state | budget: budget}}, fn span, {:ok, state} ->
      case add(parent, {span, quote}, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  def safe_online(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, URI.to_string(%{uri | userinfo: nil})}

      _uri ->
        {:error, :invalid_online_target}
    end
  rescue
    ArgumentError -> {:error, :invalid_online_target}
  end

  defp with_fragment(path, nil), do: path

  defp with_fragment(path, fragment) do
    if String.contains?(path, "#"), do: path, else: path <> "#" <> fragment
  end

  defp structural_edits([], state), do: {:ok, state}

  defp structural_edits(occurrences, state) do
    attrs =
      Enum.reduce(state.analysis.regions, 0, fn {_id, region}, count ->
        if region.kind in [:html, :xml],
          do: count + Enum.reduce(region.facts.tags, 0, &(length(&1.attributes) + &2)),
          else: count
      end)

    entries =
      Enum.reduce(
        occurrences,
        attrs + length(occurrences),
        &(length(List.wrap(&1.integrity)) + &2)
      )

    hold = Budget.cost(:edit, entries) * 3

    with {:ok, budget} <- Budget.reserve(state.budget, hold),
         {:ok, state} <- structural_edits_reserved(occurrences, %{state | budget: budget}),
         {:ok, budget} <- Budget.release(state.budget, hold),
         do: {:ok, %{state | budget: budget}}
  end

  defp structural_edits_reserved(occurrences, state) do
    integrity =
      for occurrence <- occurrences,
          MapSet.member?(state.local, occurrence.id),
          entry <- List.wrap(occurrence.integrity),
          do: entry

    xhtml? = Crawler.MediaType.xhtml?(state.analysis.source_options[:content_type])

    with {:ok, state} <-
           add_all(
             Enum.map(Enum.uniq(integrity), fn {region, span} -> {region, {span, ""}} end),
             state
           ),
         {:ok, ownership, graph, state} <- document_graph(state),
         {:ok, documents, state} <-
           selected_documents(occurrences, ownership, graph, xhtml?, state),
         {:ok, dependencies, state} <- affected_documents(graph, documents, state),
         {:ok, owners, affected, state} <- selected_source_roots(occurrences, state),
         {:ok, state} <-
           preserve_kept_destinations(occurrences, ownership, dependencies, affected, state),
         {:ok, state} <- add_all(Enum.uniq(owners), state) do
      bases =
        state.analysis.regions
        |> Map.values()
        |> Enum.flat_map(fn region ->
          if Map.get(documents, region.id, false) do
            for tag <- region.facts.tags,
                not tag.closing?,
                not tag.in_template?,
                attr <- tag.attributes,
                neutralized_base?(region, tag, attr, xhtml?),
                do: {region.id, {attr.span, ""}}
          else
            []
          end
        end)

      add_all(bases, state)
    end
  end

  defp document_graph(state) do
    with {:ok, ownership, graph, state} <-
           document_graph(state.analysis.root, nil, %{}, [], state),
         {:ok, budget} <- Budget.charge(state.budget, Budget.cost(:list_cell, length(graph))) do
      {:ok, ownership, Enum.reverse(graph), %{state | budget: budget}}
    end
  end

  defp document_graph(id, parent, ownership, graph, state) do
    region = state.analysis.regions[id]
    document? = region.kind in [:html, :xml]

    bytes =
      Budget.cost(:map_entry) +
        if(document?, do: Budget.cost(:context) + Budget.cost(:list_cell), else: 0)

    with {:ok, budget} <- Budget.charge(state.budget, bytes) do
      graph = if document?, do: [{id, parent} | graph], else: graph
      owner = if document?, do: id, else: parent
      ownership = Map.put(ownership, id, owner)

      Enum.reduce_while(
        region.children,
        {:ok, ownership, graph, %{state | budget: budget}},
        fn child, {:ok, ownership, graph, state} ->
          case document_graph(child, owner, ownership, graph, state) do
            {:ok, ownership, graph, state} -> {:cont, {:ok, ownership, graph, state}}
            error -> {:halt, error}
          end
        end
      )
    end
  end

  defp selected_documents(occurrences, ownership, graph, xhtml?, state) do
    if Map.get(state.options, :neutralize_base, true) do
      with {:ok, local, changed, state} <- selected_document_ids(occurrences, ownership, state),
           {:ok, local, state} <- local_document_ancestors(graph, local, state) do
        select_document_bases(graph, local, changed, xhtml?, state)
      end
    else
      {:ok, %{}, state}
    end
  end

  defp select_document_bases(graph, local, changed, xhtml?, state) do
    Enum.reduce_while(graph, {:ok, %{}, state}, fn {id, _parent}, {:ok, documents, state} ->
      if MapSet.member?(local, id) or MapSet.member?(changed, id) do
        with {:ok, budget} <- Budget.charge(state.budget, Budget.cost(:map_entry)) do
          base? = document_base?(state.analysis.regions[id], xhtml?)
          {:cont, {:ok, Map.put(documents, id, base?), %{state | budget: budget}}}
        else
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, documents, state}}
      end
    end)
  end

  defp selected_document_ids(occurrences, ownership, state) do
    Enum.reduce_while(occurrences, {:ok, MapSet.new(), MapSet.new(), state}, fn occurrence,
                                                                                {:ok, local,
                                                                                 changed,
                                                                                 state} ->
      id = ownership[occurrence.region]
      local? = occurrence.span != nil and state.selections[occurrence.id] == :local
      changed? = MapSet.member?(state.changed, occurrence.id)

      with {:ok, local, state} <- document_member(local, id, local?, state),
           {:ok, changed, state} <- document_member(changed, id, changed?, state) do
        {:cont, {:ok, local, changed, state}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp document_member(set, id, selected?, state) do
    if selected? and id != nil and not MapSet.member?(set, id) do
      with {:ok, budget} <- Budget.charge(state.budget, Budget.cost(:map_entry)),
           do: {:ok, MapSet.put(set, id), %{state | budget: budget}}
    else
      {:ok, set, state}
    end
  end

  defp local_document_ancestors(graph, local, state) do
    with {:ok, budget} <- Budget.charge(state.budget, Budget.cost(:list_cell, length(graph))) do
      graph
      |> Enum.reverse()
      |> Enum.reduce_while(
        {:ok, local, %{state | budget: budget}},
        fn {id, parent}, {:ok, local, state} ->
          case document_member(local, parent, MapSet.member?(local, id), state) do
            {:ok, local, state} -> {:cont, {:ok, local, state}}
            error -> {:halt, error}
          end
        end
      )
    end
  end

  defp affected_documents(graph, documents, state) do
    Enum.reduce_while(graph, {:ok, %{}, state}, fn {id, parent}, {:ok, affected, state} ->
      with {:ok, budget} <- Budget.charge(state.budget, Budget.cost(:map_entry)),
           {:ok, affected?, budget} <-
             document_dependency(id, parent, documents, affected, %{state | budget: budget}) do
        {:cont, {:ok, Map.put(affected, id, affected?), %{state | budget: budget}}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp document_dependency(id, parent, documents, affected, state) do
    cond do
      Map.get(documents, id, false) -> {:ok, true, state.budget}
      not Map.get(affected, parent, false) -> {:ok, false, state.budget}
      Map.has_key?(documents, id) -> {:ok, true, state.budget}
      true -> inherited_document(state.analysis.regions[id], state.budget)
    end
  end

  defp inherited_document(region, budget) do
    attribute =
      Enum.find_value(region.facts.tags, fn tag ->
        if not tag.closing? and not tag.in_template?,
          do: Enum.find(tag.attributes, &html_base_attribute?(tag, &1, region.kind))
      end)

    case independent_base(attribute, budget) do
      {:ok, independent?, latest} ->
        with {:ok, latest} <- Budget.refund(latest, latest.retained - budget.retained),
             do: {:ok, not independent?, latest}

      error ->
        error
    end
  end

  defp independent_base(nil, budget), do: {:ok, false, budget}

  defp independent_base(attribute, budget) do
    case URL.resolve_result(attribute.decoded, nil, budget) do
      {:ok, _url, budget} -> {:ok, true, budget}
      {:skip, budget} -> {:ok, false, budget}
      error -> error
    end
  end

  defp document_base?(region, xhtml?) do
    Enum.any?(region.facts.tags, fn tag ->
      not tag.closing? and not tag.in_template? and
        Enum.any?(tag.attributes, &neutralized_base?(region, tag, &1, xhtml?))
    end)
  end

  defp preserve_kept_destinations(occurrences, ownership, documents, affected, state) do
    Enum.reduce_while(occurrences, {:ok, state}, fn occurrence, {:ok, state} ->
      document = ownership[occurrence.region]

      affected? =
        Map.get(documents, document, false) or
          MapSet.member?(affected, {occurrence.region, occurrence.span})

      if state.selections[occurrence.id] == :keep and affected? do
        preserve_destination(occurrence, state)
      else
        {:cont, {:ok, state}}
      end
    end)
  end

  defp preserve_destination(occurrence, state) do
    case resolved_target(occurrence, occurrence.url, false, state) do
      {:ok, state} -> {:cont, {:ok, state}}
      error -> {:halt, error}
    end
  end

  defp selected_source_roots(occurrences, state) do
    occurrences
    |> Enum.group_by(& &1.region)
    |> Enum.reduce_while({:ok, [], MapSet.new(), state}, fn {id, items},
                                                            {:ok, owners, affected, state} ->
      with {:ok, locals, state} <- local_source_spans(items, state) do
        if MapSet.size(locals) > 0 do
          with {:ok, candidates, budget} <-
                 SourceMap.root_owners_result(state.analysis.regions[id].facts, state.budget),
               {:ok, owners, affected, state} <-
                 select_root_owners(candidates, id, locals, owners, affected, %{
                   state
                   | budget: budget
                 }) do
            {:cont, {:ok, owners, affected, state}}
          else
            error -> {:halt, error}
          end
        else
          {:cont, {:ok, owners, affected, state}}
        end
      else
        error -> {:halt, error}
      end
    end)
  end

  defp local_source_spans(items, state) do
    Enum.reduce_while(items, {:ok, MapSet.new(), state}, fn occurrence, {:ok, spans, state} ->
      if occurrence.source_role == :source_map and occurrence.context[:fetch_kind] == nil and
           state.selections[occurrence.id] == :local and occurrence.span != nil do
        with {:ok, budget} <- Budget.charge(state.budget, Budget.cost(:map_entry)) do
          {:cont, {:ok, MapSet.put(spans, occurrence.span), %{state | budget: budget}}}
        else
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, spans, state}}
      end
    end)
  end

  defp select_root_owners(candidates, id, locals, owners, affected, state) do
    Enum.reduce_while(candidates, {:ok, owners, affected, state}, fn {span, parents, sources},
                                                                     {:ok, owners, affected,
                                                                      state} ->
      if Enum.any?(sources, &local_source?(&1, locals)) do
        selected_root_owner(span, parents, sources, id, owners, affected, state)
      else
        {:cont, {:ok, owners, affected, state}}
      end
    end)
  end

  defp selected_root_owner(span, parents, sources, id, owners, affected, state) do
    count = length(parents) + if(span, do: 1, else: 0)
    bytes = count * (Budget.cost(:context) + Budget.cost(:list_cell))

    with {:ok, budget} <- Budget.charge(state.budget, bytes),
         {:ok, affected, state} <-
           affected_sources(sources, id, affected, %{state | budget: budget}) do
      owners = if span, do: [{id, {span, ~s("")}} | owners], else: owners

      owners =
        Enum.reduce(parents, owners, fn parent, acc -> [{id, {parent, ~s("")}} | acc] end)

      {:cont, {:ok, owners, affected, state}}
    else
      error -> {:halt, error}
    end
  end

  defp local_source?({:str, _value, at, len}, locals), do: MapSet.member?(locals, {at, len})
  defp local_source?(_value, _locals), do: false

  defp affected_sources(sources, id, affected, state) do
    Enum.reduce_while(sources, {:ok, affected, state}, fn
      {:str, _value, at, len}, {:ok, affected, state} ->
        with {:ok, budget} <- Budget.charge(state.budget, Budget.cost(:map_entry)) do
          {:cont, {:ok, MapSet.put(affected, {id, {at, len}}), %{state | budget: budget}}}
        else
          error -> {:halt, error}
        end

      _source, result ->
        {:cont, result}
    end)
  end

  defp neutralized_base?(%{kind: :html}, tag, attr, _xhtml?),
    do: html_base_attribute?(tag, attr, :html)

  defp neutralized_base?(%{kind: :xml}, tag, attr, xhtml?),
    do:
      (attr.namespace_uri == "http://www.w3.org/XML/1998/namespace" and attr.name == "base") or
        (xhtml? and html_base_attribute?(tag, attr, :xml))

  defp html_base_attribute?(tag, attr, kind),
    do:
      tag.name == "base" and tag.namespace == :html and not tag.in_shadow_root? and
        HTMLSpans.active_attribute_name(attr, kind) == "href"

  defp add_all(edits, state) do
    Enum.reduce_while(edits, {:ok, state}, fn {id, edit}, {:ok, state} ->
      case add(id, edit, state) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  defp add(id, edit, state) do
    with :ok <- Limits.check(state.count + 1, state.analysis.limits.max_edits, :edits),
         {:ok, budget} <- Budget.charge(state.budget, Budget.cost(:edit), edits: 1) do
      {:ok,
       %{
         state
         | budget: budget,
           count: state.count + 1,
           edits: Map.update(state.edits, id, [edit], &[edit | &1])
       }}
    end
  end

  defp region_edits(id, state) do
    region = state.analysis.regions[id]

    Enum.reduce_while(region.children, {:ok, Map.get(state.edits, id, []), state}, fn child,
                                                                                      {:ok, edits,
                                                                                       state} ->
      with {:ok, child_edits, state} <- region_edits(child, state),
           {:ok, mapped, state} <- parent_edits(state.analysis.regions[child], child_edits, state) do
        {:cont, {:ok, [mapped | edits], state}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, edits, state} ->
        with {:ok, budget} <-
               Budget.charge(state.budget, Budget.cost(:list_cell, edit_count(edits))),
             do: {:ok, List.flatten(edits), %{state | budget: budget}}

      error ->
        error
    end
  end

  defp edit_count([]), do: 0
  defp edit_count([head | tail]) when is_list(head), do: edit_count(head) + edit_count(tail)
  defp edit_count([_edit | tail]), do: 1 + edit_count(tail)

  defp parent_edits(_region, [], state), do: {:ok, [], state}

  defp parent_edits(%{metadata: %{name: "srcdoc"}} = region, edits, state) do
    with {:ok, source, state} <- batch(region.source, edits, state),
         {:ok, value, state} <- expanded(source, &attribute_escape/1, state, 32) do
      {:ok, [{region.span, value}], %{state | batches: state.batches + 1}}
    end
  end

  defp parent_edits(%{mapping: {:data, meta, encoding}} = region, edits, state) do
    with {:ok, source, state} <- batch(region.source, edits, state),
         {:ok, data, state} <-
           expanded(
             source,
             fn source ->
               data = SourceMap.encode_data(source, meta, encoding)

               if region.metadata.header?,
                 do:
                   directive(
                     data,
                     region.metadata.directive_kind,
                     state.analysis.regions[region.parent].source
                   ),
                 else: data
             end,
             state,
             32,
             byte_size(meta)
           ) do
      {:ok, [{region.span, data}], %{state | batches: state.batches + 1}}
    end
  end

  defp parent_edits(%{mapping: :identity, span: {offset, _length}}, edits, state) do
    with {:ok, budget} <- Budget.charge(state.budget, Budget.cost(:edit, length(edits))),
         do:
           {:ok, Enum.map(edits, fn {{at, len}, value} -> {{offset + at, len}, value} end),
            %{state | budget: budget}}
  end

  defp parent_edits(%{mapping: mapping}, edits, state) when is_list(mapping) do
    bytes = Enum.reduce(edits, 0, fn {_span, value}, n -> n + byte_size(value) end)

    hold =
      Budget.cost(:edit, length(mapping) + 4 * length(edits)) + 32 * bytes + 512 * length(edits)

    with {:ok, budget} <- Budget.reserve(state.budget, hold),
         {:ok, mapped, state} <- mapped_edits(mapping, edits, %{state | budget: budget}) do
      retained =
        Enum.reduce(mapped, Budget.cost(:edit, length(mapped)), fn {_span, value}, n ->
          n + byte_size(value) + Budget.cost(:binary)
        end)

      with {:ok, budget} <- Budget.settle(state.budget, hold, retained),
           do: {:ok, mapped, %{state | budget: budget}}
    end
  end

  defp mapped_edits(mapping, edits, state) do
    edits
    |> Enum.uniq()
    |> Enum.sort_by(fn {{at, len}, _value} -> {at, len} end)
    |> Enum.reduce_while({:ok, [], mapping}, fn {{start, _length}, _value} = edit,
                                                {:ok, mapped, remaining} ->
      remaining =
        Enum.drop_while(remaining, fn %{decoded_span: {at, len}} -> at + len < start end)

      case map_edit(remaining, edit) do
        {:ok, parts} -> {:cont, {:ok, [parts | mapped], remaining}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, mapped, _remaining} -> {:ok, List.flatten(mapped), state}
      error -> error
    end
  end

  defp map_edit(mapping, {{start, length}, value}) do
    finish = start + length

    segments =
      mapping
      |> Enum.take_while(fn %{decoded_span: {at, _len}} -> at <= finish end)
      |> Enum.filter(fn %{decoded_span: {at, len}} ->
        if length == 0,
          do: start >= at and start <= at + len,
          else: at < finish and at + len > start
      end)

    segments = if length == 0, do: Enum.take(segments, 1), else: segments

    if segments == [] do
      {:error, :unmapped_source_span}
    else
      segments
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {segment, index}, {:ok, edits} ->
        map_segment(segment, index, start, finish, value, edits)
      end)
      |> case do
        {:ok, edits} -> {:ok, Enum.reverse(edits)}
        error -> error
      end
    end
  end

  defp map_segment(segment, index, start, finish, value, edits) do
    %{decoded_span: {at, len}, span: {source_at, source_len}, kind: kind} = segment
    left = max(start, at)
    right = min(finish, at + len)

    if len != source_len and (left != at or right != at + len) do
      {:halt, {:error, :split_entity_span}}
    else
      span =
        if len == source_len,
          do: {source_at + left - at, right - left},
          else: {source_at, source_len}

      replacement = if index == 0, do: mapped_escape(value, kind), else: ""
      {:cont, {:ok, [{span, replacement} | edits]}}
    end
  end

  defp batch(source, [], state) do
    with :ok <-
           Limits.check(
             byte_size(source),
             state.analysis.limits.max_output_bytes,
             :rendered_bytes
           ),
         do: {:ok, source, state}
  end

  defp batch(source, edits, state) do
    scratch = Budget.cost(:edit, length(edits)) * 3

    with {:ok, budget} <- Budget.reserve(state.budget, scratch) do
      edits = Enum.uniq(edits)

      output_size =
        Enum.reduce(edits, byte_size(source), fn {{_at, len}, value}, size ->
          size - len + byte_size(value)
        end)

      with :ok <- Limits.check(length(edits), state.analysis.limits.max_edits, :edits),
           :ok <-
             Limits.check(output_size, state.analysis.limits.max_output_bytes, :rendered_bytes),
           {:ok, budget} <- Budget.reserve(budget, max(output_size, 0) + Budget.cost(:binary)) do
        body = HTMLSpans.rewrite(source, edits)

        with {:ok, budget} <-
               Budget.settle(
                 budget,
                 output_size + Budget.cost(:binary),
                 byte_size(body) + Budget.cost(:binary)
               ),
             {:ok, budget} <- Budget.release(budget, scratch),
             do: {:ok, body, %{state | budget: budget}}
      end
    end
  rescue
    ArgumentError -> {:error, :conflicting_source_edits}
  end

  defp expanded(value, fun, state, factor, extra \\ 0) do
    hold = factor * byte_size(value) + 512 + extra

    with {:ok, budget} <- Budget.reserve(state.budget, hold) do
      result = fun.(value)

      with {:ok, budget} <- Budget.settle(budget, hold, byte_size(result) + Budget.cost(:binary)),
           do: {:ok, result, %{state | budget: budget}}
    end
  end

  defp mapped_escape(value, :attribute), do: attribute_escape(value)
  defp mapped_escape(value, :xml_text), do: xml_text_escape(value)
  defp mapped_escape(value, :xml_cdata), do: String.replace(value, "]]>", "]]]]><![CDATA[>")

  defp encode(value, :plain, _source), do: value
  defp encode(value, :xml_attribute, _source), do: attribute_escape(value)
  defp encode(value, :json, _source), do: "\"" <> string_escape(value, "\"") <> "\""

  defp encode(value, {:javascript, quote}, _source) do
    escaped = string_escape(value, quote)
    if quote == "`", do: String.replace(escaped, "${", "\\${"), else: escaped
  end

  defp encode(value, {:css, quote, closed?}, _source) do
    escaped = css_escape(value, quote)
    quote <> escaped <> if(closed?, do: quote, else: "")
  end

  defp encode(value, {:source_map, _kind, %{at: at}}, _source) when is_integer(at),
    do: annotation_url(value)

  defp encode(value, {:source_map, kind, _note}, source),
    do: directive(annotation_url(value), kind, source)

  defp directive(value, kind, source) do
    prefix = if String.ends_with?(source, "\n"), do: "", else: "\n"

    case kind do
      :javascript -> prefix <> "//# sourceMappingURL=" <> value
      :css -> prefix <> "/*# sourceMappingURL=" <> value <> " */"
    end
  end

  defp annotation_url(value) do
    URI.encode(value, fn char -> char > 32 and char not in [?*, ?<, ?>, 127] end)
  end

  defp string_escape(value, quote) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(quote, "\\" <> quote)
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
    |> String.replace("<", "\\u003c")
    |> String.replace("\u2028", "\\u2028")
    |> String.replace("\u2029", "\\u2029")
    |> escape_controls()
  end

  defp escape_controls(value) do
    for <<char::utf8 <- value>>, into: "" do
      if char < 0x20,
        do: "\\u" <> (char |> Integer.to_string(16) |> String.pad_leading(4, "0")),
        else: <<char::utf8>>
    end
  end

  defp css_escape(value, quote) do
    for <<char::utf8 <- value>>, into: "" do
      cond do
        char == ?\\ ->
          "\\\\"

        <<char::utf8>> == quote ->
          "\\" <> quote

        char < 0x20 or char in [?<, ?>] or (quote == "" and char in [32, ?(, ?), ?", ?']) ->
          "\\" <> Integer.to_string(char, 16) <> " "

        true ->
          <<char::utf8>>
      end
    end
  end

  defp xml_text_escape(value),
    do:
      value
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp attribute_escape(value) do
    value
    |> xml_text_escape()
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
    |> String.replace("`", "&#96;")
    |> String.replace("=", "&#61;")
    |> String.replace(" ", "&#32;")
    |> String.replace("\n", "&#10;")
    |> String.replace("\r", "&#13;")
    |> String.replace("\t", "&#9;")
  end
end
