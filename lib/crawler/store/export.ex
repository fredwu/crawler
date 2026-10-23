defmodule Crawler.Store.Export do
  @moduledoc """
  Pure preparation state embedded in the Store owner's export record.

  The owner supplies canonical Jobs, outcomes, ordered CSS versions and close
  proofs. This module validates local consistency. It creates no authority and
  does not establish scheduler quiescence or authorize filesystem promotion.

  Helper records reserve a subset of the embedded Session descriptor debit.
  Every Session update must pass through `put_session/2`, `admit/3`, `settle/4`
  or `prepared/5`. Callers must never restore a stale external Session copy.
  Record tariffs include prepaid ordered-index and optional ring slots. They
  are conservative accounting tariffs, not VM heap measurements.
  """

  alias Crawler.Export.Session
  alias Crawler.Export.StagedIO
  alias Crawler.Export.StagedIO.Ack
  alias Crawler.Export.StagedIO.Plan
  alias Crawler.Frontier.Ring
  alias Crawler.Job
  alias Crawler.Job.Outcome

  @descriptor_keys [
    :source_operation,
    :lexical_operation,
    :source_revision,
    :analysis_revision,
    :public_id,
    :render_mode
  ]
  @bound_keys [:operation, :source_revision, :analysis_revision, :css_stamp, :edges_digest]
  @derive {Inspect,
           only: [:phase, :mutation_version, :dirty_count, :pending_fanouts, :unprepared]}
  @enforce_keys [:session, :dirty, :fanouts, :order]
  defstruct [
    :session,
    :dirty,
    :fanouts,
    :order,
    :close_proof,
    :finalizer,
    phase: :admitting,
    targets: %{},
    groups: %{},
    sequence: 0,
    dirty_count: 0,
    pending_fanouts: 0,
    unsettled: 0,
    unprepared: 0,
    mutation_version: 0,
    charged_bytes: 0,
    base_charge: 0
  ]

  def new(%Session{manifest: %{state: :admitting, targets: targets}} = session)
      when map_size(targets) == 0 do
    state = %__MODULE__{
      session: session,
      dirty: Ring.new(),
      fanouts: Ring.new(),
      order: :gb_trees.empty()
    }

    budget(state, %{}, 0, false)
  end

  def new(_session), do: {:error, :nonempty_session}

  def admit(state, epoch, %Job{} = job) do
    with :ok <- admitting(state),
         result <- Session.admit(state.session, epoch, job) do
      case result do
        {:existing, _session} ->
          {:existing, state}

        {:ok, session} ->
          row = %{
            version: 0,
            descriptor: nil,
            bound: nil,
            memberships: %{},
            dirty?: true,
            refreshing?: false,
            refresh_owner: nil,
            prepared: nil,
            sequence: state.sequence,
            membership_charge: 0
          }

          with {:ok, cost} <- row_cost(job.id, row, state),
               {:ok, next} <-
                 budget(
                   %{state | session: session},
                   %{
                     sequence: state.sequence + 1,
                     unsettled: state.unsettled + 1,
                     dirty_count: state.dirty_count + 1
                   },
                   cost,
                   true,
                   {1, 0}
                 ) do
            {:ok,
             %{
               next
               | targets: Map.put(next.targets, job.id, row),
                 order: :gb_trees.insert(row.sequence, job.id, next.order),
                 dirty: Ring.put(next.dirty, job.id)
             }}
          end

        error ->
          error
      end
    end
  end

  def settle(state, epoch, target, %Outcome{} = outcome) do
    with :ok <- admitting(state),
         true <- epoch === state.session.epoch or {:error, :stale_epoch},
         {:ok, row} <- target(state, target) do
      if outcome(state, target) === outcome.status do
        record = state.session.manifest.targets[target]

        if (is_nil(outcome.representation_id) or
              outcome.representation_id === record.representation_id) and
             (is_nil(outcome.interpretation_id) or
                outcome.interpretation_id === record.interpretation_id),
           do: {:existing, state},
           else: {:error, :outcome_identity_mismatch}
      else
        settle_new(state, epoch, target, row, outcome)
      end
    end
  end

  defp settle_new(state, epoch, target, row, outcome) do
    with {:ok, session} <- Session.settle(state.session, epoch, target, outcome) do
      success? = outcome.status == :succeeded

      next_row =
        if success?, do: row, else: %{row | dirty?: false, refreshing?: false, refresh_owner: nil}

      counts = %{
        unsettled: state.unsettled - 1,
        unprepared: state.unprepared + if(success?, do: 1, else: 0),
        dirty_count: state.dirty_count - if(not success? and row.dirty?, do: 1, else: 0)
      }

      with {:ok, delta} <- row_delta(state, target, row, next_row),
           growth = if(success? and row.dirty?, do: ring_growth(state.dirty, target), else: 0),
           {:ok, next} <- budget(%{state | session: session}, counts, delta, true, {growth, 0}) do
        dirty =
          cond do
            not success? -> Ring.delete(next.dirty, target)
            row.dirty? -> Ring.put(next.dirty, target)
            true -> next.dirty
          end

        {:ok,
         %{
           next
           | targets: Map.put(next.targets, target, next_row),
             dirty: dirty
         }}
      end
    end
  end

  @doc "Accept a current owner Session update without bypassing target or final-edge transitions."
  def put_session(state, %Session{} = session) do
    old = state.session

    with true <-
           (session.run === old.run and session.epoch === old.epoch and
              session.manifest.id === old.manifest.id and
              session.manifest.limits === old.manifest.limits) or
             {:error, :session_identity_changed},
         true <-
           (session.manifest.targets === old.manifest.targets and
              session.manifest.interpretations === old.manifest.interpretations and
              session.manifest.edges === old.manifest.edges and
              session.manifest.public_ids === old.manifest.public_ids and
              session.manifest.edge_count === old.manifest.edge_count and
              session.manifest.representation_ids === old.manifest.representation_ids) or
             {:error, :session_transition_bypass},
         true <-
           (session.manifest.seal_token === old.manifest.seal_token and
              session.snapshot === old.snapshot) or
             {:error, :session_transition_bypass},
         :ok <- session_lifecycle(old, session),
         true <-
           state.phase == :admitting or session.manifest.responses === old.manifest.responses or
             {:error, :closed_response},
         true <-
           (session.descriptor_bytes >= old.descriptor_bytes and
              session.descriptor_bytes >= state.charged_bytes) or {:error, :lost_helper_debit},
         :ok <- aggregate_bound(session) do
      if session === old do
        {:existing, state}
      else
        phase =
          if session.manifest.state in [:ready, :failed, :cancelled],
            do: :terminal,
            else: state.phase

        budget(%{state | session: session}, %{phase: phase}, 0)
      end
    end
  end

  def candidate(state, target, expected_version, descriptor, memberships, owner \\ nil) do
    with :ok <- admitting(state),
         {:ok, row} <- active_target(state, target),
         true <- expected_version === row.version or {:superseded, state},
         :ok <- descriptor(state, target, descriptor),
         :ok <- same_lexical(row.descriptor, descriptor),
         :ok <- membership_versions(state, memberships),
         :ok <- candidate_preflight(state, target, row, descriptor, memberships) do
      if row.descriptor === descriptor and versions(row.memberships) === memberships do
        {:existing, row.version, state}
      else
        {new_memberships, additions} = membership_rows(state, row, memberships)

        with {:ok, membership_charge} <- measured(new_memberships, state, 0),
             next_row = %{
               row
               | descriptor: descriptor,
                 memberships: new_memberships,
                 membership_charge: membership_charge,
                 version: row.version + 1,
                 bound: nil,
                 dirty?: true,
                 refreshing?: not is_nil(owner),
                 refresh_owner: owner
             },
             {:ok, delta} <- row_delta(state, target, row, next_row),
             {:ok, group_delta} <- membership_group_delta(state, memberships, additions),
             {:ok, next} <-
               budget(
                 state,
                 %{dirty_count: state.dirty_count + if(row.dirty?, do: 0, else: 1)},
                 delta + group_delta,
                 true,
                 {if(is_nil(owner), do: ring_growth(state.dirty, target), else: 0), 0}
               ) do
          groups = remove_memberships(next.groups, row.memberships, new_memberships)
          groups = add_memberships(groups, target, new_memberships, memberships, additions)

          {:ok, next_row.version,
           %{
             next
             | groups: groups,
               targets: Map.put(next.targets, target, next_row),
               dirty:
                 if(is_nil(owner),
                   do: Ring.put(next.dirty, target),
                   else: Ring.delete(next.dirty, target)
                 )
           }}
        end
      end
    end
  end

  def discovered(state, target, version, expected_group_versions, bound) do
    with :ok <- admitting(state),
         {:ok, row} <- active_target(state, target) do
      if row.version !== version or not current_versions?(state, row, expected_group_versions) do
        requeue(state, target, row)
      else
        with :ok <- bound(state, row, bound) do
          if not row.dirty? and row.bound === bound and
               stored_versions?(row.memberships, expected_group_versions) do
            {:existing, state}
          else
            store_discovered(state, target, row, expected_group_versions, bound)
          end
        end
      end
    end
  end

  defp store_discovered(state, target, row, expected_group_versions, bound) do
    with {:ok, membership_charge} <-
           updated_membership_charge(state, row.memberships, expected_group_versions),
         next_row = %{
           row
           | bound: bound,
             membership_charge: membership_charge,
             dirty?: false,
             refreshing?: false,
             refresh_owner: nil
         },
         {:ok, delta} <- row_delta(state, target, row, next_row),
         {:ok, next} <-
           budget(
             state,
             %{dirty_count: state.dirty_count - if(row.dirty?, do: 1, else: 0)},
             delta
           ) do
      next_row = %{
        next_row
        | memberships: update_versions(row.memberships, expected_group_versions)
      }

      {:ok,
       %{
         next
         | targets: Map.put(next.targets, target, next_row),
           dirty: Ring.delete(next.dirty, target)
       }}
    end
  end

  def invalidate(state, group_id, version) do
    with :ok <- admitting(state),
         :ok <- handle(group_id, state),
         :ok <- group_version(version, state) do
      group = Map.get(state.groups, group_id)

      case compare_version(group && group.version, version) do
        :same ->
          {:existing, state}

        :stale ->
          {:stale, state}

        :conflict ->
          {:error, :group_version_conflict}

        :new ->
          group = group || empty_group(version)
          cursor = group.cursor || %{after: -1, high_water: group.sequence - 1, version: version}
          next_group = %{group | version: version, cursor: cursor}
          pending = state.pending_fanouts + if(group.cursor, do: 0, else: 1)

          with {:ok, delta} <- group_delta(state, group_id, state.groups[group_id], next_group),
               {:ok, next} <-
                 budget(
                   state,
                   %{pending_fanouts: pending},
                   delta,
                   true,
                   {0, ring_growth(state.fanouts, group_id)}
                 ) do
            {:ok,
             %{
               next
               | groups: Map.put(next.groups, group_id, next_group),
                 fanouts: Ring.put(next.fanouts, group_id)
             }}
          end
      end
    end
  end

  @doc "Bound all fan-out member visits and target dispatches by limit; waiting is not done."
  def refresh_batch(state, limit, eligible \\ fn _target -> true end, owner \\ nil)

  def refresh_batch(state, limit, eligible, owner)
      when is_integer(limit) and limit > 0 and is_function(eligible, 1) do
    with :ok <- admitting(state), do: refresh(state, limit, [], 0, eligible, owner)
  end

  def refresh_batch(_state, _limit, _eligible, _owner), do: {:error, :invalid_batch_limit}

  def release_refresh(state, owner, selected) do
    with :ok <- admitting(state), do: release_selected(state, owner, selected, 16)
  end

  defp release_selected(state, _owner, [], _remaining), do: {:ok, state}

  defp release_selected(state, owner, [{id, version} | rest], remaining) when remaining > 0 do
    case state.targets[id] do
      %{dirty?: true, refreshing?: true, refresh_owner: ^owner, version: ^version} = row ->
        case requeue(state, id, row) do
          {:superseded, state} -> release_selected(state, owner, rest, remaining - 1)
          error -> error
        end

      _ ->
        release_selected(state, owner, rest, remaining - 1)
    end
  end

  defp release_selected(_state, _owner, _selected, _remaining),
    do: {:error, :invalid_batch_limit}

  def close(state, epoch, proof, %Job{kind: :finalize} = finalizer) do
    with :ok <- admitting(state),
         true <- epoch === state.session.epoch or {:error, :stale_epoch},
         :ok <- proof(state, proof),
         :ok <- same_run(state, finalizer) do
      if state.unsettled != 0 or state.dirty_count != 0 or state.pending_fanouts != 0 or
           map_size(state.session.pending) != 0 do
        {:busy, state}
      else
        job = %Job{id: finalizer.id, kind: :finalize, authority: finalizer.authority}
        pinned = Map.put(proof, :mutation_version, state.mutation_version)

        with {:ok, next} <-
               budget(state, %{phase: :preparing, close_proof: pinned, finalizer: job}, 0) do
          {:ok, proof.close_token, next}
        end
      end
    end
  end

  def close(_state, _epoch, _proof, _finalizer), do: {:error, :invalid_finalizer}

  def prepare_next(state, token, cursor, limit) when is_integer(limit) and limit > 0 do
    with :ok <- preparing(state, token),
         true <-
           is_nil(cursor) or (is_integer(cursor) and cursor >= -1 and cursor < state.sequence) or
             {:error, :invalid_cursor} do
      collect_preparation(
        state,
        :gb_trees.iterator_from((cursor || -1) + 1, state.order),
        limit,
        [],
        cursor
      )
    end
  end

  def prepare_next(_state, _token, _cursor, _limit), do: {:error, :invalid_batch_limit}

  def prepared(
        state,
        token,
        target,
        %{operation: operation, ack: %Ack{plan: %Plan{}} = ack} = attrs,
        edges
      )
      when map_size(attrs) == 2 and is_list(edges) do
    with :ok <- preparing(state, token),
         {:ok, row} <- target(state, target),
         true <- outcome(state, target) == :succeeded or {:error, :inactive_target},
         true <- (is_reference(operation) and is_reference(ack.ticket)) or {:error, :invalid_ack},
         true <- state.session.staged[operation] === ack.plan or {:error, :unstaged_metadata} do
      fingerprint = {operation, ack.plan.digest, ack.ticket}

      with :ok <- final_plan(state, row, operation, ack.plan, edges) do
        cond do
          row.prepared === fingerprint ->
            {:existing, state}

          not is_nil(row.prepared) ->
            {:error, :already_prepared}

          true ->
            with {:ok, session} <-
                   register(state.session, target, row.descriptor, operation, edges),
                 next_row = %{row | prepared: fingerprint},
                 {:ok, delta} <- row_delta(state, target, row, next_row),
                 {:ok, next} <-
                   budget(%{state | session: session}, %{unprepared: state.unprepared - 1}, delta) do
              {:ok, %{next | targets: Map.put(next.targets, target, next_row)}}
            end
        end
      end
    end
  end

  def prepared(_state, _token, _target, _ack, _edges), do: {:error, :invalid_preparation}

  def seal(state, token) do
    with :ok <- preparing(state, token),
         true <- state.unprepared == 0 or {:error, :pending_preparation},
         {:ok, snapshot, session} <-
           Session.seal(
             state.session,
             state.session.epoch,
             state.close_proof.seal_token,
             state.finalizer
           ),
         {:ok, next} <- budget(%{state | session: session}, %{phase: :sealed}, 0) do
      {:ok, snapshot, next}
    end
  end

  defp refresh(state, 0, ids, visited, _eligible, _owner), do: refresh_result(state, ids, visited)

  defp refresh(state, remaining, ids, visited, eligible, owner) do
    case Ring.take(state.fanouts) do
      {:ok, group_id, ring} ->
        case advance_group(%{state | fanouts: ring}, group_id) do
          {:ok, next} -> refresh(next, remaining - 1, ids, visited + 1, eligible, owner)
          error -> error
        end

      :empty ->
        case Ring.take(state.dirty) do
          :empty ->
            refresh_result(state, ids, visited)

          {:ok, id, ring} ->
            row = state.targets[id]

            if is_nil(row.descriptor) or not active?(state, id) or not eligible.(id) do
              with {:ok, next} <- budget(state, %{}, 0) do
                refresh(%{next | dirty: ring}, remaining - 1, ids, visited + 1, eligible, owner)
              end
            else
              next_row = %{row | refreshing?: true, refresh_owner: owner}

              with {:ok, delta} <- row_delta(state, id, row, next_row),
                   {:ok, next} <- budget(state, %{}, delta) do
                refresh(
                  %{next | dirty: ring, targets: Map.put(next.targets, id, next_row)},
                  remaining - 1,
                  [id | ids],
                  visited + 1,
                  eligible,
                  owner
                )
              end
            end
        end
    end
  end

  defp refresh_result(state, ids, visited) do
    cond do
      ids != [] or visited != 0 -> {:ok, Enum.reverse(ids), visited, state}
      state.dirty_count != 0 or state.pending_fanouts != 0 -> {:waiting, state}
      true -> {:done, state}
    end
  end

  defp advance_group(state, id) do
    group = state.groups[id]
    cursor = group.cursor
    member = :gb_trees.next(:gb_trees.iterator_from(cursor.after + 1, group.members))

    case member do
      {sequence, target_id, _iterator} when sequence <= cursor.high_water ->
        row = state.targets[target_id]

        needs_refresh? =
          active?(state, target_id) and
            (is_nil(row.bound) or row.memberships[id].version !== group.version)

        next_row =
          if needs_refresh?,
            do: %{row | dirty?: true, refreshing?: false, refresh_owner: nil},
            else: row

        next_group = %{group | cursor: %{cursor | after: sequence}}
        dirty_count = state.dirty_count + if(next_row.dirty? and not row.dirty?, do: 1, else: 0)

        with {:ok, row_delta} <- row_delta(state, target_id, row, next_row),
             {:ok, group_delta} <- group_delta(state, id, group, next_group),
             {:ok, next} <-
               budget(
                 state,
                 %{dirty_count: dirty_count},
                 row_delta + group_delta,
                 true,
                 {if(needs_refresh?, do: ring_growth(state.dirty, target_id), else: 0), 1}
               ) do
          {:ok,
           %{
             next
             | groups: Map.put(next.groups, id, next_group),
               targets: Map.put(next.targets, target_id, next_row),
               dirty: if(needs_refresh?, do: Ring.put(next.dirty, target_id), else: next.dirty),
               fanouts: Ring.put(next.fanouts, id)
           }}
        end

      _ ->
        restart? = cursor.version !== group.version

        next_cursor =
          if restart?,
            do: %{after: -1, high_water: group.sequence - 1, version: group.version},
            else: nil

        next_group = %{group | cursor: next_cursor}

        with {:ok, delta} <- group_delta(state, id, group, next_group),
             {:ok, next} <-
               budget(
                 state,
                 %{pending_fanouts: state.pending_fanouts - if(restart?, do: 0, else: 1)},
                 delta,
                 true,
                 {0, if(restart?, do: 1, else: 0)}
               ) do
          {:ok,
           %{
             next
             | groups: Map.put(next.groups, id, next_group),
               fanouts: if(restart?, do: Ring.put(next.fanouts, id), else: next.fanouts)
           }}
        end
    end
  end

  defp requeue(state, id, row) do
    if row.dirty? and Map.has_key?(state.dirty.members, id) and not row.refreshing? do
      {:superseded, state}
    else
      next_row = %{row | dirty?: true, refreshing?: false, refresh_owner: nil}

      with {:ok, delta} <- row_delta(state, id, row, next_row),
           {:ok, next} <-
             budget(
               state,
               %{dirty_count: state.dirty_count + if(row.dirty?, do: 0, else: 1)},
               delta,
               true,
               {ring_growth(state.dirty, id), 0}
             ) do
        {:superseded,
         %{next | targets: Map.put(next.targets, id, next_row), dirty: Ring.put(next.dirty, id)}}
      end
    end
  end

  defp collect_preparation(_state, _iterator, 0, entries, cursor),
    do: {:ok, Enum.reverse(entries), cursor}

  defp collect_preparation(state, iterator, remaining, entries, cursor) do
    case :gb_trees.next(iterator) do
      :none ->
        if entries == [], do: :done, else: {:ok, Enum.reverse(entries), cursor}

      {sequence, id, next} ->
        row = state.targets[id]

        entries =
          if outcome(state, id) == :succeeded and is_nil(row.prepared),
            do: [
              %{
                target: id,
                version: row.version,
                descriptor: row.descriptor,
                bound: row.bound,
                group_versions: versions(row.memberships)
              }
              | entries
            ],
            else: entries

        collect_preparation(state, next, remaining - 1, entries, sequence)
    end
  end

  defp descriptor(state, target, descriptor)
       when is_map(descriptor) and map_size(descriptor) == 6 do
    with true <-
           Enum.sort(Map.keys(descriptor)) == Enum.sort(@descriptor_keys) or
             {:error, :invalid_descriptor},
         true <- descriptor.render_mode in [:copy, :rewrite] or {:error, :invalid_descriptor},
         true <-
           (is_reference(descriptor.source_operation) and is_reference(descriptor.source_revision)) or
             {:error, :invalid_descriptor},
         %Plan{kind: :source, source_revision: revision} <-
           state.session.staged[descriptor.source_operation],
         true <- revision === descriptor.source_revision or {:error, :source_revision_mismatch},
         :ok <- canonical_response(state, target, descriptor),
         true <-
           Crawler.Export.Paths.public_id?(descriptor.public_id) or {:error, :invalid_public_id} do
      case descriptor.render_mode do
        :copy ->
          if is_nil(descriptor.lexical_operation) and is_nil(descriptor.analysis_revision),
            do: :ok,
            else: {:error, :copy_has_analysis}

        :rewrite ->
          case state.session.staged[descriptor.lexical_operation] do
            %Plan{
              kind: :metadata,
              source_revision: ^revision,
              analysis_revision: analysis,
              source_digest: digest
            }
            when analysis === descriptor.analysis_revision ->
              if digest === state.session.staged[descriptor.source_operation].digest,
                do: :ok,
                else: {:error, :source_digest_mismatch}

            _ ->
              {:error, :unstaged_lexical_metadata}
          end
      end
    else
      nil -> {:error, :unstaged_source}
      %Plan{} -> {:error, :unstaged_source}
      error -> error
    end
  end

  defp descriptor(_state, _target, _descriptor), do: {:error, :invalid_descriptor}

  defp canonical_response(state, target, descriptor) do
    representation = state.session.manifest.targets[target].representation_id

    case state.session.manifest.responses[representation] do
      %{source_handle: operation, source_revision: revision}
      when operation === descriptor.source_operation and revision === descriptor.source_revision ->
        :ok

      nil ->
        {:error, :missing_target_response}

      _response ->
        {:error, :target_source_mismatch}
    end
  end

  defp bound(state, row, bound) when is_map(bound) and map_size(bound) == 5 do
    with true <- Enum.sort(Map.keys(bound)) == Enum.sort(@bound_keys) or {:error, :invalid_bound},
         true <- is_reference(bound.operation) or {:error, :invalid_bound},
         true <- not is_nil(row.descriptor) or {:error, :missing_candidate},
         true <-
           (bound.source_revision === row.descriptor.source_revision and
              bound.analysis_revision === row.descriptor.analysis_revision) or
             {:error, :lexical_revision_changed},
         true <-
           (is_binary(bound.edges_digest) and byte_size(bound.edges_digest) == 32) or
             {:error, :invalid_bound},
         %Plan{} = plan <- state.session.staged[bound.operation] do
      case row.descriptor.render_mode do
        :copy ->
          if bound.operation === row.descriptor.source_operation and is_nil(bound.css_stamp) and
               bound.edges_digest == StagedIO.edge_digest([]),
             do: :ok,
             else: {:error, :invalid_copy_bound}

        :rewrite ->
          if plan.kind == :metadata and plan.source_revision === bound.source_revision and
               plan.analysis_revision === bound.analysis_revision and
               plan.css_revision === bound.css_stamp and
               plan.edges_digest === bound.edges_digest and
               plan.source_digest === state.session.staged[row.descriptor.source_operation].digest,
             do: :ok,
             else: {:error, :changed_occurrence_collection}
      end
    else
      nil -> {:error, :unstaged_bound_metadata}
      error -> error
    end
  end

  defp bound(_state, _row, _bound), do: {:error, :invalid_bound}

  defp final_plan(state, row, operation, %Plan{} = plan, edges) do
    case row.descriptor.render_mode do
      :copy ->
        if operation === row.descriptor.source_operation and plan.kind == :source and edges == [],
          do: :ok,
          else: {:error, :invalid_copy_preparation}

      :rewrite ->
        if plan.kind == :metadata and plan.source_revision === row.bound.source_revision and
             plan.analysis_revision === row.bound.analysis_revision and
             plan.css_revision === row.bound.css_stamp and
             plan.edges_digest === row.bound.edges_digest and
             StagedIO.edge_digest(edges) === row.bound.edges_digest and
             plan.source_digest === state.session.staged[row.descriptor.source_operation].digest,
           do: :ok,
           else: {:error, :changed_occurrence_collection}
    end
  end

  defp register(session, target, %{render_mode: :copy, public_id: id}, _operation, []),
    do: Session.copy(session, session.epoch, target, id)

  defp register(session, target, %{render_mode: :rewrite, public_id: id}, operation, edges),
    do: Session.interpretation(session, session.epoch, target, operation, id, edges)

  defp membership_versions(state, memberships) when is_map(memberships) do
    Enum.reduce_while(memberships, :ok, fn {id, version}, :ok ->
      with :ok <- handle(id, state),
           :ok <- group_version(version, state),
           true <-
             is_nil(state.groups[id]) or state.groups[id].version === version or
               {:error, :stale_group_version} do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp membership_versions(_state, _memberships), do: {:error, :invalid_memberships}

  defp candidate_preflight(state, id, row, descriptor, memberships) do
    if row.descriptor === descriptor and versions(row.memberships) === memberships do
      :ok
    else
      result =
        Enum.reduce_while(memberships, {:ok, 0, 0}, fn {group_id, version},
                                                       {:ok, association_cost, group_cost} ->
          membership_preflight(state, row, group_id, version, association_cost, group_cost)
        end)

      with {:ok, association_cost, group_cost} <- result,
           header = %{
             row
             | descriptor: descriptor,
               bound: nil,
               dirty?: true,
               refreshing?: false,
               version: row.version + 1,
               membership_charge: association_cost
           },
           {:ok, delta} <- row_delta(state, id, row, header),
           {:ok, _prepaid} <-
             budget(
               state,
               %{dirty_count: state.dirty_count + if(row.dirty?, do: 0, else: 1)},
               delta + group_cost,
               true,
               {ring_growth(state.dirty, id), 0}
             ) do
        :ok
      end
    end
  end

  defp membership_preflight(state, row, group_id, version, association_cost, group_cost) do
    old = row.memberships[group_id]
    group = state.groups[group_id]
    sequence = if old, do: old.sequence, else: if(group, do: group.sequence, else: 0)

    proposed_group =
      if group,
        do: %{group | sequence: group.sequence + if(old, do: 0, else: 1)},
        else: %{empty_group(version) | sequence: 1}

    with {:ok, association} <-
           measured(%{group_id => %{sequence: sequence, version: version}}, state, 0),
         {:ok, delta} <- group_delta(state, group_id, group, proposed_group) do
      {:cont, {:ok, association_cost + association, group_cost + delta}}
    else
      error -> {:halt, error}
    end
  end

  defp session_lifecycle(old, new) do
    old_state = old.manifest.state
    new_state = new.manifest.state

    allowed? =
      old_state === new_state or
        (old_state in [:admitting, :finalizing] and new_state in [:failed, :cancelled]) or
        (old_state == :finalizing and new_state == :ready)

    finalizer? =
      old.finalizer === new.finalizer or
        case {old.finalizer, new.finalizer} do
          {%{id: id, outcome: nil}, %{id: id, outcome: %Outcome{status: status}}} ->
            (new_state == :ready and status == :succeeded) or
              (new_state in [:failed, :cancelled] and status in [:failed, :limited, :cancelled])

          _ ->
            false
        end

    if allowed? and finalizer?, do: :ok, else: {:error, :session_transition_bypass}
  end

  defp membership_rows(state, row, versions) do
    Enum.reduce(versions, {%{}, %{}}, fn {id, version}, {memberships, additions} ->
      old = row.memberships[id]

      sequence = membership_sequence(state, id, old)

      {Map.put(memberships, id, %{sequence: sequence, version: version}),
       if(old, do: additions, else: Map.put(additions, id, sequence))}
    end)
  end

  defp membership_sequence(state, id, old) do
    if old,
      do: old.sequence,
      else: if(state.groups[id], do: state.groups[id].sequence, else: 0)
  end

  defp remove_memberships(groups, old, current) do
    Enum.reduce(old, groups, fn {id, membership}, acc ->
      if Map.has_key?(current, id),
        do: acc,
        else:
          Map.update!(
            acc,
            id,
            &%{&1 | members: :gb_trees.delete(membership.sequence, &1.members)}
          )
    end)
  end

  defp add_memberships(groups, target, memberships, versions, additions) do
    Enum.reduce(memberships, groups, fn {id, _membership}, acc ->
      group = Map.get(acc, id) || empty_group(versions[id])

      case Map.fetch(additions, id) do
        {:ok, sequence} ->
          Map.put(acc, id, %{
            group
            | sequence: sequence + 1,
              members: :gb_trees.insert(sequence, target, group.members)
          })

        :error ->
          acc
      end
    end)
  end

  defp membership_group_delta(state, memberships, additions) do
    Enum.reduce_while(memberships, {:ok, 0}, fn {id, version}, {:ok, cost} ->
      membership_group_cost(state, id, version, additions, cost)
    end)
  end

  defp membership_group_cost(state, id, version, additions, cost) do
    if Map.has_key?(state.groups, id) do
      group = state.groups[id]

      next_group =
        if Map.has_key?(additions, id), do: %{group | sequence: group.sequence + 1}, else: group

      case group_delta(state, id, group, next_group) do
        {:ok, next} -> {:cont, {:ok, cost + next}}
        error -> {:halt, error}
      end
    else
      case group_cost(state, id, empty_group(version)) do
        {:ok, next} -> {:cont, {:ok, cost + next}}
        error -> {:halt, error}
      end
    end
  end

  defp empty_group(version),
    do: %{version: version, members: :gb_trees.empty(), sequence: 0, cursor: nil}

  defp versions(memberships), do: Map.new(memberships, fn {id, row} -> {id, row.version} end)

  defp stored_versions?(memberships, versions) do
    map_size(memberships) == map_size(versions) and
      Enum.all?(memberships, fn {id, row} -> Map.get(versions, id) === row.version end)
  end

  defp updated_membership_charge(state, memberships, versions) do
    with {:ok, empty} <- measured(%{}, state, 0) do
      Enum.reduce_while(memberships, {:ok, empty}, fn {id, row}, {:ok, cost} ->
        # A pair's tuple header has the same tariff as one map entry.
        entry = {id, %{sequence: row.sequence, version: Map.fetch!(versions, id)}}

        with {:ok, entry_cost} <- measured(entry, state, 0),
             true <- cost + entry_cost <= state.session.manifest.limits.max_manifest_bytes do
          {:cont, {:ok, cost + entry_cost}}
        else
          _ -> {:halt, {:error, {:limit, :max_manifest_bytes}}}
        end
      end)
    end
  end

  defp update_versions(memberships, versions),
    do: Map.new(memberships, fn {id, row} -> {id, %{row | version: versions[id]}} end)

  defp current_versions?(state, row, versions) when is_map(versions) do
    map_size(versions) == map_size(row.memberships) and
      Enum.all?(row.memberships, fn {id, _} ->
        Map.has_key?(versions, id) and state.groups[id].version === versions[id]
      end)
  end

  defp current_versions?(_state, _row, _versions), do: false

  defp group_version(%{serial: serial, revision: revision} = version, state)
       when map_size(version) == 2 and is_integer(serial) and serial >= 0,
       do: handle(revision, state)

  defp group_version(_version, _state), do: {:error, :invalid_group_version}
  defp compare_version(nil, _version), do: :new

  defp compare_version(old, new) do
    cond do
      new.serial < old.serial -> :stale
      new.serial > old.serial -> :new
      new.revision === old.revision -> :same
      true -> :conflict
    end
  end

  defp same_lexical(nil, _descriptor), do: :ok

  defp same_lexical(old, new) do
    if old.source_revision === new.source_revision and
         old.analysis_revision === new.analysis_revision and
         old.render_mode === new.render_mode and old.public_id === new.public_id,
       do: :ok,
       else: {:error, :lexical_revision_changed}
  end

  defp proof(state, proof) when is_map(proof) and map_size(proof) in [4, 5] do
    required = [:close_token, :seal_token, :owner_css_epoch, :quiescent?]

    with true <-
           (Enum.all?(required, &Map.has_key?(proof, &1)) and
              Enum.all?(Map.keys(proof), &(&1 in (required ++ [:expected_mutation_version])))) or
             {:error, :invalid_close_proof},
         true <-
           (is_reference(proof.close_token) and is_reference(proof.seal_token) and
              proof.quiescent? === true) or {:error, :invalid_close_proof},
         :ok <- handle(proof.owner_css_epoch, state),
         true <-
           not Map.has_key?(proof, :expected_mutation_version) or
             proof.expected_mutation_version === state.mutation_version or
             {:error, :stale_mutation_version},
         do: :ok
  end

  defp proof(_state, _proof), do: {:error, :invalid_close_proof}

  defp same_run(state, %Job{id: id, authority: {scope, generation, _queue}})
       when is_reference(id),
       do: if(state.session.run === {scope, generation}, do: :ok, else: {:error, :stale_run})

  defp same_run(_state, _job), do: {:error, :invalid_finalizer}
  defp admitting(%{phase: :admitting}), do: :ok
  defp admitting(_state), do: {:error, :closed_export}

  defp preparing(
         %{
           phase: :preparing,
           mutation_version: version,
           close_proof: %{close_token: token, mutation_version: version}
         },
         token
       ),
       do: :ok

  defp preparing(_state, _token), do: {:error, :stale_close}

  defp target(state, id) do
    case Map.fetch(state.targets, id) do
      {:ok, row} -> {:ok, row}
      :error -> {:error, :unknown_target}
    end
  end

  defp active_target(state, id) do
    with {:ok, row} <- target(state, id),
         true <- active?(state, id) or {:error, :inactive_target},
         do: {:ok, row}
  end

  defp active?(state, id), do: outcome(state, id) in [nil, :succeeded]
  defp outcome(state, id), do: state.session.manifest.targets[id].outcome

  defp handle(value, state) do
    if not is_nil(value) do
      measured_handle(value, state)
    else
      {:error, :invalid_handle}
    end
  end

  defp measured_handle(value, state) do
    case StagedIO.measure(value, state.session.manifest.limits.max_manifest_bytes) do
      {:ok, _cost} -> if opaque?(value), do: :ok, else: {:error, :invalid_handle}
      _ -> {:error, :invalid_handle}
    end
  end

  defp opaque?(value)
       when is_reference(value) or is_binary(value) or is_atom(value) or is_integer(value),
       do: true

  defp opaque?(value) when is_tuple(value), do: opaque_tuple?(value, 0)
  defp opaque?(_value), do: false

  defp opaque_tuple?(value, index) when index == tuple_size(value), do: true

  defp opaque_tuple?(value, index),
    do: opaque?(elem(value, index)) and opaque_tuple?(value, index + 1)

  defp row_cost(id, row, state) do
    with {:ok, header} <- measured({id, Map.delete(row, :memberships)}, state, 2048),
         do: {:ok, header + row.membership_charge}
  end

  defp row_delta(state, id, old, new) do
    with {:ok, before} <- row_cost(id, old, state),
         {:ok, after_cost} <- row_cost(id, new, state),
         do: {:ok, after_cost - before}
  end

  defp group_cost(state, id, group), do: measured({id, Map.drop(group, [:members])}, state, 2048)

  defp group_delta(state, id, old, new) do
    with {:ok, before} <- if(is_nil(old), do: {:ok, 0}, else: group_cost(state, id, old)),
         {:ok, after_cost} <- group_cost(state, id, new),
         do: {:ok, after_cost - before}
  end

  defp measured(term, state, overhead) do
    case StagedIO.measure(term, state.session.manifest.limits.max_manifest_bytes) do
      {:ok, cost} -> {:ok, overhead + 8 * cost}
      {:error, _reason} -> {:error, {:limit, :max_manifest_bytes}}
    end
  end

  defp budget(state, fields, record_delta, mutate? \\ true, ring_growth \\ {0, 0}) do
    increment? =
      mutate? and state.phase == :admitting and Map.get(fields, :phase, :admitting) == :admitting

    fields =
      if increment?,
        do: Map.put(fields, :mutation_version, state.mutation_version + 1),
        else: fields

    scalars =
      Map.merge(
        Map.take(state, [
          :phase,
          :sequence,
          :dirty_count,
          :pending_fanouts,
          :unsettled,
          :unprepared,
          :mutation_version,
          :close_proof
        ]),
        Map.drop(fields, [:finalizer])
      )

    {dirty_growth, fanout_growth} = ring_growth

    scalars =
      Map.merge(scalars, %{
        dirty_sequence: state.dirty.sequence + dirty_growth,
        fanout_sequence: state.fanouts.sequence + fanout_growth
      })

    # Finalizer authority includes the owner's queue PID; only its fixed projection is retained.
    finalizer = Map.get(fields, :finalizer, state.finalizer)
    job_cost = if finalizer, do: 8 * :erlang.external_size(finalizer), else: 0

    with {:ok, base} <- measured(scalars, state, 4096),
         base = base + job_cost,
         charge = state.charged_bytes + record_delta + base - state.base_charge,
         session = %{
           state.session
           | descriptor_bytes: state.session.descriptor_bytes + charge - state.charged_bytes
         },
         :ok <- aggregate_bound(session) do
      {:ok,
       struct!(%{state | session: session, charged_bytes: charge, base_charge: base}, fields)}
    end
  end

  defp ring_growth(ring, id), do: if(Map.has_key?(ring.members, id), do: 0, else: 1)

  defp aggregate_bound(session) do
    if session.manifest.metadata_bytes + session.descriptor_bytes <=
         session.manifest.limits.max_manifest_bytes,
       do: :ok,
       else: {:error, {:limit, :max_manifest_bytes}}
  end
end
