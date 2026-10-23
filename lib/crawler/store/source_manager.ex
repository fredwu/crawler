defmodule Crawler.Store.SourceManager do
  @moduledoc false

  alias Crawler.Frontier.Ring
  alias Crawler.Store.Authority
  alias Crawler.Store.DecodedSource
  alias Crawler.Store.ResourceManager
  alias Crawler.Store.Resources
  alias Crawler.Store.Retained
  alias Crawler.Store.SourceCache

  @root_host 4096
  @slot_host 16_384
  @waiter_host 1024
  @lease_host 4096
  @bounds %{max_visits: 1, max_effects: 10}
  @decoded_bounds %{max_visits: 1, max_effects: 1}

  def request(state, opts, command, worker) do
    with {:ok, ref} <- input_receipt(command),
         {:ok, grant} <- incoming_grant(state, opts, worker, ref) do
      {reply, state} = funded_request(state, opts, command, grant)
      {reply, defer_release(state, ref)}
    else
      error -> {error, state}
    end
  end

  defp funded_request(state, opts, command, grant) do
    with :ok <- context_limits(state, opts),
         {:ok, workspace, state} <-
           reserve_workspace(
             state,
             opts,
             max(request_workspace(command) - state.source_cache_workspace, 0)
           ) do
      {reply, state} = consume_request(state, opts, command, grant)
      {reply, defer_workspace(state, workspace)}
    else
      {{:error, _} = error, state} -> {error, state}
      error -> {error, state}
    end
  end

  defp context_limits(state, opts) do
    claim = opts[:scheduler_claim]

    with %{job: id} <- state.scheduler.claims[claim],
         %{job: %Crawler.Job{opts: owned}} <- state.scheduler.frontier.jobs[id] do
      limits = opts[:analysis_limits]
      expected = Map.new(Crawler.Limits.analysis(owned))

      valid =
        is_map(limits) and map_size(limits) == 11 and
          Crawler.Analysis.Limits.new(limits) === {:ok, limits} and
          Enum.all?(expected, fn {key, ceiling} -> limits[key] <= ceiling end) and
          limits[:max_bytes] === opts[:max_body] and
          limits[:max_total_bytes] === opts[:max_analysis_bytes] and
          Enum.all?(
            [:max_interpretations, :max_pending, :max_frontier_bytes, :max_retained_bytes],
            fn key -> is_integer(opts[key]) and opts[key] >= 0 and opts[key] <= owned[key] end
          )

      if valid, do: :ok, else: {:error, :invalid_limits}
    else
      _ -> {:error, :stale}
    end
  end

  defp input_receipt({:acquire, _, attempt, ref})
       when is_reference(attempt) and is_reference(ref),
       do: {:ok, ref}

  defp input_receipt({:publish, _, %{copy_receipt: ref}}) when is_reference(ref),
    do: {:ok, ref}

  defp input_receipt({:acquire_decoded, attempt, ref})
       when is_reference(attempt) and is_reference(ref),
       do: {:ok, ref}

  defp input_receipt({:publish_decoded, _, %{copy_receipt: ref}}) when is_reference(ref),
    do: {:ok, ref}

  defp input_receipt(_), do: {:error, :invalid_source_command}

  defp request_workspace({kind, _, _}) when kind in [:acquire_decoded, :publish_decoded],
    do: DecodedSource.context_workspace()

  defp request_workspace(_), do: 98_304

  defp incoming_grant(state, opts, worker, ref) do
    lease = opts[:execution_lease]

    with %{arena: arena, worker: ^worker} <- state.executions[lease],
         %{kind: :response, actual: actual, copy_bytes: copy, holders: holders} = record
         when is_integer(actual) and is_integer(copy) <- Resources.receipt(state.resources, ref),
         %{status: :pending, lease: ^lease, arena: ^arena, origin: ^worker} <- holders[self()],
         true <- Resources.current?(state.resources, ref, lease, worker) do
      {:ok, record}
    else
      _ -> {:error, :stale_resource}
    end
  end

  defp consume_request(state, opts, command, grant) do
    payload = {:source_cache, opts, command}

    with :ok <- preflight_context(opts, command),
         {:ok, _bytes} <- Retained.bytes(payload, grant.actual),
         {:ok, _copy} <- Retained.copy_bytes(payload, grant.copy_bytes) do
      case command do
        {:acquire, key, attempt, _} -> acquire(state, opts, key, attempt)
        {:publish, token, entry} -> publish(state, opts, token, entry)
        {:acquire_decoded, attempt, _} -> acquire_decoded(state, opts, attempt)
        {:publish_decoded, token, capsule} -> publish_decoded(state, opts, token, capsule)
      end
    else
      error -> {error, state}
    end
  end

  defp decode_context(opts), do: %{content_type: opts[:content_type], headers: opts[:headers]}

  defp preflight_context(opts, {:publish_decoded, token, capsule}) do
    with {:ok, _} <- decoded_token(opts, token),
         :ok <- validate_capsule(capsule, opts.analysis_limits),
         do: preflight_context(opts, {:acquire_decoded, nil, nil})
  end

  defp preflight_context(opts, {:acquire_decoded, _, _}) do
    case DecodedSource.context_bytes(
           decode_context(opts),
           Crawler.Limits.decoded_context(opts),
           %{
             retained_bytes: 0,
             workspace_bytes: DecodedSource.context_workspace()
           }
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp preflight_context(_opts, _command), do: :ok

  def acquire_decoded(state, opts, attempt) do
    case source(state, opts) do
      {:ok, source} ->
        with {:ok, id, state} <- ensure(state, opts, source),
             {:ok, state} <- ensure_decoded(state, id, opts) do
          case command(
                 state,
                 id,
                 :decoded,
                 {:acquire, decode_context(opts), opts.target_handle, opts.execution_lease,
                  attempt},
                 opts
               ) do
            {{:decoded, capsule}, state} -> import_decoded(state, opts, capsule)
            other -> other
          end
        else
          {{:error, _} = error, failed} -> {error, failed}
          error -> {error, state}
        end

      :private ->
        {{:decode, nil}, state}

      error ->
        {error, state}
    end
  end

  def publish_decoded(state, opts, token, capsule) do
    with {:ok, id} <- decoded_token(opts, token),
         {:ok, _source} <- source(state, opts),
         :ok <- validate_capsule(capsule, opts.analysis_limits),
         :ok <- publication_grants(state, opts, capsule) do
      command(state, id, :decoded, {:publish, token, capsule}, opts)
    else
      error -> {error, state}
    end
  end

  defp validate_capsule(
         %{
           body: body,
           decoder_seed: seed,
           unavailable: unavailable,
           root_ownership: ownership,
           limits: limits,
           source_revision: revision,
           decode_context: _,
           retained_receipts: retained,
           backing_receipts: backing,
           copy_receipt: copy
         } = capsule,
         limits
       )
       when map_size(capsule) == 10 and is_reference(revision) and is_reference(copy) do
    with true <-
           (receipt_list?(retained, 4) and receipt_list?(backing, 4)) ||
             {:error, :invalid_capsule},
         do: validate_decoder(body, %{budget: seed, unavailable: unavailable}, ownership, limits)
  end

  defp validate_capsule(_, _), do: {:error, :invalid_capsule}

  defp decoded_token(
         %{source_revision: revision, target_handle: target, execution_lease: lease},
         {revision, target, lease, attempt}
       )
       when is_reference(revision) and is_reference(target) and is_reference(lease) and
              is_reference(attempt),
       do: {:ok, revision}

  defp decoded_token(_, _), do: {:error, :stale_token}

  def validate_decoder(
        body,
        %{budget: %Crawler.Analysis.Budget{} = seed, unavailable: unavailable} = checkpoint,
        ownership,
        limits
      )
      when is_binary(body) and is_map(limits) and map_size(limits) == 11 and
             map_size(checkpoint) == 2 and is_integer(unavailable) and unavailable >= 0 and
             ownership in [:borrowed, :retained] do
    with {:ok, ^limits} <- Crawler.Analysis.Limits.new(limits),
         true <- valid_seed?(seed, unavailable, limits) || {:error, :invalid_decoder_seed},
         true <- byte_size(body) <= limits.max_bytes || {:error, {:limit, :max_body}},
         true <-
           ownership == :borrowed or
             seed.retained - unavailable >= :binary.referenced_byte_size(body) + 64 ||
             {:error, :invalid_decoder_seed},
         do: :ok
  end

  def validate_decoder(_, _, _, _), do: {:error, :invalid_decoder_seed}

  defp valid_seed?(seed, unavailable, limits) do
    expected = Crawler.Analysis.Budget.new(limits)

    map_size(seed) == 7 and seed.limit === expected.limit and seed.caps === expected.caps and
      seed.scratch === 0 and
      is_integer(seed.retained) and seed.retained >= unavailable and
      is_integer(seed.peak) and seed.peak >= seed.retained and seed.peak <= seed.limit and
      is_map(seed.counts) and map_size(seed.counts) == 4 and
      Enum.all?(expected.caps, fn {key, cap} ->
        is_integer(seed.counts[key]) and seed.counts[key] >= 0 and seed.counts[key] <= cap
      end)
  end

  defp ensure_decoded(state, id, opts) do
    row = state.source_caches[id]
    if row.decoded, do: {:ok, state}, else: create_decoded(state, id, row, opts)
  end

  defp create_decoded(state, id, row, opts) do
    caps = %{
      pending: min(opts.max_pending, state.scheduler.frontier.limits.max_pending),
      context_bytes: Crawler.Limits.decoded_context(opts)
    }

    quote = %{retained_bytes: 0, workspace_bytes: DecodedSource.context_workspace()}

    with {:ok, price} <- DecodedSource.requirements_new(id, decode_context(opts), caps, quote),
         prepaid = %{quote | retained_bytes: price.retained_bytes},
         cleanup = DecodedSource.cleanup_workspace_for_caps(caps),
         growth = price.retained_bytes + max(cleanup - state.source_cache_workspace, 0),
         {:ok, state} <- transfer(state, opts, growth) do
      {:ok, decoded} = DecodedSource.new(id, decode_context(opts), caps, prepaid)
      next = %{row | decoded: decoded, charge: row.charge + price.retained_bytes}
      state = update(state, id, fn _ -> next end)
      state = %{state | source_cache_workspace: max(state.source_cache_workspace, cleanup)}
      {:ok, account_run(state, row.run, price.retained_bytes)}
    else
      {{:error, _} = error, state} -> {error, state}
      {:error, _} = error -> {error, state}
    end
  end

  defp import_decoded(state, opts, capsule) do
    credit = %{
      retained: [],
      backing: [make_ref()],
      unavailable: capsule.decoder_seed.retained,
      root_ownership: :borrowed
    }

    root =
      capsule
      |> Map.drop([:copy_receipt, :retained_receipts, :backing_receipts])
      |> Map.put(:original_root_ownership, capsule.root_ownership)
      |> Map.put(:root_ownership, :borrowed)
      |> Map.put(:credit, credit)

    %{arena: arena} = state.executions[opts.execution_lease]

    with true <-
           capsule.limits === opts.analysis_limits || {:error, {:limit, :historical_analysis}},
         :ok <-
           validate_decoder(
             capsule.body,
             %{budget: capsule.decoder_seed, unavailable: capsule.unavailable},
             capsule.root_ownership,
             capsule.limits
           ),
         {:ok, bytes} <- Retained.bytes({:decoded, root}, opts.max_retained_bytes),
         {:ok, copy} <- Retained.copy_bytes({:decoded, root}, opts.max_retained_bytes),
         {{:ok, receipt}, resources, effects} <-
           independent(
             state.resources,
             arena,
             opts.execution_lease,
             :response,
             max(bytes, copy),
             copy
           ) do
      {_, state} = ResourceManager.transition(state, {:ok, resources, effects})
      {{:decoded, %{root | credit: %{credit | backing: [receipt]}}}, state}
    else
      {{:error, reason}, _virtual, _effects} -> {{:error, reason}, state}
      error -> {error, state}
    end
  end

  def acquire(state, opts, key, attempt) do
    case source(state, opts) do
      {:ok, source} ->
        with {:ok, id, state} <- ensure(state, opts, source),
             {result, state} <-
               command(
                 state,
                 id,
                 {:acquire, key, opts.target_handle, opts.execution_lease, attempt},
                 opts
               ) do
          case result do
            {:candidate, entry} -> import(state, opts, entry)
            other -> {other, state}
          end
        else
          {:error, reason} -> {{:error, reason}, state}
          {{:error, reason}, failed} -> {{:error, reason}, failed}
        end

      :private ->
        {{:compute, nil}, state}

      error ->
        {error, state}
    end
  end

  def publish(state, opts, token, entry) do
    with {:ok, id} <- publication_token(opts, token),
         {:ok, _source} <- source(state, opts),
         :ok <- decoded_entry(entry),
         :ok <- publication_grants(state, opts, entry) do
      case command(state, id, {:publish, token, entry}, opts) do
        {:published, state} -> {:ok, state}
        {error, state} -> {error, state}
      end
    else
      error -> {error, state}
    end
  end

  defp publication_token(
         %{source_revision: revision, target_handle: target, execution_lease: lease},
         {revision, slot, target, lease, attempt}
       )
       when is_reference(revision) and is_reference(slot) and is_reference(target) and
              is_reference(lease) and is_reference(attempt),
       do: {:ok, revision}

  defp publication_token(_, _), do: {:error, :stale_token}

  defp decoded_entry(%{
         analysis: %Crawler.Analysis{
           root: root,
           regions: regions,
           source_options: source_options,
           allocation: %{seed: %Crawler.Analysis.Budget{scratch: 0}}
         }
       })
       when is_map(regions) and is_map(source_options) do
    if match?(%{source: body} when is_binary(body), regions[root]),
      do: :ok,
      else: {:error, :invalid_entry}
  end

  defp decoded_entry(_), do: {:error, :invalid_entry}

  defp publication_grants(state, opts, %{
         retained_receipts: retained,
         backing_receipts: backing,
         copy_receipt: copy
       })
       when is_reference(copy) do
    with true <- receipt_list?(retained, 4) and receipt_list?(backing, 4),
         %{arena: arena, worker: worker} <- state.executions[opts.execution_lease] do
      refs = [copy | retained ++ backing]

      if Enum.all?(refs, &publication_grant?(state, &1, opts.execution_lease, arena, worker)),
        do: :ok,
        else: {:error, :stale_resource}
    else
      false -> {:error, :invalid_entry}
      _ -> {:error, :stale}
    end
  end

  defp publication_grants(_state, _opts, _entry), do: {:error, :invalid_entry}

  defp receipt_list?([], _left), do: true

  defp receipt_list?([ref | rest], left) when is_reference(ref) and left > 0,
    do: receipt_list?(rest, left - 1)

  defp receipt_list?(_, _left), do: false

  defp publication_grant?(state, ref, lease, arena, worker) do
    case Resources.receipt(state.resources, ref) do
      %{actual: actual, holders: holders} when is_integer(actual) ->
        match?(%{lease: ^lease, arena: ^arena}, holders[self()]) and
          Resources.current?(state.resources, ref, lease, worker) and
          Resources.current?(state.resources, ref, lease, self())

      _ ->
        false
    end
  end

  def execution_ended(state, lease) do
    if Map.has_key?(state.source_cache_leases, lease),
      do: enqueue(state, {:lease, lease}),
      else: state
  end

  def retire_source(state, %{lexical: id}) do
    update(state, id, &%{&1 | retired?: true}) |> schedule(id)
  end

  def retire_source(state, _source), do: state

  def release_source(state, %{receipt: ref} = source),
    do: state |> retire_source(source) |> defer_release(ref)

  def drain(state) do
    state = %{state | source_cache_scheduled?: false}

    case Ring.take(state.source_cache_pending) do
      :empty ->
        state

      {:ok, item, pending} ->
        state = %{state | source_cache_pending: pending}
        state |> drain_item(item) |> schedule_pending()
    end
  end

  defp drain_item(state, {:cache, id}) do
    case state.source_caches[id] do
      nil -> state
      row -> cleanup(state, id, row)
    end
  end

  defp drain_item(state, {:lease, lease}) do
    ring = Map.get(state.source_cache_leases, lease, Ring.new())

    case Ring.take(ring) do
      :empty ->
        state

      {:ok, id, _remaining} ->
        case state.source_caches[id] do
          nil ->
            unlink(state, id, lease)

          _ ->
            update(state, id, &%{&1 | ended: Ring.put(&1.ended, {lease, :cache})}) |> schedule(id)
        end
    end
  end

  def refund(state) do
    state = %{
      state
      | source_cache_bytes: state.source_cache_bytes - state.source_cache_refund,
        source_cache_refund: 0,
        source_cache_refund_scheduled?: false
    }

    state = refund_runs(state, 16)
    {refs, state} = take_releases(state, 16, [])
    state = Enum.reduce(refs, state, &release_deferred/2)

    if Ring.size(state.source_cache_releases) + Ring.size(state.source_cache_refund_runs) > 0,
      do: defer_refund(state, 0),
      else: state
  end

  defp cleanup(state, id, %{retired?: true, cache: %{status: :live}}) do
    {_result, state} = command(state, id, :retire, nil)
    schedule(state, id)
  end

  defp cleanup(state, id, %{retired?: true, decoded: %{status: status}})
       when status != :retiring do
    {_result, state} = command(state, id, :decoded, :retire, nil)
    schedule(state, id)
  end

  defp cleanup(state, id, row) do
    case Ring.take(row.ended) do
      {:ok, {lease, cell}, ended} ->
        cleanup_lease(state, id, row, lease, cell, ended)

      :empty ->
        drain_cells(state, id, row)
    end
  end

  defp cleanup_lease(state, id, row, lease, cell, ended) do
    {result, state} = command(state, id, cell, {:owner_down, lease}, nil)

    if result == :ok or match?({:done, _}, result) do
      ended =
        if cell == :cache and row.decoded, do: Ring.put(ended, {lease, :decoded}), else: ended

      state |> update(id, &%{&1 | ended: ended}) |> maybe_unlink(id, lease) |> schedule(id)
    else
      schedule(state, id)
    end
  end

  defp drain_cells(state, id, row) do
    {result, state} = command(state, id, {:drain, 1}, nil)

    cond do
      match?({:more, _}, result) -> schedule(state, id)
      row.decoded -> drain_decoded(state, id, row)
      row.retired? -> drop_link(state, id)
      true -> state
    end
  end

  defp drain_decoded(state, id, row) do
    {result, state} = command(state, id, :decoded, :drain, nil)

    cond do
      match?({:more, _}, result) -> schedule(state, id)
      row.retired? -> drop_link(state, id)
      true -> state
    end
  end

  defp command(state, id, command, opts), do: command(state, id, :cache, command, opts)

  defp command(state, id, cell, command, opts) do
    case state.source_caches[id] do
      nil -> {{:error, :source_retired}, state}
      row -> transition(state, id, row, cell, command, opts)
    end
  end

  defp transition(state, id, row, cell, command, opts) do
    quote_bytes =
      if opts,
        do: max(state.source_cache_workspace, cell_workspace(cell)),
        else: state.source_cache_workspace

    case reserve_workspace(state, opts, quote_bytes - state.source_cache_workspace) do
      {:ok, quote_ref, state} ->
        result = price_transition(state, id, row, cell, command, opts, quote_bytes)

        case result do
          {reply, state} -> {reply, defer_workspace(state, quote_ref)}
        end

      {error, state} ->
        {error, state}
    end
  end

  defp price_transition(state, id, row, cell, command, opts, quote_bytes) do
    quote = %{retained_bytes: 0, workspace_bytes: quote_bytes}

    case cell_module(cell).requirements(row[cell], command, cell_bounds(cell), quote) do
      {:ok, price} ->
        case reserve_workspace(state, opts, max(price.workspace_bytes - quote_bytes, 0)) do
          {:ok, extra_ref, state} ->
            {result, state} = funded_transition(state, id, row, cell, command, opts, price)
            {result, defer_workspace(state, extra_ref)}

          {error, state} ->
            {error, state}
        end

      error ->
        {error, state}
    end
  end

  defp funded_transition(state, id, row, cell, command, opts, price) do
    growth =
      price.retained_bytes +
        if(price.retained_bytes > 0, do: cell_growth(cell), else: 0) +
        link_growth(row, command)

    case transfer(state, opts, growth) do
      {:ok, state} ->
        prepaid = %{retained_bytes: price.retained_bytes, workspace_bytes: price.workspace_bytes}

        {result, cache, effects, _stats} =
          cell_module(cell).transition(row[cell], command, cell_bounds(cell), prepaid)

        if live_execution?(state, opts) do
          finish_transition(
            state,
            id,
            Map.put(row, cell, cache),
            cell,
            command,
            result,
            effects,
            growth
          )
        else
          {{:error, :stale}, defer_refund(state, growth)}
        end

      {:error, reason} ->
        {{:error, reason}, state}

      {error, state} ->
        {error, state}
    end
  end

  defp live_execution?(_state, nil), do: true

  defp live_execution?(state, opts) do
    case state.executions[opts.execution_lease] do
      %{worker: worker} -> Authority.execution_current?(opts.execution_lease, worker)
      _ -> false
    end
  end

  defp finish_transition(state, id, row, cell, command, result, effects, growth) do
    case adopt_publication(state, command, publication_result(cell, result)) do
      {:ok, state} ->
        {state, row} = transition_link(state, id, row, cell, command, result)
        next = %{row | charge: row_charge(row)}
        state = update(state, id, fn _ -> next end)
        delta = next.charge - row.charge
        state = account_run(state, row.run, delta)
        state = defer_refund(state, growth - max(delta, 0))
        state = transition_effects(state, id, command, result, effects)

        state =
          if match?({:publish, _, _}, command) and publication_result(cell, result) == :published,
            do: schedule(state, id),
            else: state

        {result, state}

      error ->
        {error, defer_refund(state, growth)}
    end
  end

  defp cell_module(:cache), do: SourceCache
  defp cell_module(:decoded), do: DecodedSource
  defp cell_bounds(:cache), do: @bounds
  defp cell_bounds(:decoded), do: @decoded_bounds
  defp cell_workspace(:cache), do: 98_304
  defp cell_workspace(:decoded), do: DecodedSource.context_workspace()
  defp cell_growth(:cache), do: @slot_host + @waiter_host
  defp cell_growth(:decoded), do: 0
  defp publication_result(:decoded, :ok), do: :published
  defp publication_result(_, result), do: result

  defp link_growth(row, {:acquire, _, _, lease, _}),
    do: if(Map.has_key?(row.links.members, lease), do: 0, else: @lease_host)

  defp link_growth(_row, _command), do: 0

  defp transition_effects(state, _id, {:publish, _, _}, {:error, _}, effects),
    do: Enum.reduce(effects, state, fn {:release, ref}, state -> defer_release(state, ref) end)

  defp transition_effects(state, id, _command, _result, effects),
    do: Enum.reduce(effects, state, &effect(&1, &2, id))

  defp reserve_workspace(state, _opts, 0), do: {:ok, nil, state}
  defp reserve_workspace(state, nil, _bytes), do: {{:error, :cleanup_workspace}, state}

  defp reserve_workspace(state, opts, bytes) do
    case state.executions[opts.execution_lease] do
      %{arena: arena, worker: worker} ->
        with {{:ok, receipt}, resources, reserved} <-
               Resources.reserve(
                 state.resources,
                 arena,
                 opts.execution_lease,
                 :scratch,
                 bytes,
                 self()
               ),
             {:ok, resources, adopted} <- Resources.adopt(resources, receipt, self()) do
          {_, state} = ResourceManager.transition(state, {:ok, resources, reserved ++ adopted})

          state = %{
            state
            | source_cache_workspaces: Map.put(state.source_cache_workspaces, receipt, worker)
          }

          {:ok, receipt, state}
        else
          {error, _virtual, _effects} -> {error, state}
        end

      _ ->
        {{:error, :stale}, state}
    end
  end

  defp defer_workspace(state, nil), do: state
  defp defer_workspace(state, ref), do: defer_release(state, ref)

  defp ensure(state, _opts, %{lexical: id}), do: {:ok, id, state}

  defp ensure(state, opts, source) do
    caps = %{
      slots: min(opts.max_interpretations, state.scheduler.frontier.limits.max_interpretations),
      waiters: min(opts.max_pending, state.scheduler.frontier.limits.max_pending),
      key_bytes: min(opts.max_frontier_bytes, opts.max_analysis_bytes)
    }

    id = opts.source_revision

    with {:ok, cache} <-
           SourceCache.new(id, caps, %{retained_bytes: 4096, workspace_bytes: 4096}),
         {:ok, run_bytes} <-
           Retained.bytes({opts.scope, opts.generation}, opts.max_frontier_bytes),
         cleanup = SourceCache.cleanup_workspace(cache),
         workspace_growth = max(cleanup - state.source_cache_workspace, 0),
         root = @root_host + run_bytes,
         bytes = charge(cache, root, Ring.new()),
         {:ok, state} <- transfer(state, opts, bytes + workspace_growth) do
      row = %{
        cache: cache,
        run: {opts.scope, opts.generation},
        charge: bytes,
        root_charge: root,
        decoded: nil,
        retired?: false,
        links: Ring.new(),
        ended: Ring.new()
      }

      representation = state.scheduler.representations[opts.representation_id]
      representation = %{representation | source: Map.put(source, :lexical, id)}

      scheduler = %{
        state.scheduler
        | representations:
            Map.put(state.scheduler.representations, opts.representation_id, representation)
      }

      state = %{
        state
        | scheduler: scheduler,
          source_caches: Map.put(state.source_caches, id, row),
          source_cache_workspace: max(state.source_cache_workspace, cleanup)
      }

      {:ok, id, account_run(state, row.run, bytes)}
    end
  end

  defp transfer(state, _opts, 0), do: {:ok, state}
  defp transfer(_state, nil, _bytes), do: {:error, :cleanup_growth}

  defp transfer(state, opts, bytes) do
    case state.executions[opts.execution_lease] do
      %{arena: arena} ->
        case ResourceManager.transition(
               state,
               Resources.transfer_external(state.resources, arena, opts.execution_lease, bytes)
             ) do
          {:ok, state} -> {:ok, %{state | source_cache_bytes: state.source_cache_bytes + bytes}}
          {error, state} -> {error, state}
        end

      _ ->
        {:error, :stale}
    end
  end

  defp charge(cache, root, links),
    do:
      root + cache.metadata_bytes +
        :gb_trees.size(cache.slots) * @slot_host + :gb_trees.size(cache.waiters) * @waiter_host +
        Ring.size(links) * @lease_host

  defp row_charge(row),
    do:
      charge(row.cache, row.root_charge, row.links) +
        if(row.decoded, do: row.decoded.metadata_bytes, else: 0)

  defp source(state, opts) do
    case state.scheduler.representations[opts[:representation_id]] do
      %{source: %{value: response} = source} ->
        if Req.Response.get_private(response, :crawler_source_revision) ===
             opts[:source_revision],
           do: {:ok, source},
           else: {:error, :source_superseded}

      %{source: nil} ->
        :private

      _ ->
        {:error, :source_retired}
    end
  end

  defp adopt_publication(state, {:publish, _, entry}, :published) do
    refs = Enum.uniq([entry.copy_receipt | entry.retained_receipts ++ entry.backing_receipts])

    result =
      Enum.reduce_while(refs, {:ok, state.resources, []}, fn ref, {:ok, resources, effects} ->
        case Resources.adopt(resources, ref, self()) do
          {:ok, resources, next} -> {:cont, {:ok, resources, effects ++ next}}
          {error, _, _} -> {:halt, error}
        end
      end)

    case result do
      {:ok, resources, effects} ->
        {_, state} = ResourceManager.transition(state, {:ok, resources, effects})

        held =
          Enum.reduce(refs, state.source_cache_resources, fn ref, held ->
            Map.update(held, ref, 1, &(&1 + 1))
          end)

        {:ok, %{state | source_cache_resources: held}}

      error ->
        error
    end
  end

  defp adopt_publication(state, _command, _result), do: {:ok, state}

  defp effect({:release, ref}, state, _id) do
    case state.source_cache_resources[ref] do
      count when is_integer(count) and count > 1 ->
        %{state | source_cache_resources: Map.put(state.source_cache_resources, ref, count - 1)}

      _ ->
        defer_release(
          %{state | source_cache_resources: Map.delete(state.source_cache_resources, ref)},
          ref
        )
    end
  end

  defp effect({:wake, target, lease, reason}, state, id) do
    case state.executions[lease] do
      %{worker: worker} -> send(worker, {:crawler_source_cache, id, target, lease, reason})
      _ -> :ok
    end

    maybe_unlink(state, id, lease)
  end

  defp effect({:wake, id, target, lease, reason}, state, id) do
    case state.executions[lease] do
      %{worker: worker} -> send(worker, {:crawler_decoded_source, id, target, lease, reason})
      _ -> :ok
    end

    maybe_unlink(state, id, lease)
  end

  defp transition_link(state, id, row, _cell, {:acquire, _, _, lease, _}, result)
       when elem(result, 0) in [:compute, :decode, :waiting] do
    links = Ring.put(row.links, lease)
    ring = state.source_cache_leases |> Map.get(lease, Ring.new()) |> Ring.put(id)

    {%{state | source_cache_leases: Map.put(state.source_cache_leases, lease, ring)},
     %{row | links: links}}
  end

  defp transition_link(state, id, row, :cache, {:publish, {_, _, _, lease, _}, _}, :published),
    do: remove_unused_link(state, id, row, lease)

  defp transition_link(state, _id, row, _cell, _command, _result), do: {state, row}

  defp remove_unused_link(state, id, row, lease),
    do: if(obligation?(row, lease), do: {state, row}, else: remove_link(state, id, row, lease))

  defp obligation?(row, lease) do
    :gb_trees.is_defined(lease, row.cache.leases) or decoded_obligation?(row.decoded, lease)
  end

  defp decoded_obligation?(nil, _lease), do: false

  defp decoded_obligation?(root, lease) do
    token_lease?(root.producer, lease) or token_lease?(root.published_token, lease) or
      :gb_trees.is_defined(lease, root.waiters)
  end

  defp token_lease?(nil, _lease), do: false
  defp token_lease?({_, _, lease, _}, lease), do: true
  defp token_lease?(_, _), do: false

  defp remove_link(state, id, row, lease),
    do: {unlink(state, id, lease), %{row | links: Ring.delete(row.links, lease)}}

  defp unlink(state, id, lease) do
    ring = state.source_cache_leases |> Map.get(lease, Ring.new()) |> Ring.delete(id)

    leases =
      if Ring.size(ring) == 0,
        do: Map.delete(state.source_cache_leases, lease),
        else: Map.put(state.source_cache_leases, lease, ring)

    state = %{state | source_cache_leases: leases}

    if not Map.has_key?(state.executions, lease) and Ring.size(ring) > 0,
      do: enqueue(state, {:lease, lease}),
      else: state
  end

  defp maybe_unlink(state, id, lease) do
    row = state.source_caches[id]

    if obligation?(row, lease) do
      state
    else
      {state, row} = remove_link(state, id, row, lease)
      next = %{row | charge: row_charge(row)}
      old = state.source_caches[id]
      state = update(state, id, fn _ -> next end)
      account_run(state, row.run, next.charge - old.charge)
    end
  end

  defp drop_link(state, id) do
    row = state.source_caches[id]

    case Ring.take(row.links) do
      :empty -> drop(state, id)
      {:ok, lease, _} -> state |> maybe_unlink(id, lease) |> schedule(id)
    end
  end

  defp import(state, opts, entry) do
    analysis = entry.analysis
    root = analysis.regions[analysis.root].source
    arena = state.executions[opts.execution_lease].arena
    lease = opts.execution_lease

    with {:ok, copied} <- Retained.copy_bytes(entry, opts.max_retained_bytes),
         {:ok, copy} <- Retained.copy_bytes(root, opts.max_retained_bytes),
         root_bytes = :binary.referenced_byte_size(root) + 64,
         {{:ok, retained}, resources, first} <-
           independent(
             state.resources,
             arena,
             lease,
             :analysis,
             copied + analysis.allocation.retained + 4096,
             nil
           ),
         {{:ok, backing}, resources, second} <-
           independent(resources, arena, lease, :response, max(root_bytes, copy), copy) do
      {_, state} = ResourceManager.transition(state, {:ok, resources, first ++ second})

      {{:cached, analysis,
        %{
          retained: [retained],
          backing: [backing],
          unavailable: analysis.allocation.seed.retained,
          root_ownership: :borrowed
        }}, state}
    else
      {{:error, reason}, _virtual, _unpublished_effects} -> {{:error, reason}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp independent(resources, arena, lease, kind, bytes, copy) do
    with {{:ok, ref}, resources, effects} <-
           Resources.reserve(resources, arena, lease, kind, bytes, self()),
         {:ok, resources, committed} <- commit_independent(resources, ref, lease, bytes, copy) do
      {{:ok, ref}, resources, effects ++ committed}
    end
  end

  defp commit_independent(resources, ref, lease, bytes, nil),
    do: Resources.commit(resources, ref, lease, bytes)

  defp commit_independent(resources, ref, lease, bytes, copy),
    do: Resources.commit_response(resources, ref, lease, bytes, copy)

  defp release_deferred(ref, state) do
    case Map.pop(state.source_cache_workspaces, ref) do
      {nil, _} ->
        ResourceManager.release_owner(state, ref)

      {worker, workspaces} ->
        state = %{state | source_cache_workspaces: workspaces}

        {_, state} =
          ResourceManager.transition(state, Resources.release(state.resources, ref, self()))

        {_, state} =
          ResourceManager.transition(state, Resources.release(state.resources, ref, worker))

        state
    end
  end

  defp account_run(state, run, delta) when delta < 0 do
    state = %{
      state
      | source_cache_run_refunds:
          Map.update(state.source_cache_run_refunds, run, -delta, &(&1 - delta)),
        source_cache_refund_runs: Ring.put(state.source_cache_refund_runs, run)
    }

    defer_refund(state, 0)
  end

  defp account_run(state, run, delta) do
    bytes = Map.get(state.source_cache_run_bytes, run, 0) + delta

    runs =
      if bytes == 0,
        do: Map.delete(state.source_cache_run_bytes, run),
        else: Map.put(state.source_cache_run_bytes, run, bytes)

    %{state | source_cache_run_bytes: runs}
  end

  defp drop(state, id) do
    row = state.source_caches[id]
    state = %{state | source_caches: Map.delete(state.source_caches, id)}
    state = account_run(state, row.run, -row.charge)

    if map_size(state.source_caches) == 0 do
      bytes = state.source_cache_workspace
      defer_refund(%{state | source_cache_workspace: 0}, bytes)
    else
      state
    end
  end

  defp update(state, id, callback) do
    case state.source_caches[id] do
      nil -> state
      row -> %{state | source_caches: Map.put(state.source_caches, id, callback.(row))}
    end
  end

  defp schedule(state, id), do: enqueue(state, {:cache, id})

  defp enqueue(state, item),
    do:
      schedule_pending(%{state | source_cache_pending: Ring.put(state.source_cache_pending, item)})

  defp schedule_pending(state) do
    if Ring.size(state.source_cache_pending) > 0 and not state.source_cache_scheduled? do
      send(self(), :source_cache_pending)
      %{state | source_cache_scheduled?: true}
    else
      state
    end
  end

  defp defer_release(state, ref),
    do:
      defer_refund(
        %{state | source_cache_releases: Ring.put(state.source_cache_releases, ref)},
        0
      )

  defp defer_refund(state, bytes) when bytes >= 0 do
    if not state.source_cache_refund_scheduled?, do: send(self(), :source_cache_refund)

    %{
      state
      | source_cache_refund: state.source_cache_refund + bytes,
        source_cache_refund_scheduled?: true
    }
  end

  defp take_releases(state, 0, refs), do: {refs, state}

  defp take_releases(state, left, refs) do
    case Ring.take(state.source_cache_releases) do
      :empty ->
        {refs, state}

      {:ok, ref, rest} ->
        take_releases(%{state | source_cache_releases: rest}, left - 1, [ref | refs])
    end
  end

  defp refund_runs(state, 0), do: state

  defp refund_runs(state, left) do
    case Ring.take(state.source_cache_refund_runs) do
      :empty ->
        state

      {:ok, run, ring} ->
        {bytes, pending} = Map.pop(state.source_cache_run_refunds, run)
        remaining = state.source_cache_run_bytes[run] - bytes

        runs =
          if remaining == 0,
            do: Map.delete(state.source_cache_run_bytes, run),
            else: Map.put(state.source_cache_run_bytes, run, remaining)

        state = %{
          state
          | source_cache_run_bytes: runs,
            source_cache_run_refunds: pending,
            source_cache_refund_runs: ring,
            source_cache_bytes: state.source_cache_bytes - bytes
        }

        refund_runs(state, left - 1)
    end
  end
end
