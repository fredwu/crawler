defmodule Crawler.Export.Stage do
  @moduledoc """
  Producer staging under one existing canonical Job and Runtime.

  Call `source/4`, obtain a fresh funded export context, then call `emit_bound`
  once with the owner's dispatch context. Pass its prepaid occurrence-ID to
  canonical-target index to `stage/5`. Missing or rejected observations have
  no target. This module never repeats callbacks or associates targets by URL.
  The caller retains Prepared, binding-index and Page credit through these calls.

  `refresh/3` consumes one prepaid owner batch. Its producer-local callback
  receives `(row, replay, credit, consume)`. It calls
  `consume.(prepared, current_credit, bindings)` synchronously inside its funded
  frames and returns the Stage scalar result. It releases additional credit only
  after `consume` ends. It continues the replay capsule's Analysis and
  Budget when obtaining the current CSS snapshot; it must not analyze again.
  The caller retains the batch receipt until this consumer frame has ended.
  The projection grant covers the complete retained-copy quote and an additional
  structural bound for CSS memberships: eight list cells and two map-entry tariffs
  per group, plus a frame per query batch and final map. These pay the reverse,
  split, ID and pair lists and one final membership map. Query replies retain
  their own grants through consumption. Pair-list accumulation shares its tails;
  it does not retain successive growing map copies. These are spending quotes
  against current Resources credit, not a new envelope or Analysis budget seed.

  Staging acknowledges private metadata, never archive readiness or local paths.
  """

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Export.Runtime
  alias Crawler.Export.StagedIO
  alias Crawler.Export.StagedIO.Plan
  alias Crawler.Parser.Prepared
  alias Crawler.Store
  alias Crawler.Store.Retained

  @walk_workspace 98_304

  def source(%Runtime{} = runtime, %Prepared{} = prepared, credit, assignment) do
    with_context(runtime, fn export ->
      with :ok <- assigned(runtime, export, assignment),
           :ok <- physical_source(prepared),
           do: register_source(runtime, export, prepared, credit, assignment)
    end)
  end

  def stage(%Runtime{} = runtime, %Prepared{} = prepared, credit, assignment, bindings)
      when is_map(bindings) do
    with_context(runtime, fn export ->
      with :ok <- assigned(runtime, export, assignment),
           :ok <- physical_source(prepared) do
        with_source(runtime, export.epoch, fn info ->
          with :ok <- matching_source(info, prepared),
               true <-
                 not is_nil(export.assignment.dispatch_context) or
                   {:error, :missing_target_source} do
            normal(runtime, export, prepared, credit, assignment, bindings, info)
          end
        end)
      end
    end)
  end

  def refresh(_runtime, status, _prepare_and_admit) when status in [:waiting, :done], do: status

  def refresh(%Runtime{} = runtime, {:batch, rows, visited}, prepare_and_admit)
      when is_list(rows) and length(rows) <= 16 and is_integer(visited) and visited >= 0 and
             is_function(prepare_and_admit, 4) do
    with_context(runtime, fn export ->
      refresh_batch(runtime, export.epoch, rows, visited, prepare_and_admit)
    end)
  end

  defp refresh_batch(runtime, epoch, rows, visited, prepare_and_admit) do
    Enum.reduce_while(rows, {:ok, visited}, fn row, result ->
      case refresh_assigned(runtime, epoch, row, prepare_and_admit) do
        {:ok, version} when is_integer(version) and version > 0 -> {:cont, result}
        :superseded -> {:halt, :superseded}
        {:error, _reason} = error -> {:halt, error}
        _other -> {:halt, {:error, :invalid_refresh_result}}
      end
    end)
  end

  defp refresh_assigned(runtime, epoch, row, prepare_and_admit) do
    assignment = row.assignment

    if assignment.target === row.target and assignment.version === row.version and
         assignment.candidate === row.descriptor and assignment.bound === row.bound_descriptor,
       do: refresh_row(runtime, epoch, row, prepare_and_admit),
       else: {:error, :stale_refresh}
  end

  defp with_context(runtime, consume) do
    case Store.export_context(runtime.context.opts) do
      {:ok, %{context_receipt: receipt} = export} ->
        try do
          consume.(export)
        after
          Store.release_resource(receipt)
        end

      {:ok, nil} ->
        {:error, :missing_export}

      error ->
        error
    end
  end

  defp assigned(runtime, export, assignment) do
    current = export.assignment

    if export.job.id === runtime.context.job.id and current.target === export.job.id and
         Map.drop(current, [:dispatch_context]) === Map.drop(assignment, [:dispatch_context]),
       do: :ok,
       else: {:error, :stale_assignment}
  end

  defp physical_source(%Prepared{source: body, source_revision: revision})
       when is_binary(body) and is_reference(revision),
       do: :ok

  defp physical_source(_prepared), do: {:error, :source_revision_mismatch}

  defp with_source(runtime, epoch, consume) do
    case Store.export_source_info(runtime.context.opts, epoch) do
      {:ok, info, receipt} ->
        try do
          consume.(info)
        after
          Store.release_resource(receipt)
        end

      error ->
        error
    end
  end

  defp register_source(runtime, export, prepared, credit, assignment) do
    with_source(runtime, export.epoch, fn
      nil ->
        with_overlap(runtime, credit, byte_size(prepared.source), fn funding ->
          with true <-
                 funding.backing_capacity >= :binary.referenced_byte_size(prepared.source) or
                   {:error, {:limit, :backing_capacity}},
               {:ok, ack} <-
                 Runtime.stage_source(
                   runtime,
                   assignment.source_path,
                   prepared.source,
                   prepared.source_revision,
                   :borrowed,
                   funding
                 ),
               do: register(runtime, export.epoch, prepared, ack.operation)
        end)

      info ->
        with :ok <- matching_source(info, prepared),
             do: register(runtime, export.epoch, prepared, info.response.source_handle)
    end)
  end

  defp register(runtime, epoch, prepared, operation) do
    Store.export_source(
      runtime.context.opts,
      epoch,
      operation,
      prepared.opts[:content_type],
      prepared.opts[:referrer_url] || prepared.opts[:url]
    )
  end

  defp matching_source(%{plan: %Plan{} = plan}, prepared) do
    if plan.kind == :source and plan.source_revision === prepared.source_revision and
         plan.bytes == byte_size(prepared.source) and
         plan.digest === :crypto.hash(:sha256, prepared.source) and
         plan.root_ownership in [:borrowed, :retained],
       do: :ok,
       else: {:error, :source_revision_mismatch}
  end

  defp matching_source(nil, _prepared), do: {:error, :missing_target_source}

  defp normal(
         runtime,
         export,
         %Prepared{analysis: nil, collection: nil, groups: []},
         _credit,
         assignment,
         bindings,
         info
       )
       when map_size(bindings) == 0 do
    descriptor =
      descriptor(assignment, info.response.source_handle, info.plan.source_revision, nil, nil)

    with {:ok, version} <-
           candidate_result(
             Store.export_candidate(
               runtime.context.opts,
               export.epoch,
               assignment.version,
               descriptor,
               %{}
             )
           ),
         :ok <-
           Store.export_discovered(
             runtime.context.opts,
             export.epoch,
             version,
             %{},
             copy_bound(descriptor)
           ),
         do: {:ok, version}
  end

  defp normal(
         runtime,
         export,
         %Prepared{analysis: %Analysis{}} = prepared,
         credit,
         assignment,
         bindings,
         info
       ) do
    with_bound(runtime, prepared, credit, bindings, fn bound, credit ->
      stage_collection(runtime, export, prepared, bound, credit, assignment, info)
    end)
  end

  defp normal(_runtime, _export, _prepared, _credit, _assignment, _bindings, _info),
    do: {:error, :invalid_bindings}

  defp stage_collection(runtime, export, prepared, bound, credit, assignment, info) do
    with_memberships(runtime, export.epoch, prepared, true, fn memberships, current? ->
      with {:ok, descriptor} <-
             lexical_candidate(runtime, prepared, bound, credit, assignment, info),
           {:ok, version} <-
             candidate_result(
               Store.export_candidate(
                 runtime.context.opts,
                 export.epoch,
                 assignment.version,
                 descriptor,
                 memberships
               )
             ) do
        if current?,
          do:
            publish_bound(
              runtime,
              export.epoch,
              assignment,
              version,
              descriptor,
              prepared,
              bound,
              credit,
              memberships,
              nil
            ),
          else: :superseded
      end
    end)
  end

  defp lexical_candidate(runtime, prepared, bound, credit, %{candidate: nil} = assignment, info) do
    with {:ok, lexical} <-
           metadata(runtime, assignment.lexical_path, prepared, bound, credit) do
      {:ok,
       descriptor(
         assignment,
         info.response.source_handle,
         prepared.source_revision,
         lexical.operation,
         prepared.analysis.revision
       )}
    end
  end

  defp lexical_candidate(_runtime, prepared, _bound, _credit, assignment, info) do
    candidate = assignment.candidate

    expected =
      descriptor(
        assignment,
        info.response.source_handle,
        prepared.source_revision,
        candidate.lexical_operation,
        prepared.analysis.revision
      )

    if candidate === expected and is_reference(candidate.lexical_operation),
      do: {:ok, candidate},
      else: {:error, :lexical_revision_changed}
  end

  defp with_bound(runtime, prepared, credit, bindings, consume) do
    with :ok <- binding_ids(prepared.collection, bindings) do
      with_projection(runtime, prepared, credit, bindings, fn credit ->
        with {:ok, bound} <- Analysis.bind(prepared.collection, &Map.get(bindings, &1.id)),
             do: consume.(bound, credit)
      end)
    end
  end

  defp binding_ids(collection, bindings) when is_map(bindings) do
    found = Enum.count(collection.occurrences, &Map.has_key?(bindings, &1.id))

    if found == map_size(bindings) and
         Enum.all?(bindings, fn {_id, target} -> is_nil(target) or is_reference(target) end),
       do: :ok,
       else: {:error, :invalid_bindings}
  end

  defp binding_ids(_collection, _bindings), do: {:error, :invalid_bindings}

  defp with_projection(runtime, prepared, credit, bindings, consume) do
    opts = runtime.context.opts

    with {:ok, walk} <- Store.reserve_resource(opts, :scratch, @walk_workspace) do
      try do
        with {:ok, bytes} <-
               Retained.copy_bytes(
                 {prepared.collection, prepared.css_collection, prepared.css_revision, bindings},
                 prepared.collection.budget.limit
               ),
             bytes =
               max(bytes, Budget.cost(:occurrence, length(prepared.collection.occurrences))) +
                 membership_workspace(prepared.css_collection),
             {:ok, funding} <-
               Store.resource_funding(
                 opts,
                 Map.put(Map.take(credit, [:retained, :backing, :unavailable]), :overlap, walk)
               ) do
          needed = prepared.collection.budget.retained - credit.unavailable + bytes
          extra = max(needed - funding.retained_capacity, 0)
          projection_credit(runtime, credit, extra, consume)
        end
      after
        Store.release_resource(walk)
      end
    end
  end

  defp membership_workspace(nil), do: 0
  defp membership_workspace(%{groups: []}), do: 0

  defp membership_workspace(%{groups: groups}) do
    count = length(groups)

    Budget.cost(:map_entry, 2 * count) + Budget.cost(:list_cell, 8 * count) +
      Budget.cost(:frame, 1 + div(count + 15, 16))
  end

  defp projection_credit(_runtime, credit, 0, consume), do: consume.(credit)

  defp projection_credit(runtime, credit, bytes, consume) when length(credit.retained) < 4 do
    with {:ok, receipt} <- Store.reserve_resource(runtime.context.opts, :analysis, bytes) do
      try do
        consume.(%{credit | retained: credit.retained ++ [receipt]})
      after
        Store.release_resource(receipt)
      end
    end
  end

  defp projection_credit(_runtime, _credit, _bytes, _consume), do: {:error, :unfunded}

  defp metadata(runtime, path, prepared, bound, credit) do
    opts = runtime.context.opts

    with {:ok, walk} <- Store.reserve_resource(opts, :scratch, @walk_workspace) do
      try do
        lineage = %{root: :borrowed, unavailable: credit.unavailable}

        with {:ok, plan} <-
               StagedIO.plan_metadata(
                 path,
                 prepared.analysis,
                 prepared.collection,
                 bound,
                 prepared.css_revision,
                 prepared.source_revision,
                 lineage
               ) do
          with_overlap(runtime, credit, plan.bytes, fn funding ->
            Runtime.stage_metadata(
              runtime,
              path,
              prepared.analysis,
              prepared.collection,
              bound,
              prepared.css_revision,
              prepared.source_revision,
              lineage,
              funding
            )
          end)
        end
      after
        Store.release_resource(walk)
      end
    end
  end

  defp with_overlap(runtime, credit, bytes, consume) do
    opts = runtime.context.opts

    with {:ok, receipt} <- Store.reserve_resource(opts, :scratch, bytes) do
      try do
        with {:ok, funding} <-
               Store.resource_funding(
                 opts,
                 Map.put(Map.take(credit, [:retained, :backing, :unavailable]), :overlap, receipt)
               ),
             do: consume.(funding)
      after
        Store.release_resource(receipt)
      end
    end
  end

  defp candidate_result({:error, :stale_group_version}), do: :superseded
  defp candidate_result(result), do: result

  defp with_memberships(runtime, epoch, prepared, allow_stale?, consume) do
    groups = if prepared.css_collection, do: prepared.css_collection.groups, else: []
    revisions = if groups == [], do: [], else: prepared.css_revision

    if is_list(revisions) and length(groups) == length(revisions),
      do:
        memberships(
          runtime,
          epoch,
          Enum.reverse(groups),
          revisions,
          [],
          true,
          allow_stale?,
          consume
        ),
      else: {:error, :invalid_css_revision}
  end

  defp memberships(_runtime, _epoch, [], [], found, current?, _allow_stale?, consume),
    do: consume.(Map.new(found), current?)

  defp memberships(runtime, epoch, groups, revisions, found, current?, allow_stale?, consume) do
    {batch, rest} = Enum.split(groups, 16)
    {expected, revisions} = Enum.split(revisions, length(batch))
    ids = Enum.map(batch, & &1.style_group)

    case Store.export_group_versions(runtime.context.opts, epoch, ids) do
      {:ok, versions, receipt} ->
        try do
          matches? = css_matches?(ids, expected, versions)

          if matches? or allow_stale? do
            entries = membership_entries(versions, found)

            memberships(
              runtime,
              epoch,
              rest,
              revisions,
              entries,
              current? and matches?,
              allow_stale?,
              consume
            )
          else
            :superseded
          end
        after
          Store.release_resource(receipt)
        end

      error ->
        error
    end
  end

  defp membership_entries(versions, found),
    do: Enum.reduce(versions, found, fn pair, entries -> [pair | entries] end)

  defp css_matches?(ids, expected, versions) do
    ids
    |> Enum.zip_with(expected, fn id, revision -> versions[id].revision === revision end)
    |> Enum.all?()
  end

  defp descriptor(assignment, source, revision, lexical, analysis) do
    %{
      source_operation: source,
      source_revision: revision,
      lexical_operation: lexical,
      analysis_revision: analysis,
      public_id: assignment.public_id,
      render_mode: if(is_nil(analysis), do: :copy, else: :rewrite)
    }
  end

  defp copy_bound(descriptor) do
    %{
      operation: descriptor.source_operation,
      source_revision: descriptor.source_revision,
      analysis_revision: nil,
      css_stamp: nil,
      edges_digest: StagedIO.edge_digest([])
    }
  end

  defp publish_bound(
         runtime,
         epoch,
         assignment,
         version,
         descriptor,
         prepared,
         bound,
         credit,
         memberships,
         target
       ) do
    cond do
      version != assignment.version or is_nil(assignment.bound) ->
        stage_bound(
          runtime,
          epoch,
          assignment,
          version,
          descriptor,
          prepared,
          bound,
          credit,
          memberships,
          target
        )

      true ->
        reuse_bound(
          runtime,
          epoch,
          assignment.bound,
          version,
          descriptor,
          prepared,
          bound,
          memberships,
          target
        )
    end
  end

  defp reuse_bound(
         runtime,
         epoch,
         acknowledged,
         version,
         descriptor,
         prepared,
         bound,
         memberships,
         target
       ) do
    expected = %{
      operation: acknowledged.operation,
      source_revision: descriptor.source_revision,
      analysis_revision: descriptor.analysis_revision,
      css_stamp: prepared.css_revision,
      edges_digest: StagedIO.edge_digest(bound.occurrences)
    }

    with true <- acknowledged === expected or {:error, :changed_occurrence_collection},
         :ok <- discovered(runtime, epoch, target, version, memberships, acknowledged),
         do: {:ok, version}
  end

  defp stage_bound(
         runtime,
         epoch,
         assignment,
         version,
         descriptor,
         prepared,
         bound,
         credit,
         memberships,
         target
       ) do
    path = assignment.bound_prefix <> Integer.to_string(version) <> ".etf"

    with {:ok, ack} <- metadata(runtime, path, prepared, bound, credit),
         discovered = %{
           operation: ack.operation,
           source_revision: descriptor.source_revision,
           analysis_revision: descriptor.analysis_revision,
           css_stamp: prepared.css_revision,
           edges_digest: StagedIO.edge_digest(bound.occurrences)
         },
         :ok <- discovered(runtime, epoch, target, version, memberships, discovered),
         do: {:ok, version}
  end

  defp discovered(runtime, epoch, nil, version, memberships, bound),
    do: Store.export_discovered(runtime.context.opts, epoch, version, memberships, bound)

  defp discovered(runtime, epoch, target, version, memberships, bound),
    do:
      Store.export_refresh_discovered(
        runtime.context.opts,
        epoch,
        target,
        version,
        memberships,
        bound
      )

  defp refresh_row(runtime, epoch, %{descriptor: %{render_mode: :copy}} = row, _prepare) do
    with {:ok, version} <-
           candidate_result(
             Store.export_refresh_candidate(
               runtime.context.opts,
               epoch,
               row.target,
               row.version,
               row.descriptor,
               %{}
             )
           ),
         :ok <- discovered(runtime, epoch, row.target, version, %{}, copy_bound(row.descriptor)),
         do: {:ok, version}
  end

  defp refresh_row(runtime, epoch, %{lexical: %Plan{kind: :metadata}} = row, prepare) do
    with_replay(runtime, row.bound || row.lexical, fn replay, credit ->
      prepare.(row, replay, credit, fn prepared, current_credit, bindings ->
        with :ok <- physical_source(prepared),
             :ok <- matching_source(%{plan: row.source}, prepared),
             true <-
               prepared.analysis.revision === row.descriptor.analysis_revision or
                 {:error, :lexical_revision_changed} do
          refreshed(runtime, epoch, row, prepared, current_credit, bindings)
        end
      end)
    end)
  end

  defp refreshed(runtime, epoch, row, prepared, credit, bindings) do
    with_bound(runtime, prepared, credit, bindings, fn bound, credit ->
      with_memberships(runtime, epoch, prepared, false, fn memberships, true ->
        refresh_bound(runtime, epoch, row, prepared, bound, credit, memberships)
      end)
    end)
  end

  defp refresh_bound(runtime, epoch, row, prepared, bound, credit, memberships) do
    with {:ok, version} <-
           candidate_result(
             Store.export_refresh_candidate(
               runtime.context.opts,
               epoch,
               row.target,
               row.version,
               row.descriptor,
               memberships
             )
           ) do
      publish_bound(
        runtime,
        epoch,
        row.assignment,
        version,
        row.descriptor,
        prepared,
        bound,
        credit,
        memberships,
        row.target
      )
    end
  end

  defp with_replay(runtime, plan, consume) do
    opts = runtime.context.opts

    with {:ok, retained} <- Store.reserve_resource(opts, :analysis, plan.read_capacity) do
      try do
        with {:ok, backing} <- Store.reserve_resource(opts, :response, plan.root_bytes) do
          try do
            credit = %{retained: [retained], backing: [backing], unavailable: plan.unavailable}

            result =
              with_overlap(runtime, credit, plan.read_capacity + 1, fn funding ->
                StagedIO.replay(plan, runtime.context.recovery_receipt, funding)
              end)

            with {:ok, replay} <- result,
                 :ok <- Store.commit_resource(retained, plan.read_capacity),
                 do: consume.(replay, credit)
          after
            Store.release_resource(backing)
          end
        end
      after
        Store.release_resource(retained)
      end
    end
  end
end
