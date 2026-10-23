defmodule Crawler.Parser.CssSheets do
  @moduledoc false

  use GenServer

  alias Crawler.Analysis.Budget
  alias Crawler.Deadline
  alias Crawler.Dispatcher
  alias Crawler.HTMLReferences
  alias Crawler.Limits
  alias Crawler.Parser.CssParser.Variables
  alias Crawler.Parser.LinkParser
  alias Crawler.Store
  alias Crawler.Store.Authority
  alias Crawler.Store.Execution
  alias Crawler.Store.Retained
  alias Crawler.URL

  defmodule Error do
    @moduledoc false
    defexception [:reason]
    @impl true
    def message(%{reason: reason}), do: "CSS settlement failed: #{inspect(reason)}"
  end

  @cleanup_batch 64
  @cleanup_interval 100
  @metadata_bytes 16_384

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  def resolve_groups(opts, groups) do
    opts = normalize(opts)

    if is_nil(opts[:generation]) do
      local_groups(groups, Limits.validate!(opts))
    else
      Execution.run(opts, &resolve_managed_groups(&1, groups))
    end
  end

  defp resolve_managed_groups(opts, groups) do
    Enum.reduce_while(groups, {:ok, empty_context()}, fn group, {:ok, context} ->
      case resolve_group(opts, group, :resolve) do
        {:ok, resolved} -> {:cont, {:ok, merge_context(context, resolved)}}
        error -> {:halt, error}
      end
    end)
  end

  def remember(opts, body, analysis) when is_binary(body) do
    opts = normalize(opts)

    cond do
      Map.get(opts, :mode, :stylesheet) != :stylesheet ->
        :local

      is_nil(opts[:generation]) ->
        :local

      not server?() ->
        :local

      String.contains?(body, <<0>>) and opts[:css_sheet] != :replace ->
        :local

      true ->
        group = legacy_group(opts, body, analysis)
        mode = if opts[:css_sheet] == :replace, do: :preview, else: :remember

        result = Execution.run(opts, fn opts -> resolve_group(opts, group, mode) end)

        case unwrap(result) do
          {:ok, context} -> {:ok, Map.get(context.css_tokens, :legacy, [])}
          {:error, :stale} -> {:ok, []}
          error -> error
        end
    end
  end

  def remember(_opts, _body, _analysis), do: :local

  def take_urls(opts, body, span_tokens) when is_binary(body) do
    opts = normalize(opts)

    if managed_stylesheet?(opts) and opts[:css_sheet] != :rewrite do
      result = Execution.run(opts, &take_managed_urls(&1, span_tokens))

      case unwrap(result) do
        {:error, :stale} -> []
        result -> result
      end
    else
      []
    end
  end

  def take_urls(_opts, _body, _span_tokens), do: []

  defp take_managed_urls(opts, span_tokens) do
    key = group_key(opts, group_id(opts))

    with {:ok, descriptor} <- call({:describe, authority_options(opts), key}),
         {:ok, receipt} <-
           Store.reserve_resource(opts, :css_snapshot, descriptor.bytes, self()),
         :ok <- Store.retain_resource(receipt, descriptor.cache),
         {:ok, ref} <-
           Store.deliver_resource(receipt, descriptor.cache, {:read, opts, key, receipt}) do
      with {:ok, %{group: group}} <- await(ref, opts) do
        take_group_urls(opts, span_tokens, key, descriptor, group)
      end
    end
  end

  defp take_group_urls(opts, span_tokens, key, descriptor, group) do
    covered = covered_urls(span_tokens, sheet_base(opts))

    fresh =
      Enum.reject(
        group.urls,
        &(MapSet.member?(covered, &1) or MapSet.member?(group.emitted, &1))
      )

    emissions = covered |> MapSet.union(MapSet.new(fresh)) |> MapSet.difference(group.emitted)

    if MapSet.size(emissions) == 0 do
      fresh
    else
      with {:ok, bytes} <- Retained.bytes(emissions, opts.max_analysis_bytes),
           {:ok, emitted} <-
             Store.reserve_resource(
               opts,
               :css_facts,
               bytes + @metadata_bytes,
               descriptor.cache
             ),
           {:ok, emit_ref} <-
             Store.deliver_resource(
               emitted,
               descriptor.cache,
               {:emit, opts, key, group.revision, emissions, bytes + @metadata_bytes}
             ),
           :ok <- await(emit_ref, opts) do
        fresh
      end
    end
  end

  def replay?(opts, body) when is_binary(body) do
    opts = normalize(opts)

    if managed_stylesheet?(opts) and not String.contains?(body, <<0>>) do
      case call(
             {:replay, authority_options(opts), group_key(opts, group_id(opts)),
              source_revision(body)}
           ) do
        result when is_boolean(result) -> result
        _ -> false
      end
    else
      false
    end
  end

  def replay?(_opts, _body), do: false

  def settle(opts) do
    opts = normalize(opts)
    urls = Enum.filter([opts[:url], opts[:referrer_url]], &is_binary/1) |> Enum.uniq()

    if not is_nil(opts[:generation]) and server?() and urls != [] do
      result = Execution.run(opts, &settle_groups(&1, urls))

      case unwrap(result) do
        {:ok, urls} -> Enum.uniq(urls)
        {:error, :stale} -> []
        error -> error
      end
    else
      []
    end
  end

  defp settle_groups(opts, urls) do
    with {:ok, keys} <- call({:groups, authority_options(opts)}) do
      Enum.reduce_while(keys, {:ok, []}, &settle_group(opts, urls, &1, &2))
    end
  end

  defp settle_group(opts, urls, key, {:ok, urls_found}) do
    group = %{style_group: elem(key, 2), source_revision: nil, sheets: [], failed: urls}

    case resolve_group(opts, group, :settle) do
      {:ok, context} ->
        extra =
          context.css_references
          |> Map.values()
          |> List.flatten()
          |> Enum.map(&resolve_picture/1)

        {:cont, {:ok, Enum.reject(extra, &is_nil/1) ++ urls_found}}

      error ->
        {:halt, error}
    end
  end

  def run_settlement(opts, group, _revision) do
    key = group_key(opts, group)

    with {:ok, descriptor} <- call({:describe, authority_options(opts), key}),
         {:ok, receipt} <-
           Store.reserve_resource(opts, :css_snapshot, descriptor.bytes, descriptor.cache) do
      try do
        settle_with_output(opts, key, group, receipt, descriptor)
      after
        Store.release_resource(receipt)
      end
    end
  end

  defp settle_with_output(opts, key, group, receipt, descriptor) do
    capacity = descriptor.bytes + 128 * opts.max_css_work

    with {:ok, output} <- Store.reserve_resource(opts, :scratch, capacity, descriptor.cache) do
      try do
        with {:ok, ref} <-
               Store.deliver_resource(
                 receipt,
                 descriptor.cache,
                 {:snapshot, opts, key, receipt, output, :settle,
                  %{snapshot: descriptor.bytes, output: capacity}}
               ) do
          settlement_reply(ref, opts, key, group)
        end
      after
        Store.release_resource(output)
      end
    end
  end

  defp settlement_reply(ref, opts, key, group) do
    with {:ok, {:snapshot, snapshot}} <- await(ref, opts),
         do: settle_snapshot(snapshot, opts, key, group)
  end

  defp settle_snapshot(%{mode: :cached, revision: revision}, _opts, _key, _group),
    do: {:ok, revision}

  defp settle_snapshot(snapshot, opts, key, group) do
    with {:ok, :compute} <- Store.schedule_css(opts, group, snapshot.revision) do
      case compute_and_commit(snapshot, opts, key) do
        {:ok, context} ->
          discover_settled_pictures(context, opts)

          {:ok, snapshot.revision}

        other ->
          other
      end
    end
  end

  defp discover_settled_pictures(context, opts) do
    unless Authority.export_managed?(opts[:scope], opts[:generation]) do
      context.css_references
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq_by(&{&1.token.value, &1.base_url})
      |> Enum.each(&discover_settled_picture(&1, opts))
    end
  end

  defp discover_settled_picture(picture, opts) do
    case resolve_picture(picture) do
      nil -> :ok
      url -> LinkParser.parse({:css, url, :url}, opts, &Dispatcher.dispatch/2)
    end
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :cleanup, @cleanup_interval)

    {:ok,
     %{
       scopes: %{},
       jobs: %{},
       retained: MapSet.new(),
       runs: MapSet.new(),
       run_groups: %{},
       cleanup: :queue.new(),
       incarnation: make_ref(),
       next: 0
     }}
  end

  @impl true
  def handle_call({:describe, opts, key}, _from, state) do
    if current?(opts) do
      group = candidate(state, key)
      descriptor = %{cache: self(), bytes: snapshot_bytes(group), incarnation: state.incarnation}
      {:reply, {:ok, descriptor}, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:groups, opts}, _from, state) do
    if current?(opts) do
      groups = get_in(state.scopes, [run_key(opts), :groups]) || %{}
      {:reply, {:ok, Enum.map(Map.keys(groups), &group_key(opts, &1))}, state}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:abort, opts, key, revision}, _from, state) do
    if current?(opts) and match?(%{revision: ^revision}, state.jobs[key]) do
      {:reply, :ok, discard_job(state, key)}
    else
      {:reply, {:error, :stale}, state}
    end
  end

  def handle_call({:replay, opts, key, revision}, _from, state) do
    group = candidate(state, key)
    reply = current?(opts) and not MapSet.member?(group.sources, revision)
    {:reply, reply, state}
  end

  @impl true
  def handle_info({:crawler_resource_delivery, receipt, lease, origin, ref, payload}, state) do
    case payload do
      {:register, opts, prepared, snapshot_receipt, output_receipt, mode} ->
        if writable_grant?(receipt, lease, opts) and granted?(snapshot_receipt, lease, opts) and
             granted?(output_receipt, lease, opts) do
          state =
            register(
              state,
              receipt,
              origin,
              ref,
              opts,
              prepared,
              snapshot_receipt,
              output_receipt,
              mode
            )

          {:noreply, state}
        else
          release(receipt)
          release(snapshot_receipt)
          release(output_receipt)
          send(origin, {ref, {:error, :stale}})
          {:noreply, state}
        end

      {:snapshot, opts, key, snapshot_receipt, output_receipt, mode, capacities} ->
        if writable_grant?(receipt, lease, opts) and granted?(snapshot_receipt, lease, opts) and
             granted?(output_receipt, lease, opts) do
          {:noreply,
           send_snapshot(
             state,
             key,
             origin,
             ref,
             opts,
             snapshot_receipt,
             output_receipt,
             mode,
             capacities
           )}
        else
          release(receipt)
          release(snapshot_receipt)
          release(output_receipt)
          send(origin, {ref, {:error, :stale}})
          {:noreply, state}
        end

      {:commit, opts, key, revision, result} ->
        if writable_grant?(receipt, lease, opts) do
          {:noreply, commit(state, key, revision, receipt, origin, ref, opts, result)}
        else
          release(receipt)
          send(origin, {ref, {:error, :stale}})
          {:noreply, state}
        end

      {:emit, opts, key, revision, covered, bytes} ->
        group = committed(state, key)

        if writable_grant?(receipt, lease, opts) and group.revision == revision do
          group = %{
            group
            | emitted: MapSet.union(group.emitted, covered),
              emission_receipts: Map.put(group.emission_receipts, receipt, bytes)
          }

          state = put_group(state, key, group)
          state = %{state | retained: MapSet.put(state.retained, receipt)}
          adopted(receipt)
          send(origin, {ref, :ok})
          {:noreply, state}
        else
          release(receipt)
          send(origin, {ref, {:error, :stale}})
          {:noreply, state}
        end

      {:read, opts, key, snapshot_receipt} ->
        if granted?(receipt, lease, opts) do
          group = committed(state, key)
          adopted(snapshot_receipt)

          Store.deliver_resource_async(
            snapshot_receipt,
            lease,
            origin,
            %{group: group},
            origin,
            ref
          )

          release(snapshot_receipt)
        else
          release(receipt)
          send(origin, {ref, {:error, :stale}})
        end

        {:noreply, state}
    end
  end

  def handle_info({:crawler_resource_abandon, receipt, _lease}, state) do
    settle(receipt, if(MapSet.member?(state.retained, receipt), do: :retained, else: :released))
    {:noreply, state}
  end

  def handle_info(:cleanup, state) do
    state = cleanup(state, min(@cleanup_batch, MapSet.size(state.runs)))
    Process.send_after(self(), :cleanup, @cleanup_interval)
    {:noreply, state}
  end

  defp cleanup(state, 0), do: state

  defp cleanup(state, remaining) do
    case :queue.out(state.cleanup) do
      {:empty, _} ->
        state

      {{:value, {scope, generation} = run}, queue} ->
        state = %{state | cleanup: queue}

        state =
          cond do
            not MapSet.member?(state.runs, run) ->
              state

            Authority.current?(scope, generation, nil) ->
              %{state | cleanup: :queue.in(run, state.cleanup)}

            true ->
              discard_run(state, run)
          end

        cleanup(state, remaining - 1)
    end
  end

  defp resolve_group(opts, raw, mode) do
    cache = Process.whereis(__MODULE__)

    with true <- is_pid(cache),
         {:ok, raw_bytes} <- Retained.bytes({raw, opts}, opts.max_analysis_bytes),
         facts_capacity = 2 * raw_bytes + @metadata_bytes,
         key = group_key(opts, raw.style_group),
         {:ok, descriptor} <- call({:describe, authority_options(opts), key}),
         snapshot_capacity = descriptor.bytes + 2 * facts_capacity,
         output_capacity = snapshot_capacity + 128 * opts.max_css_work,
         {:ok, facts} <- Store.reserve_resource(opts, :css_facts, facts_capacity, cache),
         {:ok, snapshot} <- Store.reserve_resource(opts, :css_snapshot, snapshot_capacity, cache) do
      try do
        with {:ok, output} <- Store.reserve_resource(opts, :scratch, output_capacity, cache),
             {:ok, prepared} <- prepare_group(raw, opts),
             {:ok, size} <- Retained.bytes({prepared, opts}, facts_capacity - @metadata_bytes),
             actual = size + @metadata_bytes,
             :ok <- Store.commit_resource(facts, actual),
             :ok <- retain_obligation(facts, mode),
             opts = Map.put(opts, :css_obligation_receipt, facts),
             prepared =
               Map.merge(prepared, %{
                 bytes: actual,
                 capacities: %{snapshot: snapshot_capacity, output: output_capacity}
               }),
             {:ok, ref} <-
               Store.deliver_resource(
                 facts,
                 cache,
                 {:register, opts, prepared, snapshot, output, mode}
               ) do
          await_resolution(ref, opts, key)
        end
      after
        Store.release_resource(snapshot)
      end
    else
      false -> {:error, :css_cache_unavailable}
      error -> error
    end
  end

  defp await_resolution(ref, opts, key) do
    case await(ref, opts) do
      {:ok, {:snapshot, %{mode: :cached} = snapshot}} ->
        funded_committed_context(snapshot, opts)

      {:ok, {:snapshot, %{mode: :preview} = snapshot}} ->
        case compute(snapshot, opts) do
          {:error, _} = error ->
            error

          result ->
            {:ok, result.context}
        end

      {:ok, {:snapshot, snapshot}} ->
        case Store.schedule_css(opts, elem(key, 2), snapshot.revision) do
          {:ok, :compute} ->
            case compute_and_commit(snapshot, opts, key) do
              {:superseded, _latest} -> committed_context(snapshot, opts)
              result -> result
            end

          {:ok, status} when status in [:queued, :settled] ->
            funded_committed_context(snapshot, opts)

          error ->
            error
        end

      other ->
        other
    end
  end

  defp funded_committed_context(snapshot, opts) do
    with {:ok, workspace} <- Store.reserve_resource(opts, :scratch, 98_304) do
      try do
        with {:ok, context} <- committed_context(snapshot, opts),
             {:ok, bytes} <- Retained.bytes(context, snapshot.output_capacity - @metadata_bytes),
             :ok <- Store.commit_resource(snapshot.output_receipt, bytes + @metadata_bytes),
             do: {:ok, context}
      after
        Store.release_resource(workspace)
      end
    end
  end

  defp committed_context(snapshot, opts) do
    pictures =
      case snapshot.committed.outcome do
        nil -> []
        outcome -> outcome.pictures
      end

    revision = snapshot.committed.revision || {:pending, snapshot.revision}
    budget = Budget.new(Limits.analysis(opts))

    with {:ok, budget} <- adopt_snapshot_result(snapshot, budget) do
      case project_result(pictures, snapshot.request, snapshot.committed, revision, budget) do
        {:ok, context, _budget} -> {:ok, context}
        error -> error
      end
    end
  end

  defp compute_and_commit(snapshot, opts, key) do
    result = compute(snapshot, opts)

    case result do
      {:error, _} = error ->
        call({:abort, authority_options(opts), key, snapshot.revision})
        complete(opts, key, snapshot.revision, error)
        error

      result ->
        with {:ok, size} <- Retained.bytes(result, snapshot.output_capacity - @metadata_bytes),
             actual = size + @metadata_bytes,
             :ok <- Store.commit_resource(snapshot.output_receipt, actual),
             {:ok, ref} <-
               Store.deliver_resource(
                 snapshot.output_receipt,
                 snapshot.cache,
                 {:commit, opts, key, snapshot.revision,
                  Map.merge(result, %{bytes: actual, emit?: snapshot.mode in [:resolve, :settle]})}
               ),
             :ok <- await(ref, opts) do
          context = result.context

          case complete(opts, key, snapshot.revision, {:ok, snapshot.revision}) do
            :ok -> {:ok, context}
            :superseded -> {:superseded, snapshot.revision}
            error -> error
          end
        else
          {:superseded, latest} ->
            complete(opts, key, snapshot.revision, :superseded)
            {:superseded, latest}

          error ->
            call({:abort, authority_options(opts), key, snapshot.revision})
            complete(opts, key, snapshot.revision, error)
            error
        end
    end
  end

  defp prepare_group(raw, opts) do
    source = raw.source_revision

    sheets =
      Enum.map(raw.sheets, fn sheet ->
        id = {source, sheet.id, sheet.base}
        tagged = fn items -> Enum.map(items, &Map.put(&1, :sheet_id, id)) end

        %{
          sheet
          | id: id,
            bindings: tagged.(sheet.bindings),
            registrations: tagged.(sheet.registrations),
            uses: tagged.(sheet.uses)
        }
        |> Map.put(:region_id, sheet.id)
        |> Map.put(:source_revision, source)
        |> Map.put(
          :imports,
          Enum.reject(
            Enum.map(Map.get(sheet, :imports, []), &resolve_value(&1.value, sheet.base)),
            &is_nil/1
          )
        )
      end)

    prepared = %{
      style_group: raw.style_group,
      source_revision: source,
      sheets: sheets,
      failed: Map.get(raw, :failed, []),
      joined: Enum.filter([opts[:url], opts[:referrer_url]], &is_binary/1)
    }

    with {:ok, bytes} <- Retained.bytes(prepared, opts.max_analysis_bytes) do
      {:ok, Map.put(prepared, :bytes, bytes + @metadata_bytes)}
    end
  end

  defp compute(snapshot, opts) do
    case compute_result(snapshot, opts, Budget.new(Limits.analysis(opts))) do
      {:ok, result, _budget} -> result
      error -> error
    end
  end

  def compute_result(snapshot, opts, budget) do
    count = map_size(snapshot.group.sheets)
    scratch = 512 + Budget.cost(:list_cell, 10 * count)

    with {:ok, budget} <- adopt_snapshot_result(snapshot, budget),
         {:ok, budget} <- Budget.reserve(budget, scratch) do
      sheets = snapshot.group.sheets |> Map.values() |> Enum.sort_by(& &1.order)
      limits = Keyword.put(Limits.css(opts), :graph_revision, snapshot.revision)

      with {:ok, outcome, budget} <-
             Variables.analyze_result(
               sheets,
               MapSet.size(snapshot.group.pending) == 0,
               limits,
               budget
             ),
           {:ok, budget} <- Budget.release(budget, scratch) do
        case outcome.status do
          {:limited, limit} ->
            {:error, {:limit, {:css_graph, limit}}}

          :ok ->
            with {:ok, budget} <-
                   Budget.charge(
                     budget,
                     Budget.cost(:context, 2) +
                       Budget.cost(:map_entry, map_size(snapshot.group))
                   ),
                 {:ok, context, urls, budget} <-
                   projection_result(
                     outcome.pictures,
                     snapshot.request,
                     snapshot.group,
                     snapshot.revision,
                     budget
                   ) do
              {:ok,
               %{
                 outcome: outcome,
                 context: context,
                 metadata: Map.drop(snapshot.group, [:sheets, :outcome, :urls]),
                 urls: urls
               }, budget}
            end
        end
      end
    end
  end

  defp adopt_snapshot_result(snapshot, budget) do
    with {:ok, budget} <- Budget.reserve(budget, 512),
         {:ok, budget} <- Budget.charge(budget, compute_input_bytes(snapshot.group)),
         {:ok, budget} <- Budget.release(budget, 512),
         do: {:ok, budget}
  end

  defp compute_input_bytes(group),
    do:
      2 *
        (compute_receipt_bytes(:maps.iterator(group.receipts), 0) +
           compute_receipt_bytes(:maps.iterator(group.emission_receipts), 0) + group.output_bytes) +
        @metadata_bytes

  defp compute_receipt_bytes(iterator, bytes) do
    case :maps.next(iterator) do
      :none -> bytes
      {_receipt, size, next} -> compute_receipt_bytes(next, bytes + size)
    end
  end

  defp project(pictures, request, group, revision) do
    {:ok, context, _budget} =
      project_result(pictures, request, group, revision, Budget.unlimited())

    context
  end

  def project_result(pictures, request, group, revision, budget) do
    case projection_result(pictures, request, group, revision, budget) do
      {:ok, context, _urls, budget} -> {:ok, context, budget}
      error -> error
    end
  end

  defp projection_result(pictures, request, group, revision, budget) do
    budget = projection_take!(Budget.reserve(budget, 1024))
    {pictures, budget, held} = projection_pictures(pictures, budget, 1024)

    {tokens, budget} =
      Enum.reduce(request.sheets, {%{}, budget}, fn sheet, {tokens, budget} ->
        budget = projection_take!(Budget.charge(budget, Budget.cost(:map_entry)))

        case Variables.picture_spans_result(pictures, sheet.id, budget) do
          {:ok, spans, budget} -> {Map.put(tokens, sheet.region_id, spans), budget}
          {:error, reason} -> throw({:css_projection_budget, reason})
        end
      end)

    {covered, cache, budget, held} =
      Enum.reduce(request.sheets, {MapSet.new(), %{}, budget, held}, fn sheet, acc ->
        Enum.reduce(Map.get(tokens, sheet.region_id, []), acc, fn token,
                                                                  {covered, cache, budget, held} ->
          {url, cache, budget, held} =
            projection_url(token.value, sheet.base, cache, budget, held)

          budget = projection_take!(Budget.reserve(budget, Budget.cost(:map_entry)))
          {MapSet.put(covered, url), cache, budget, held + Budget.cost(:map_entry)}
        end)
      end)

    {extras, urls, _seen, _cache, budget, held} =
      Enum.reduce(pictures, {[], [], MapSet.new(), cache, budget, held}, fn picture,
                                                                            {extras, urls, seen,
                                                                             cache, budget,
                                                                             held} ->
        {url, cache, budget, held} =
          projection_url(picture.token.value, picture.base_url, cache, budget, held)

        {urls, seen, budget, held} =
          if is_nil(url) or MapSet.member?(seen, url) do
            {urls, seen, budget, held}
          else
            budget = projection_take!(Budget.charge(budget, Budget.cost(:list_cell)))
            bytes = Budget.cost(:map_entry) + Budget.cost(:list_cell)
            budget = projection_take!(Budget.reserve(budget, bytes))
            {[url | urls], MapSet.put(seen, url), budget, held + bytes}
          end

        {extras, budget, held} =
          if is_nil(url) or MapSet.member?(covered, url) or MapSet.member?(group.emitted, url) do
            {extras, budget, held}
          else
            budget = projection_take!(Budget.charge(budget, Budget.cost(:list_cell)))
            budget = projection_take!(Budget.reserve(budget, Budget.cost(:list_cell)))
            {[picture | extras], budget, held + Budget.cost(:list_cell)}
          end

        {extras, urls, seen, cache, budget, held}
      end)

    budget = projection_take!(Budget.charge(budget, Budget.cost(:context, 3)))

    region =
      case request.sheets do
        [sheet | _] -> sheet.region_id
        [] -> :settlement
      end

    context = %{
      css_tokens: tokens,
      css_references: %{region => Enum.reverse(extras)},
      css_revision: revision
    }

    urls = Enum.reverse(urls)
    {:ok, context, urls, projection_take!(Budget.release(budget, held))}
  catch
    {:css_projection_budget, reason} -> {:error, reason}
  end

  defp projection_pictures(pictures, budget, held) do
    {pictures, budget, held} =
      Enum.reduce(pictures, {[], budget, held}, fn picture, {pictures, budget, held} ->
        scratch = Budget.cost(:binary) + byte_size(picture.token.value)
        budget = projection_take!(Budget.reserve(budget, scratch))
        local? = HTMLReferences.local_reference?(picture.token.value)
        budget = projection_take!(Budget.release(budget, scratch))

        if local? do
          {pictures, budget, held}
        else
          bytes = Budget.cost(:list_cell, 2)
          budget = projection_take!(Budget.reserve(budget, bytes))
          {[picture | pictures], budget, held + bytes}
        end
      end)

    {Enum.reverse(pictures), budget, held}
  end

  defp projection_url(value, base, cache, budget, held) do
    key = {value, base}

    case Map.fetch(cache, key) do
      {:ok, url} ->
        {url, cache, budget, held}

      :error ->
        bytes = Budget.cost(:map_entry) + 64
        budget = projection_take!(Budget.reserve(budget, bytes))

        {url, budget} =
          case URL.resolve_result(value, base, budget) do
            {:ok, url, budget} -> {url, budget}
            {:skip, budget} -> {nil, budget}
            {:error, reason} -> throw({:css_projection_budget, reason})
          end

        {url, Map.put(cache, key, url), budget, held + bytes}
    end
  end

  defp projection_take!({:ok, budget}), do: budget
  defp projection_take!({:error, reason}), do: throw({:css_projection_budget, reason})

  defp register(state, receipt, origin, ref, opts, prepared, snapshot, output, mode) do
    key = group_key(opts, prepared.style_group)
    previous = candidate(state, key)

    unchanged? =
      mode != :preview and not Map.has_key?(state.jobs, key) and
        previous.outcome != nil and
        Enum.all?(prepared.sheets, &Map.has_key?(previous.sheets, &1.id)) and
        Enum.all?(prepared.failed, &MapSet.member?(previous.failed, &1))

    if unchanged? and writable?(opts) do
      job = %{
        group: previous,
        revision: previous.revision,
        mode: :cached,
        capacities: prepared.capacities
      }

      snapshot(state, key, job, %{sheets: prepared.sheets}, origin, ref, opts, snapshot, output)
      release(receipt)
      release(output)
      state
    else
      register_changed(state, receipt, origin, ref, opts, prepared, snapshot, output, mode)
    end
  end

  defp register_changed(state, receipt, origin, ref, opts, prepared, snapshot, output, mode) do
    key = group_key(opts, prepared.style_group)
    previous = candidate(state, key)
    known_failed = get_in(state.scopes, [run_key(opts), :failed]) || MapSet.new()
    previous = %{previous | failed: MapSet.union(previous.failed, known_failed)}
    group = stage_group(previous, prepared, receipt)
    revision = {state.incarnation, state.next + 1}
    request = %{sheets: prepared.sheets}

    job = %{
      group: group,
      revision: revision,
      request: request,
      mode: mode,
      capacities: prepared.capacities
    }

    if writable?(opts) and snapshot_bytes(group) <= prepared.capacities.snapshot do
      adopted(receipt)
      run = run_key(opts)

      state =
        if MapSet.member?(state.runs, run),
          do: state,
          else: %{
            state
            | runs: MapSet.put(state.runs, run),
              cleanup: :queue.in(run, state.cleanup)
          }

      state = %{
        state
        | next: state.next + 1,
          run_groups: Map.update(state.run_groups, run, MapSet.new([key]), &MapSet.put(&1, key)),
          retained:
            if(mode == :preview, do: state.retained, else: MapSet.put(state.retained, receipt))
      }

      state =
        if mode == :preview do
          state
        else
          Store.notify_css_revision(opts, elem(key, 2), revision, receipt)
          %{state | jobs: Map.put(state.jobs, key, job)}
        end

      snapshot(state, key, job, request, origin, ref, opts, snapshot, output)
      if mode == :preview, do: release(receipt)
      state
    else
      release(receipt)
      release(snapshot)
      release(output)
      reason = if writable?(opts), do: {:limit, :css_snapshot}, else: :stale
      send(origin, {ref, {:error, reason}})
      state
    end
  end

  defp stage_group(group, prepared, receipt) do
    group =
      Enum.reduce(prepared.sheets, group, fn sheet, group ->
        if Map.has_key?(group.sheets, sheet.id) do
          group
        else
          slot = {sheet.base, sheet.region_id}
          old = group.slots[slot]
          sheet = %{sheet | order: group.next}

          %{
            group
            | sheets: group.sheets |> Map.delete(old) |> Map.put(sheet.id, sheet),
              slots: Map.put(group.slots, slot, sheet.id),
              next: group.next + 1,
              sheet_receipts:
                group.sheet_receipts |> Map.delete(old) |> Map.put(sheet.id, receipt)
          }
        end
      end)

    joined =
      MapSet.union(
        group.joined,
        MapSet.new(prepared.joined ++ Enum.map(prepared.sheets, & &1.base))
      )

    imports = prepared.sheets |> Enum.flat_map(& &1.imports) |> MapSet.new()
    failed = MapSet.union(group.failed, MapSet.new(prepared.failed))

    pending =
      group.pending
      |> MapSet.union(imports)
      |> MapSet.difference(joined)
      |> MapSet.difference(failed)

    %{
      group
      | joined: joined,
        pending: pending,
        failed: failed,
        sources: MapSet.put(group.sources, prepared.source_revision),
        receipts: Map.put(group.receipts, receipt, prepared.bytes)
    }
  end

  defp send_snapshot(state, key, origin, ref, opts, receipt, output, mode, capacities) do
    case state.jobs[key] do
      nil ->
        group = candidate(state, key)

        if not is_nil(group.outcome) do
          job = %{group: group, revision: group.revision, mode: :cached, capacities: capacities}
          snapshot(state, key, job, %{sheets: []}, origin, ref, opts, receipt, output)
        else
          release(receipt)
          send(origin, {ref, {:error, :stale}})
        end

        release(output)

      job ->
        snapshot(
          state,
          key,
          %{job | mode: mode, capacities: capacities},
          %{sheets: []},
          origin,
          ref,
          opts,
          receipt,
          output
        )
    end

    state
  end

  defp snapshot(state, key, job, request, origin, ref, opts, receipt, output) do
    if writable?(opts) and snapshot_bytes(job.group) <= job.capacities.snapshot do
      payload = %{
        cache: self(),
        group: job.group,
        committed: committed(state, key),
        revision: job.revision,
        request: request,
        mode: job.mode,
        output_receipt: output,
        output_capacity: job.capacities.output
      }

      adopted(receipt)

      Store.deliver_resource_async(
        receipt,
        opts[:execution_lease],
        origin,
        {:snapshot, payload},
        origin,
        ref
      )

      release(receipt)
    else
      release(receipt)
      release(output)
      reason = if writable?(opts), do: {:limit, :css_snapshot}, else: :stale
      send(origin, {ref, {:error, reason}})
    end
  end

  defp commit(state, key, revision, receipt, origin, ref, opts, result) do
    case state.jobs[key] do
      %{revision: ^revision} = job ->
        before = committed(state, key)

        emitted =
          if result.emit?,
            do: MapSet.union(job.group.emitted, MapSet.new(result.urls)),
            else: job.group.emitted

        group = %{
          job.group
          | revision: revision,
            outcome: result.outcome,
            urls: result.urls,
            output_receipt: receipt,
            output_bytes: result.bytes,
            emitted: MapSet.union(emitted, before.emitted),
            emission_receipts: Map.merge(job.group.emission_receipts, before.emission_receipts)
        }

        active = MapSet.new(Map.values(group.sheet_receipts))
        superseded = Enum.reject(Map.keys(group.receipts), &MapSet.member?(active, &1))
        group = %{group | receipts: Map.take(group.receipts, MapSet.to_list(active))}
        next = put_group(state, key, group)
        retained = Enum.reduce(superseded, state.retained, &MapSet.delete(&2, &1))
        retained = MapSet.delete(retained, before.output_receipt)
        next = %{next | retained: MapSet.put(retained, receipt), jobs: Map.delete(next.jobs, key)}

        if writable?(opts) and result.outcome.status == :ok and
             result.outcome.revision == revision do
          adopted(receipt)
          Enum.each(superseded, &release/1)
          release(before.output_receipt)
          send(origin, {ref, :ok})
          next
        else
          release(receipt)
          send(origin, {ref, {:error, :stale}})
          state
        end

      %{revision: latest} ->
        release(receipt)
        send(origin, {ref, {:superseded, latest}})
        state

      nil ->
        release(receipt)
        send(origin, {ref, {:error, :stale}})
        state
    end
  end

  defp committed(state, {scope, generation, group}) do
    get_in(state.scopes, [{scope, generation}, :groups, group]) || empty_group()
  end

  defp candidate(state, key) do
    case state.jobs[key] do
      nil -> committed(state, key)
      job -> job.group
    end
  end

  defp put_group(state, {scope, generation, id}, group) do
    run = {scope, generation}
    scope = Map.get(state.scopes, run, %{groups: %{}, failed: MapSet.new()})

    scope = %{
      scope
      | groups: Map.put(scope.groups, id, group),
        failed: MapSet.union(scope.failed, group.failed)
    }

    %{state | scopes: Map.put(state.scopes, run, scope)}
  end

  defp discard_job(state, key) do
    case state.jobs[key] do
      nil ->
        state

      job ->
        committed = committed(state, key)

        Enum.each(Map.keys(job.group.receipts), &release_uncommitted_receipt(&1, committed))

        stale = Enum.reject(Map.keys(job.group.receipts), &Map.has_key?(committed.receipts, &1))

        %{
          state
          | jobs: Map.delete(state.jobs, key),
            retained: Enum.reduce(stale, state.retained, &MapSet.delete(&2, &1))
        }
    end
  end

  defp release_uncommitted_receipt(receipt, committed) do
    if not Map.has_key?(committed.receipts, receipt), do: release(receipt)
  end

  defp discard_run(state, run) do
    keys = Map.get(state.run_groups, run, MapSet.new())
    state = Enum.reduce(keys, state, &discard_job(&2, &1))
    state = %{state | run_groups: Map.delete(state.run_groups, run)}

    case state.scopes[run] do
      nil ->
        %{state | runs: MapSet.delete(state.runs, run)}

      cached ->
        Enum.each(cached.groups, &release_group/1)

        receipts =
          Enum.flat_map(cached.groups, fn {_id, group} ->
            Map.keys(group.receipts) ++
              Map.keys(group.emission_receipts) ++
              List.wrap(group.output_receipt)
          end)

        %{
          state
          | scopes: Map.delete(state.scopes, run),
            runs: MapSet.delete(state.runs, run),
            retained: Enum.reduce(receipts, state.retained, &MapSet.delete(&2, &1))
        }
    end
  end

  defp release_group({_id, group}) do
    Enum.each(Map.keys(group.receipts), &release/1)
    Enum.each(Map.keys(group.emission_receipts), &release/1)
    if group.output_receipt, do: release(group.output_receipt)
  end

  defp empty_group do
    %{
      sheets: %{},
      slots: %{},
      sheet_receipts: %{},
      next: 0,
      pending: MapSet.new(),
      joined: MapSet.new(),
      failed: MapSet.new(),
      sources: MapSet.new(),
      receipts: %{},
      emitted: MapSet.new(),
      emission_receipts: %{},
      revision: nil,
      outcome: nil,
      urls: [],
      output_receipt: nil,
      output_bytes: 0
    }
  end

  defp snapshot_bytes(group),
    do:
      2 *
        (Enum.sum(Map.values(group.receipts)) + Enum.sum(Map.values(group.emission_receipts)) +
           group.output_bytes) + @metadata_bytes

  defp current?(opts),
    do: Authority.current?(opts[:scope], opts[:generation], opts[:queue], opts[:execution_lease])

  defp writable?(opts),
    do:
      Authority.export_writable?(
        opts[:scope],
        opts[:generation],
        opts[:queue],
        opts[:execution_lease]
      )

  defp writable_grant?(receipt, lease, opts),
    do: granted?(receipt, lease, opts) and writable?(opts)

  defp granted?(receipt, lease, opts),
    do:
      lease == opts[:execution_lease] and Authority.resource_current?(receipt, lease, self()) and
        current?(opts)

  defp adopted(receipt), do: send(Store, {:crawler_resource_adopted, receipt, self()})
  defp release(nil), do: :ok
  defp release(receipt), do: settle(receipt, :released)

  defp settle(receipt, result),
    do: send(Store, {:crawler_resource_settled, receipt, self(), result})

  defp await(ref, opts) do
    receive do
      {:crawler_resource_delivery, receipt, lease, _origin, ^ref, payload} ->
        if Authority.resource_current?(receipt, lease, self()) and current?(opts),
          do: {:ok, payload},
          else: {:error, :stale}

      {^ref, result} ->
        result
    after
      Deadline.remaining(opts.crawler_deadline) ->
        {:error, {:deadline, opts.crawler_deadline.kind}}
    end
  end

  defp retain_obligation(_facts, :preview), do: :ok
  defp retain_obligation(facts, _mode), do: Store.retain_resource(facts, Process.whereis(Store))

  defp complete(opts, key, revision, result),
    do: Store.complete_css(opts[:execution_lease], elem(key, 2), revision, result)

  defp call(request) do
    GenServer.call(__MODULE__, request)
  catch
    :exit, _reason -> {:error, :css_cache_unavailable}
  end

  defp local_groups(groups, opts) do
    Enum.reduce_while(groups, {:ok, empty_context()}, fn group, {:ok, context} ->
      outcome = Variables.analyze(group.sheets, true, Limits.css(opts))

      case outcome.status do
        :ok ->
          request = %{sheets: Enum.map(group.sheets, &Map.put(&1, :region_id, &1.id))}
          projected = project(outcome.pictures, request, empty_group(), outcome.revision)
          {:cont, {:ok, merge_context(context, projected)}}

        {:limited, limit} ->
          {:halt, {:error, {:limit, {:css_graph, limit}}}}
      end
    end)
  end

  defp legacy_group(opts, body, analysis) do
    sheet =
      Variables.sheet(analysis, :legacy, sheet_base(opts), 0)
      |> Map.put(
        :imports,
        Enum.filter(analysis.resources, &(Map.get(&1, :kind) == :import))
      )

    %{style_group: group_id(opts), source_revision: source_revision(body), sheets: [sheet]}
  end

  defp empty_context, do: %{css_tokens: %{}, css_references: %{}, css_revision: []}

  defp merge_context(left, right) do
    %{
      css_tokens: Map.merge(left.css_tokens, right.css_tokens),
      css_references: Map.merge(left.css_references, right.css_references),
      css_revision: [right.css_revision | List.wrap(left.css_revision)]
    }
  end

  defp unwrap({:error, {:limit, {:css_graph, limit}}}),
    do: raise(Variables.LimitError, limit: limit)

  defp unwrap({:error, reason}) when reason != :stale, do: raise(Error, reason: reason)
  defp unwrap(result), do: result
  defp group_key(opts, group), do: {opts[:scope], opts[:generation], group}
  defp run_key(opts), do: {opts[:scope], opts[:generation]}
  defp source_revision(body), do: :crypto.hash(:sha256, body)
  defp group_id(opts), do: opts[:style_group] || opts[:document_url] || opts[:url]
  defp sheet_base(opts), do: opts[:referrer_url] || opts[:url]
  defp server?, do: is_pid(Process.whereis(__MODULE__))

  defp managed_stylesheet?(opts),
    do:
      server?() and not is_nil(opts[:generation]) and
        Map.get(opts, :mode, :stylesheet) == :stylesheet

  defp authority_options(opts),
    do: Map.take(opts, [:scope, :generation, :queue, :execution_lease])

  defp normalize(opts) when is_list(opts), do: normalize(Map.new(opts))

  defp normalize(opts) when is_map(opts) do
    lease = opts[:execution_lease] || Process.get(:crawler_execution_lease)

    if is_reference(lease) and
         Authority.current?(opts[:scope], opts[:generation], opts[:queue], lease),
       do: Map.put(opts, :execution_lease, lease),
       else: opts
  end

  defp normalize(_opts), do: %{}
  defp resolve_picture(%{token: %{value: value}, base_url: base}), do: resolve_value(value, base)

  defp resolve_value(value, base) do
    if HTMLReferences.local_reference?(value) do
      nil
    else
      case URL.resolve(value, base) do
        {:ok, url} -> url
        :skip -> nil
      end
    end
  end

  defp covered_urls(tokens, base),
    do:
      tokens |> Enum.map(&resolve_value(&1.value, base)) |> Enum.reject(&is_nil/1) |> MapSet.new()
end
