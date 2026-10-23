defmodule Crawler.Parser.CssParser.VariableGraph do
  @moduledoc false

  alias Crawler.Analysis.Budget

  @defaults [max_work: 100_000, max_pictures: 10_000, max_depth: 256]

  def run(sheets, fallbacks?, opts) do
    {:ok, outcome, _budget} = run_result(sheets, fallbacks?, opts, Budget.unlimited())
    outcome
  end

  def run_result(sheets, fallbacks?, opts, budget) do
    state = initial(fallbacks?, opts, budget)

    try do
      state = hold(state, 4096)
      state = %{state | budget: adopt(sheets, state.budget)}
      state = Enum.reduce(sheets, state, &index_sheet/2)
      state = hold(state, Budget.cost(:list_cell, length(state.uses)))
      uses = Enum.reverse(state.uses)
      {result, state} = collect(uses, empty(), state, &use_pictures/2)

      output_bytes =
        Budget.cost(:context) +
          length(result.pictures) *
            (Budget.cost(:context) + Budget.cost(:token) + Budget.cost(:list_cell))

      budget = take!(Budget.charge(state.budget, output_bytes))
      pictures = Enum.reverse(result.pictures)
      budget = take!(Budget.release(budget, state.held))

      {:ok,
       %{
         pictures: pictures,
         revision: state.revision,
         status: :ok,
         stats: Map.put(state.stats, :pictures, MapSet.size(result.identities))
       }, budget}
    catch
      {:css_graph_limit, limit, state} ->
        with {:ok, budget} <- Budget.charge(state.budget, Budget.cost(:context)),
             {:ok, budget} <- Budget.release(budget, state.held) do
          {:ok,
           %{
             pictures: [],
             revision: state.revision,
             status: {:limited, limit},
             stats: Map.put(state.stats, :pictures, 0)
           }, budget}
        end

      {:css_graph_budget, reason} ->
        {:error, reason}
    end
  end

  defp initial(fallbacks?, opts, budget) do
    limits =
      Map.new(@defaults, fn {key, default} ->
        value = Keyword.get(opts, key, default)

        if not is_integer(value) or value < 1 do
          raise ArgumentError, "#{key} must be a positive integer"
        end

        {key, value}
      end)

    %{
      budget: budget,
      held: 0,
      revision: Keyword.get_lazy(opts, :graph_revision, &make_ref/0),
      fallbacks?: fallbacks?,
      limits: limits,
      bindings: %{},
      local: %{},
      rules: %{},
      registrations: %{},
      bases: %{},
      uses: [],
      memo: %{},
      stats: %{work: 0, indexed: 0, lookups: 0, cache_hits: 0, cache_entries: 0}
    }
  end

  defp index_sheet(sheet, state) do
    state = spend(state)
    state = hold(state, Budget.cost(:map_entry))
    state = %{state | bases: Map.put_new(state.bases, sheet.id, sheet.base)}

    {state, _index} =
      Enum.reduce(sheet.bindings, {state, 0}, fn binding, {state, index} ->
        state = indexed(state)
        state = hold(state, Budget.cost(:map_entry, 3) + 192)
        rank = {sheet.order, index}
        name = binding.name

        state = %{
          state
          | bindings: put_winner(state.bindings, name, rank, binding),
            local: put_winner(state.local, {name, binding.sheet_id}, rank, binding),
            rules:
              put_winner(state.rules, {name, binding.sheet_id, binding.rule_id}, rank, binding)
        }

        {state, index + 1}
      end)

    {state, _index} =
      Enum.reduce(sheet.registrations, {state, 0}, fn registration, {state, index} ->
        state = indexed(state)

        state = hold(state, Budget.cost(:map_entry) + 64)

        registrations =
          put_winner(state.registrations, registration.name, {sheet.order, index}, registration)

        {%{state | registrations: registrations}, index + 1}
      end)

    Enum.reduce(sheet.uses, state, fn use, state ->
      state = indexed(state)
      state = hold(state, Budget.cost(:list_cell))
      %{state | uses: [use | state.uses]}
    end)
  end

  defp put_winner(index, key, rank, item) do
    Map.update(index, key, {rank, item}, fn
      {old_rank, _old} when rank > old_rank -> {rank, item}
      old -> old
    end)
  end

  defp indexed(state) do
    state = spend(state)
    %{state | stats: Map.update!(state.stats, :indexed, &(&1 + 1))}
  end

  defp use_pictures(use, state) do
    state = hold(state, Budget.cost(:context) + Budget.cost(:frame))
    ctx = context(use.sheet_id, use.base, use.sheet_id, use.base, use.sheet_id, use.rule_id)
    alias_pictures(use, ctx, MapSet.new(), 0, state)
  end

  defp resolve(name, ctx, seen, depth, state) do
    state = spend(state)
    check_depth(depth, state)

    state = hold(state, Budget.cost(:frame) + Budget.cost(:map_entry))

    if MapSet.member?(seen, name) do
      {%{empty() | names: MapSet.new([name]), cyclic?: true}, state}
    else
      cached_or_resolve(name, ctx, seen, depth, state)
    end
  end

  defp cached_or_resolve(name, ctx, seen, depth, state) do
    state = hold(state, 128)
    key = {state.revision, ctx.use_sheet, ctx.use_rule, state.fallbacks?, name}

    case Map.fetch(state.memo, key) do
      {:ok, result} ->
        state = spend(state, min(MapSet.size(result.names), MapSet.size(seen)))

        if MapSet.disjoint?(result.names, seen) do
          stats = Map.update!(state.stats, :cache_hits, &(&1 + 1))
          {result, %{state | stats: stats}}
        else
          resolve_binding(name, key, ctx, seen, depth, state)
        end

      :error ->
        resolve_binding(name, key, ctx, seen, depth, state)
    end
  end

  defp resolve_binding(name, key, ctx, seen, depth, state) do
    stats = Map.update!(state.stats, :lookups, &(&1 + 1))
    state = %{state | stats: stats}

    state = hold(state, Budget.cost(:map_entry))

    {result, state} =
      case winning(name, ctx, state) do
        nil ->
          {%{empty() | set?: false}, state}

        binding ->
          binding_pictures(binding, ctx, MapSet.put(seen, name), depth + 1, state)
      end

    state = hold(state, Budget.cost(:map_entry) + Budget.cost(:context))
    result = %{result | names: MapSet.put(result.names, name)}

    if result.cyclic? do
      {result, state}
    else
      state = hold(state, Budget.cost(:map_entry))
      memo = Map.put(state.memo, key, result)
      stats = %{state.stats | cache_entries: map_size(memo)}
      {result, %{state | memo: memo, stats: stats}}
    end
  end

  defp winning(name, ctx, state) do
    entry =
      Map.get(state.rules, {name, ctx.use_sheet, ctx.use_rule}) ||
        Map.get(state.local, {name, ctx.use_sheet}) || Map.get(state.bindings, name)

    item(entry)
  end

  defp item(nil), do: nil
  defp item({_rank, item}), do: item

  defp binding_pictures(binding, ctx, seen, depth, state) do
    base_id = if registered?(binding.name, state), do: binding.sheet_id, else: ctx.use_sheet
    base = Map.get(state.bases, base_id, binding.base)
    state = hold(state, Budget.cost(:context))
    ctx = context(binding.sheet_id, binding.base, base_id, base, ctx.use_sheet, ctx.use_rule)
    value_pictures(binding, ctx, seen, depth, state)
  end

  defp registered?(name, state) do
    case item(Map.get(state.registrations, name)) do
      %{syntax_url?: true} -> true
      _other -> false
    end
  end

  defp alias_pictures(alias_value, ctx, seen, depth, state) do
    {result, state} = resolve(alias_value.name, ctx, seen, depth, state)

    if result.set? or not state.fallbacks? do
      {result, state}
    else
      {fallback, state} = unset_pictures(alias_value, ctx, seen, depth + 1, state)
      merge(result, fallback, state)
    end
  end

  defp unset_pictures(alias_value, ctx, seen, depth, state) do
    state = spend(state)
    check_depth(depth, state)

    case item(Map.get(state.registrations, alias_value.name)) do
      %{syntax_url?: true, initial: token} = registration when not is_nil(token) ->
        state = hold(state, Budget.cost(:context))

        ctx =
          context(
            registration.sheet_id,
            registration.base,
            registration.sheet_id,
            registration.base,
            ctx.use_sheet,
            ctx.use_rule
          )

        add_picture(empty(), token, ctx, state)

      _other ->
        state = hold(state, Budget.cost(:map_entry))
        seen = MapSet.put(seen, alias_value.name)
        fallback_pictures(alias_value.fallback, ctx, seen, depth, state)
    end
  end

  defp fallback_pictures(nil, _ctx, _seen, _depth, state), do: {empty(), state}

  defp fallback_pictures(value, ctx, seen, depth, state) do
    value_pictures(value, ctx, seen, depth, state)
  end

  defp value_pictures(value, ctx, seen, depth, state) do
    state = hold(state, Budget.cost(:context) + Budget.cost(:frame))

    {result, state} =
      Enum.reduce(value.urls, {empty(), state}, fn token, {result, state} ->
        add_picture(result, token, ctx, state)
      end)

    collect(value.aliases, result, state, fn alias_value, state ->
      alias_pictures(alias_value, ctx, seen, depth, state)
    end)
  end

  defp collect(items, result, state, fun) do
    state = hold(state, Budget.cost(:frame))

    Enum.reduce(items, {result, state}, fn item, {result, state} ->
      state = spend(state)
      {next, state} = fun.(item, state)
      merge(result, next, state)
    end)
  end

  defp merge(result, next, state) do
    state = spend(state, MapSet.size(next.names))

    state =
      hold(
        state,
        Budget.cost(:map_entry, MapSet.size(next.names)) +
          Budget.cost(:context) + Budget.cost(:list_cell, length(next.pictures))
      )

    result = %{
      result
      | names: MapSet.union(result.names, next.names),
        cyclic?: result.cyclic? or next.cyclic?
    }

    next.pictures
    |> Enum.reverse()
    |> Enum.reduce({result, state}, fn picture, {result, state} ->
      insert_picture(result, picture, state)
    end)
  end

  defp add_picture(result, token, ctx, state) do
    state = hold(state, Budget.cost(:context) + Budget.cost(:token))

    picture = %{
      token: Map.put_new(token, :kind, :url),
      token_sheet: ctx.token_sheet,
      token_base: ctx.token_base,
      base_sheet: ctx.base_id,
      base_url: ctx.base_url
    }

    insert_picture(result, picture, state)
  end

  defp insert_picture(result, picture, state) do
    state = spend(state)

    if MapSet.member?(result.identities, picture) do
      {result, state}
    else
      if MapSet.size(result.identities) >= state.limits.max_pictures do
        limit(:pictures, state)
      end

      state =
        hold(state, Budget.cost(:list_cell) + Budget.cost(:map_entry) + Budget.cost(:context))

      {%{
         result
         | pictures: [picture | result.pictures],
           identities: MapSet.put(result.identities, picture)
       }, state}
    end
  end

  defp empty do
    %{pictures: [], identities: MapSet.new(), names: MapSet.new(), cyclic?: false, set?: true}
  end

  defp context(token_sheet, token_base, base_id, base_url, use_sheet, use_rule) do
    %{
      token_sheet: token_sheet,
      token_base: token_base,
      base_id: base_id,
      base_url: base_url,
      use_sheet: use_sheet,
      use_rule: use_rule
    }
  end

  defp check_depth(depth, state) do
    if depth >= state.limits.max_depth, do: limit(:depth, state)
  end

  defp spend(state, amount \\ 1) do
    work = state.stats.work + amount
    if work > state.limits.max_work, do: limit(:work, state)
    state = hold(state, Budget.cost(:frame))
    %{state | stats: %{state.stats | work: work}}
  end

  # Internal graph structures remain live until the outcome is detached. Charging
  # replacements cumulatively also covers old persistent-map paths awaiting GC.
  defp hold(state, bytes) do
    budget = take!(Budget.reserve(state.budget, bytes))
    %{state | budget: budget, held: state.held + bytes}
  end

  # Inputs can arrive from a cache snapshot rather than a lexical ledger. Adopt
  # their complete backing conservatively; repeated references are overcharged.
  defp adopt(_term, %{limit: :infinity} = budget), do: budget

  defp adopt(term, budget) when is_binary(term),
    do: take!(Budget.charge(budget, Budget.cost(:binary) + :binary.referenced_byte_size(term)))

  defp adopt([], budget), do: budget

  defp adopt([head | tail], budget) do
    budget = take!(Budget.charge(budget, Budget.cost(:list_cell) + Budget.cost(:frame)))
    budget = adopt(head, budget)
    adopt(tail, budget)
  end

  defp adopt(term, budget) when is_map(term) do
    budget = take!(Budget.charge(budget, 128 + Budget.cost(:map_entry, map_size(term))))
    adopt_map(:maps.iterator(term), budget)
  end

  defp adopt(term, budget) when is_tuple(term) do
    budget = take!(Budget.charge(budget, 32 + 8 * tuple_size(term)))
    adopt_tuple(term, 0, budget)
  end

  defp adopt(_term, budget), do: budget

  defp adopt_map(iterator, budget) do
    case :maps.next(iterator) do
      :none ->
        budget

      {key, value, next} ->
        budget = adopt(key, budget)
        budget = adopt(value, budget)
        adopt_map(next, budget)
    end
  end

  defp adopt_tuple(tuple, index, budget) when index == tuple_size(tuple), do: budget

  defp adopt_tuple(tuple, index, budget),
    do: adopt_tuple(tuple, index + 1, adopt(elem(tuple, index), budget))

  defp take!({:ok, budget}), do: budget
  defp take!({:error, reason}), do: throw({:css_graph_budget, reason})

  @spec limit(:work | :pictures | :depth, map()) :: no_return()
  defp limit(kind, state), do: throw({:css_graph_limit, kind, state})
end
