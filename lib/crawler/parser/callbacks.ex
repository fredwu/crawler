defmodule Crawler.Parser.Callbacks do
  @moduledoc false

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.HTMLReferences
  alias Crawler.HTMLSpans
  alias Crawler.MediaType
  alias Crawler.Parser.HtmlParser
  alias Crawler.Parser.LinkParser
  alias Crawler.Robots

  def prepare(analysis, opts, %{occurrences: occurrences, budget: budget} = collection) do
    bytes = projection_bytes(analysis, occurrences, opts)

    with {:ok, budget} <- Budget.charge(budget, bytes),
         {:ok, policies, budget} <- document_policies(analysis, opts, budget) do
      {groups, members} = groups(analysis, opts, occurrences, policies)
      {:ok, groups, members, %{collection | budget: budget}}
    end
  end

  defp projection_bytes(analysis, occurrences, opts) do
    fixed = Budget.cost(:map_entry, 64 + 2 * map_size(opts))

    regions =
      Enum.reduce(analysis.regions, fixed, fn {_id, region}, bytes ->
        tags =
          case region.facts do
            %{tags: tags} -> tags
            _other -> []
          end

        document_options = if region.kind in [:html, :xml], do: map_size(opts), else: 0

        Enum.reduce(tags, bytes + Budget.cost(:map_entry, 8 + document_options), fn tag, bytes ->
          bytes + Budget.cost(:map_entry, 16) +
            Budget.cost(:list_cell, 24 + 8 * length(tag.attributes))
        end)
      end)

    count = length(occurrences)
    membership_bytes = Budget.cost(:map_entry, 4 * count) + Budget.cost(:list_cell, 8 * count)

    Enum.reduce(occurrences, regions + membership_bytes, fn occurrence, bytes ->
      depth = region_depth(occurrence.region, analysis.regions)

      bytes + Budget.cost(:map_entry, 8 + map_size(opts) + map_size(occurrence.context)) +
        Budget.cost(:list_cell, 32 + 8 * depth)
    end)
  end

  defp region_depth(id, regions) do
    case regions[id].parent do
      nil -> 1
      parent -> 1 + region_depth(parent, regions)
    end
  end

  defp groups(analysis, opts, occurrences, policies) do
    root = analysis.regions[analysis.root]

    case root.kind do
      kind when kind in [:html, :xml] ->
        document(analysis, root, opts, occurrences, policies, %{})

      :css ->
        {kept, members} = deduplicate(occurrences, %{}, &plain?(&1, analysis))
        {entries(kept), members}

      _kind ->
        {entries(occurrences), %{}}
    end
  end

  def emit(groups, occurrences, opts, handler) do
    indexed = Map.new(occurrences, &{&1.id, &1})
    Enum.map(groups, &emit_group(&1, indexed, opts, handler))
  end

  def emit_bound(groups, occurrences, opts, members, handler, observer) do
    indexed = Map.new(occurrences, &{&1.id, &1})
    emit = fn id -> emit_observed(id, indexed, opts, members, handler, observer) end

    with {:ok, results} <- map_results(groups, &emit_observed_group(&1, emit)), do: results
  end

  defp emit_observed(id, indexed, opts, members, handler, observer) do
    occurrence = Map.fetch!(indexed, id)
    raw = emit_occurrence(occurrence, opts, handler)

    Map.get(members, id, [id])
    |> Enum.reduce_while(:ok, fn member, :ok ->
      case observer.(Map.fetch!(indexed, member), raw) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
        _other -> {:halt, {:error, :invalid_observer_result}}
      end
    end)
    |> case do
      :ok -> {:ok, raw}
      error -> error
    end
  end

  defp emit_observed_group({:entry, id}, emit), do: emit.(id)

  defp emit_observed_group({:element, ids, children}, emit) do
    with {:ok, results} <- map_results(ids, emit),
         {:ok, nested} <- map_results(children, &emit_observed_group(&1, emit)) do
      {:ok, combine(normalize(results), nested)}
    end
  end

  defp map_results(entries, fun) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, results} ->
      case fun.(entry) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp entries(occurrences), do: Enum.map(occurrences, &{:entry, &1.id})

  defp document(analysis, region, opts, occurrences, policies, members) do
    tags = region.facts.tags
    opts = Map.put(opts, :robots_nofollow, Map.fetch!(policies, region.id))
    selected = analysis |> HtmlParser.references(opts, region.id) |> MapSet.new(& &1.span)
    direct = Enum.group_by(region.children, &analysis.regions[&1].metadata.tag.span)
    indexed = Enum.group_by(occurrences, &direct_child(&1.region, region.id, analysis.regions))
    instructions = indexed |> Map.get(region.id, []) |> entries()

    {groups, members} =
      tags
      |> Enum.reject(&(&1.closing? or &1.in_template?))
      |> Enum.map_reduce(members, fn tag, members ->
        ids = Map.get(direct, tag.span, [])
        children = Enum.map(ids, &analysis.regions[&1])
        tag = normalized_tag(tag, children)
        own = Enum.reject(children, &srcdoc?/1)
        found = Enum.flat_map(own, &Map.get(indexed, &1.id, []))

        {nested, members} =
          children
          |> Enum.filter(&srcdoc?/1)
          |> Enum.map_reduce(members, fn child, members ->
            nested_opts =
              opts
              |> Map.drop([:headers, :robots_nofollow])
              |> Map.put(:content_type, "text/html")

            document(
              analysis,
              child,
              nested_opts,
              Map.get(indexed, child.id, []),
              policies,
              members
            )
          end)

        nested = Enum.concat(nested)

        if MapSet.member?(selected, tag.span) or found != [] or nested != [] do
          {plain, refs} = Enum.split_with(found, &plain?(&1, analysis))

          {plain, members} =
            plain
            |> ordered_plain(tag, opts, analysis)
            |> deduplicate(members, fn _occurrence -> true end)

          {[{:element, Enum.map(plain ++ refs, & &1.id), nested}], members}
        else
          {[], members}
        end
      end)

    {instructions ++ Enum.concat(groups), members}
  end

  defp normalized_tag(tag, [first | _rest]) do
    Map.put(tag, :callback_attributes, first.metadata.tag.active_attributes)
  end

  defp normalized_tag(tag, []) do
    attrs = tag |> HTMLSpans.active_attributes() |> Enum.map(&{&1.name, &1.decoded})
    Map.put(tag, :callback_attributes, attrs)
  end

  defp document_policies(analysis, opts, budget) do
    Enum.reduce_while(analysis.regions, {:ok, %{}, budget}, fn
      {id, %{kind: kind} = region}, {:ok, policies, budget} when kind in [:html, :xml] ->
        current =
          if region.parent == nil,
            do: opts,
            else:
              opts
              |> Map.drop([:headers, :robots_nofollow])
              |> Map.put(:content_type, "text/html")

        case document_policy(region, current, budget) do
          {:ok, nofollow, budget} -> {:cont, {:ok, Map.put(policies, id, nofollow), budget}}
          error -> {:halt, error}
        end

      _region, result ->
        {:cont, result}
    end)
  end

  defp document_policy(region, opts, budget) do
    cond do
      opts[:respect_robots] == false ->
        {:ok, false, budget}

      opts[:robots_nofollow] == true ->
        {:ok, true, budget}

      true ->
        meta =
          if region.kind == :html or MediaType.xhtml?(opts[:content_type]),
            do: Enum.filter(region.facts.tags, &(&1.namespace == :html)),
            else: []

        Robots.nofollow_result(meta, opts, budget)
    end
  end

  defp direct_child(id, parent, _regions) when id == parent, do: id

  defp direct_child(id, parent, regions) do
    case regions[id].parent do
      ^parent -> id
      nil -> nil
      previous -> direct_child(previous, parent, regions)
    end
  end

  defp srcdoc?(region), do: region.kind == :html and region.metadata[:name] == "srcdoc"

  defp plain?(%{encoding: {:source_map, _kind, _note}}, _analysis), do: false

  defp plain?(occurrence, analysis) do
    analysis.regions[occurrence.region].kind in [:attribute, :css]
  end

  defp ordered_plain(occurrences, tag, opts, analysis) do
    names = HTMLReferences.attributes(tag.name, tag.callback_attributes, opts, tag.namespace)
    positions = names |> Enum.with_index() |> Map.new()

    Enum.sort_by(occurrences, fn occurrence ->
      region = analysis.regions[occurrence.region]
      attribute = Map.get(positions, region.metadata[:name], length(names))

      offset =
        case occurrence.span do
          {start, _length} -> start
          nil -> :infinity
        end

      {attribute, region.id, offset}
    end)
  end

  defp deduplicate(occurrences, members, eligible?) do
    {kept, _seen, own} =
      Enum.reduce(occurrences, {[], %{}, %{}}, fn occurrence, {kept, seen, own} ->
        key = emission_key(occurrence)

        case {eligible?.(occurrence), Map.fetch(seen, key)} do
          {true, {:ok, representative}} ->
            own =
              Map.update(
                own,
                representative,
                [occurrence.id, representative],
                &[occurrence.id | &1]
              )

            {kept, seen, own}

          {true, :error} ->
            {[occurrence | kept], Map.put(seen, key, occurrence.id), own}

          {false, _found} ->
            {[occurrence | kept], seen, own}
        end
      end)

    own = Map.new(own, fn {representative, ids} -> {representative, Enum.reverse(ids)} end)
    {Enum.reverse(kept), Map.merge(members, own)}
  end

  defp emission_key(occurrence),
    do: {occurrence.value, occurrence.url, Analysis.context_key(occurrence.context)}

  defp emit_group({:entry, id}, indexed, opts, handler),
    do: emit_occurrence(Map.fetch!(indexed, id), opts, handler)

  defp emit_group({:element, ids, children}, indexed, opts, handler) do
    result =
      ids |> Enum.map(&emit_occurrence(Map.fetch!(indexed, &1), opts, handler)) |> normalize()

    nested = Enum.map(children, &emit_group(&1, indexed, opts, handler))
    combine(result, nested)
  end

  defp emit_occurrence(occurrence, opts, handler) do
    LinkParser.emit_occurrence(occurrence, opts, handler)
  end

  defp normalize([]), do: nil
  defp normalize([result]), do: result
  defp normalize(results), do: results

  defp combine(result, []), do: result
  defp combine(nil, [result]), do: result
  defp combine(nil, results), do: results
  defp combine(result, results) when not is_list(result), do: [result | results]
  defp combine(results, extra), do: results ++ extra
end
