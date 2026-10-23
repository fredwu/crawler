defmodule Crawler.Store.ExportTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis
  alias Crawler.Export.Manifest
  alias Crawler.Export.Session
  alias Crawler.Export.StagedIO
  alias Crawler.Export.StagedIO.Ack
  alias Crawler.Job
  alias Crawler.Job.Outcome
  alias Crawler.Store.Export

  @limits %{
    max_targets: 40,
    max_representations: 40,
    max_artifacts: 40,
    max_edges: 200,
    max_manifest_bytes: 4_000_000,
    max_staged_bytes: 16_000_000,
    max_staged_metadata_bytes: 8_000_000,
    max_file_bytes: 4_000_000,
    max_files: 200
  }
  @analysis_limits %{
    max_bytes: 1_000_000,
    max_total_bytes: 8_000_000,
    max_regions: 1000,
    max_depth: 16,
    max_facts: 10_000,
    max_occurrences: 1000,
    max_edits: 1000,
    max_output_bytes: 1_000_000
  }

  setup do
    scope = make_ref()
    generation = {make_ref(), scope, make_ref()}
    authority = {scope, generation, self()}
    epoch = make_ref()
    {:ok, session} = Session.new(String.duplicate("e", 24), {scope, generation}, epoch, @limits)
    {:ok, state} = Export.new(session)

    %{
      state: state,
      epoch: epoch,
      authority: authority,
      finalizer: Job.new(:finalize, authority, %{})
    }
  end

  test "canonical admission replays without copying Jobs or their private opts", c do
    job = job(c, opts: %{private_payload: String.duplicate("secret", 100)})
    assert {:ok, state} = Export.admit(c.state, c.epoch, job)
    assert {:existing, ^state} = Export.admit(state, c.epoch, job)
    assert Map.keys(state.targets) == [job.id]
    assert state.unsettled == 1
    refute inspect(state.targets) =~ "secret"

    assert {:error, :target_identity_changed} =
             Export.admit(state, c.epoch, %{job | interpretation_id: make_ref()})

    assert {:error, :stale_epoch} = Export.admit(state, make_ref(), job)
  end

  test "helper metadata is a reserved subset of Session's existing aggregate cap", c do
    assert c.state.charged_bytes > 0
    assert c.state.session.descriptor_bytes == c.state.charged_bytes
    job = job(c)
    {:ok, wide} = Export.admit(c.state, c.epoch, job)
    used = wide.session.descriptor_bytes + wide.session.manifest.metadata_bytes
    limits = %{@limits | max_manifest_bytes: used - 1}

    {:ok, session} =
      Session.new(c.state.session.manifest.id, c.state.session.run, c.epoch, limits)

    {:ok, small} = Export.new(session)
    assert {:error, {:limit, :max_manifest_bytes}} = Export.admit(small, c.epoch, job)
    assert small.targets == %{}
    assert small.session.manifest.targets == %{}
    assert small.dirty_count == 0
  end

  test "Session IO descriptors consume the same remaining cap without losing helper debit", c do
    {:ok, plan} = StagedIO.plan_source("one.bin", "one", make_ref())
    operation = make_ref()
    {:ok, session} = Session.reserve(c.state.session, c.epoch, operation, plan)
    assert {:ok, state} = Export.put_session(c.state, session)
    assert state.charged_bytes == c.state.charged_bytes
    assert state.session.descriptor_bytes > state.charged_bytes
    assert {:existing, ^state} = Export.put_session(state, state.session)

    assert {:error, :lost_helper_debit} =
             Export.put_session(state, %{
               state.session
               | descriptor_bytes: state.charged_bytes - 1
             })

    used = session.descriptor_bytes + session.manifest.metadata_bytes
    limits = %{@limits | max_manifest_bytes: used - 1}
    {:ok, tiny_session} = Session.new(session.manifest.id, session.run, c.epoch, limits)
    {:ok, tiny} = Export.new(tiny_session)

    assert {:error, {:limit, :max_manifest_bytes}} =
             Session.reserve(tiny.session, c.epoch, operation, plan)
  end

  test "put_session rejects identity, limits, target, outcome and interpretation bypass", c do
    {state, target, descriptor, _bound, _ack} = copy_target(c, c.state, 1)

    assert {:error, :session_identity_changed} =
             Export.put_session(state, %{state.session | run: make_ref()})

    assert {:error, :session_identity_changed} =
             Export.put_session(state, %{state.session | epoch: make_ref()})

    assert {:error, :session_identity_changed} =
             Export.put_session(state, %{
               state.session
               | manifest: %{state.session.manifest | limits: %{@limits | max_edges: 201}}
             })

    {:ok, admitted} = Session.admit(state.session, c.epoch, job(c))
    assert {:error, :session_transition_bypass} = Export.put_session(state, admitted)
    {:ok, settled} = Session.settle(state.session, c.epoch, target, Outcome.new(:succeeded))
    assert {:error, :session_transition_bypass} = Export.put_session(state, settled)
    {:ok, copied} = Session.copy(state.session, c.epoch, target, descriptor.public_id)
    assert {:error, :session_transition_bypass} = Export.put_session(state, copied)
  end

  test "candidate replay is exact and physical or lexical revision cannot change", c do
    {state, target, descriptor, _bound, _ack} = copy_target(c, c.state, 1)
    assert {:existing, 1, ^state} = Export.candidate(state, target, 1, descriptor, %{})
    assert {:superseded, ^state} = Export.candidate(state, target, 0, descriptor, %{})

    assert {:error, :source_revision_mismatch} =
             Export.candidate(state, target, 1, %{descriptor | source_revision: make_ref()}, %{})

    assert {:error, :copy_has_analysis} =
             Export.candidate(
               state,
               target,
               1,
               %{descriptor | analysis_revision: <<0::256>>},
               %{}
             )

    assert {:error, :lexical_revision_changed} =
             Export.candidate(state, target, 1, %{descriptor | public_id: public_id(2)}, %{})

    assert {:error, :invalid_descriptor} =
             Export.candidate(state, target, 1, Map.put(descriptor, :payload, "body"), %{})

    assert state.targets[target].version == 1
  end

  test "oversize membership metadata rejects before indexed state growth", c do
    {state, target, descriptor, _bound, _ack} = copy_target(c, c.state, 1)
    memberships = Map.new(1..1000, fn serial -> {make_ref(), group_version(serial)} end)

    assert {:error, {:limit, :max_manifest_bytes}} =
             Export.candidate(state, target, 1, descriptor, memberships)

    assert state.groups == %{}
    assert state.targets[target].memberships == %{}
    assert state.targets[target].version == 1
    assert state.session.descriptor_bytes >= state.charged_bytes
  end

  test "candidate source must match its canonical target response before helper growth", c do
    left = job(c)
    right = job(c)
    {:ok, state} = Export.admit(c.state, c.epoch, left)
    {:ok, state} = Export.admit(state, c.epoch, right)
    left_revision = make_ref()
    right_revision = make_ref()

    {:ok, left_plan} =
      StagedIO.plan_source("source/left.bin", "left physical source", left_revision)

    {:ok, right_plan} =
      StagedIO.plan_source("source/right.bin", "right physical source", right_revision)

    {state, left_operation, _ack} = stage(state, left_plan)
    {state, right_operation, _ack} = stage(state, right_plan)

    descriptor = %{
      source_operation: right_operation,
      lexical_operation: nil,
      source_revision: right_revision,
      analysis_revision: nil,
      public_id: public_id(1),
      render_mode: :copy
    }

    own_descriptor = %{
      descriptor
      | source_operation: left_operation,
        source_revision: left_revision
    }

    without_responses = state

    assert {:error, :missing_target_response} =
             Export.candidate(state, left.id, 0, own_descriptor, %{})

    assert state === without_responses
    assert state.targets[left.id].version == 0
    assert state.targets[left.id].descriptor == nil
    state = response(state, left.id, left_operation, "application/octet-stream")
    state = response(state, right.id, right_operation, "application/octet-stream")

    group = make_ref()
    memberships = %{group => group_version(1)}
    original = state

    assert {:error, :target_source_mismatch} =
             Export.candidate(state, left.id, 0, descriptor, memberships)

    assert state === original
    assert state.targets[left.id].version == 0
    assert state.targets[left.id].descriptor == nil
    assert state.targets[right.id].version == 0
    assert state.dirty === original.dirty
    assert state.dirty_count == 2
    assert state.groups == %{}
    assert state.charged_bytes == original.charged_bytes
    assert state.session.descriptor_bytes == original.session.descriptor_bytes

    assert {:ok, 1, accepted} = Export.candidate(state, left.id, 0, own_descriptor, memberships)
    assert accepted.targets[left.id].descriptor === own_descriptor
    assert Map.keys(accepted.groups) == [group]
    assert accepted.dirty_count == 2

    assert {:ok, 1, accepted} =
             Export.candidate(accepted, right.id, 0, %{descriptor | public_id: public_id(2)}, %{})

    assert accepted.targets[right.id].descriptor.source_operation == right_operation
  end

  test "discovery rejects payload-shaped operation handles before staged lookup", c do
    {state, target, _descriptor, bound, _ack} = copy_target(c, c.state, 1)
    original = state

    for operation <- [nil, {:payload, %{body: "unowned bytes"}}] do
      assert {:error, :invalid_bound} =
               Export.discovered(state, target, 1, %{}, %{bound | operation: operation})

      assert state === original
      assert state.targets[target].bound == nil
      assert state.dirty_count == 1
    end

    assert {:ok, discovered} = Export.discovered(state, target, 1, %{}, bound)
    assert discovered.targets[target].bound === bound
    assert discovered.dirty_count == 0
  end

  test "wide nested tuple handles reject aggregate growth under the same tight cap", c do
    group = {:owner_group, List.to_tuple(Enum.map(1..128, &{make_ref(), &1}))}
    {:ok, handle_cost} = StagedIO.measure(group, @limits.max_manifest_bytes)
    cap = max(c.state.charged_bytes + 1024, handle_cost + 1024)
    limits = %{@limits | max_manifest_bytes: cap}

    {:ok, session} =
      Session.new(c.state.session.manifest.id, c.state.session.run, c.epoch, limits)

    {:ok, state} = Export.new(session)
    assert cap - state.session.descriptor_bytes < 8 * handle_cost
    original = state

    assert {:error, {:limit, :max_manifest_bytes}} =
             Export.invalidate(state, group, group_version(1))

    assert state === original
    assert state.groups == %{}
    assert state.pending_fanouts == 0
    assert state.fanouts.members == %{}
    assert state.charged_bytes == original.charged_bytes
    assert state.session.descriptor_bytes == original.session.descriptor_bytes
  end

  test "exact group versions reject lower serial and equal-serial token conflicts", c do
    group = make_ref()
    version = group_version(3)
    {state, target, descriptor, bound, _ack} = copy_target(c, c.state, 1, %{group => version})
    {:ok, state} = Export.discovered(state, target, 1, %{group => version}, bound)
    assert {:existing, ^state} = Export.invalidate(state, group, version)
    assert {:stale, ^state} = Export.invalidate(state, group, group_version(2))

    assert {:error, :group_version_conflict} =
             Export.invalidate(state, group, group_version(3))

    assert {:error, :stale_group_version} =
             Export.candidate(state, target, 1, descriptor, %{group => group_version(2)})

    assert {:error, :invalid_group_version} =
             Export.invalidate(state, group, %{serial: -1, revision: make_ref()})
  end

  test "fanout visits and dispatches share the batch bound and cannot close mid-cursor", c do
    group = make_ref()
    version = group_version(1)
    {state, targets} = clean_copies(c, 5, %{group => version})
    {:ok, state} = Export.invalidate(state, group, group_version(2))
    assert state.pending_fanouts == 1
    assert state.dirty_count == 0
    assert {:busy, ^state} = Export.close(state, c.epoch, proof(state), c.finalizer)
    {:ok, [], 1, next} = Export.refresh_batch(state, 1)
    assert next.pending_fanouts == 1
    assert next.dirty_count == 1
    {next, dispatched, visits} = drain_refresh(next, 1)
    assert MapSet.new(dispatched) == MapSet.new(targets)
    assert Enum.all?(visits, &(&1 <= 1))
    assert next.pending_fanouts == 0
    assert next.dirty_count == 5
    assert {:waiting, ^next} = Export.refresh_batch(next, 1)
  end

  test "coalesced fanout retains one obligation and includes new members after its high water",
       c do
    group = make_ref()
    version = group_version(1)
    {state, [old_target]} = clean_copies(c, 1, %{group => version})
    newest = group_version(4)
    {:ok, state} = Export.invalidate(state, group, group_version(2))
    {:ok, state} = Export.invalidate(state, group, group_version(3))
    {:ok, state} = Export.invalidate(state, group, newest)
    assert state.pending_fanouts == 1

    {state, new_target, _descriptor, _bound, _ack} =
      copy_target(c, state, 2, %{group => newest})

    {state, dispatched, visits} = drain_refresh(state, 2)
    assert old_target in dispatched
    assert new_target in dispatched
    assert Enum.all?(visits, &(&1 <= 2))
    assert state.pending_fanouts == 0
    assert state.groups[group].version == newest
    assert state.groups[group].cursor == nil
    refute Map.has_key?(state.groups[group], :iterator)
  end

  test "membership removal does not leave stale indexed targets", c do
    group = make_ref()
    version = group_version(1)
    {state, target, descriptor, bound, _ack} = copy_target(c, c.state, 1, %{group => version})
    {:ok, state} = Export.discovered(state, target, 1, %{group => version}, bound)
    {:ok, 2, state} = Export.candidate(state, target, 1, descriptor, %{})
    {:ok, state} = Export.discovered(state, target, 2, %{}, bound)
    assert :gb_trees.is_empty(state.groups[group].members)
    {:ok, state} = Export.invalidate(state, group, group_version(2))
    {state, dispatched, _visits} = drain_refresh(state, 1)
    assert dispatched == []
    assert state.dirty_count == 0
    assert {:done, ^state} = Export.refresh_batch(state, 1)
  end

  test "a current discovery is not dirtied again by a late fanout cursor visit", c do
    group = make_ref()
    first = group_version(1)
    {state, target, _descriptor, bound, _ack} = copy_target(c, c.state, 1, %{group => first})
    {:ok, state} = Export.discovered(state, target, 1, %{group => first}, bound)
    newest = group_version(2)
    {:ok, state} = Export.invalidate(state, group, newest)
    {:ok, state} = Export.discovered(state, target, 1, %{group => newest}, bound)
    {state, dispatched, _visits} = drain_refresh(state, 1)
    assert dispatched == []
    assert state.dirty_count == 0
    assert {:done, ^state} = Export.refresh_batch(state, 1)
  end

  test "a missing provisional candidate cannot starve a ready target", c do
    pending = job(c)
    {:ok, state} = Export.admit(c.state, c.epoch, pending)
    {state, ready, _descriptor, _bound, _ack} = copy_target(c, state, 1)
    {state, dispatched, visits} = drain_refresh(state, 1)
    assert dispatched == [ready]
    assert Enum.all?(visits, &(&1 <= 1))
    assert state.targets[pending.id].descriptor == nil
    assert state.dirty_count == 2
    assert {:waiting, ^state} = Export.refresh_batch(state, 1)
    assert {:busy, ^state} = Export.close(state, c.epoch, proof(state), c.finalizer)
  end

  test "CSS group and owner epoch accept bounded opaque owner tokens", c do
    group = "https://example.test/styles/main.css"
    version = %{serial: 7, revision: {make_ref(), 42}}
    {state, target, _descriptor, bound, _ack} = copy_target(c, c.state, 1, %{group => version})
    {:ok, state} = Export.discovered(state, target, 1, %{group => version}, bound)
    {:ok, state} = Export.settle(state, c.epoch, target, Outcome.new(:succeeded))
    owner_epoch = {make_ref(), :css_commit_epoch, 150}
    proof = %{proof(state) | owner_css_epoch: owner_epoch}
    {:ok, _token, state} = Export.close(state, c.epoch, proof, c.finalizer)
    assert state.close_proof.owner_css_epoch === owner_epoch
    assert state.groups[group].version === version
  end

  test "stale discovery requeues in-flight work and exact group keys are required", c do
    group = make_ref()
    version = group_version(1)
    {state, target, descriptor, bound, _ack} = copy_target(c, c.state, 1, %{group => version})
    {:ok, [^target], 1, state} = Export.refresh_batch(state, 1)
    assert {:waiting, ^state} = Export.refresh_batch(state, 1)
    assert {:superseded, state} = Export.discovered(state, target, 1, %{}, bound)
    {:ok, [^target], 1, state} = Export.refresh_batch(state, 1)

    assert {:superseded, state} =
             Export.discovered(
               state,
               target,
               1,
               %{group => version, make_ref() => version},
               bound
             )

    {:ok, 2, state} = Export.candidate(state, target, 1, descriptor, %{})
    assert {:superseded, state} = Export.discovered(state, target, 1, %{}, bound)
    assert state.dirty_count == 1
    {:ok, [^target], 1, state} = Export.refresh_batch(state, 1)
    assert {:ok, clean} = Export.discovered(state, target, 2, %{}, bound)
    assert {:existing, ^clean} = Export.discovered(clean, target, 2, %{}, bound)
    assert {:done, ^clean} = Export.refresh_batch(clean, 1)
  end

  test "initial discovery is skipped and successful settlement re-enrolls its dirty row", c do
    {state, target, _descriptor, _bound, _ack} = copy_target(c, c.state, 1, %{})
    assert {:ok, [], 1, state} = Export.refresh_batch(state, 1, fn _ -> false end)
    assert state.targets[target].dirty?
    refute state.targets[target].refreshing?
    assert {:waiting, ^state} = Export.refresh_batch(state, 1)
    assert {:ok, state} = Export.settle(state, c.epoch, target, Outcome.new(:succeeded))
    assert {:ok, [^target], 1, _state} = Export.refresh_batch(state, 1)
  end

  test "an abandoned refresh requeues only its exact owner and version", c do
    {state, target, _descriptor, _bound, _ack} = copy_target(c, c.state, 1, %{})
    owner = {make_ref(), make_ref()}
    other = {make_ref(), make_ref()}
    assert {:ok, [^target], 1, state} = Export.refresh_batch(state, 1, fn _ -> true end, owner)
    assert {:ok, ^state} = Export.release_refresh(state, other, [{target, 1}])
    assert {:ok, ^state} = Export.release_refresh(state, owner, [{target, 0}])
    assert {:ok, state} = Export.release_refresh(state, owner, [{target, 1}])
    assert {:ok, [^target], 1, next} = Export.refresh_batch(state, 1, fn _ -> true end, other)
    assert {:ok, ^next} = Export.release_refresh(next, owner, [{target, 1}])
    assert next.targets[target].refresh_owner === other
  end

  test "clean refresh release is inert and new group invalidation revokes an old selection", c do
    group = make_ref()
    first = group_version(1)
    {state, target, _descriptor, bound, _ack} = copy_target(c, c.state, 1, %{group => first})
    owner = {make_ref(), make_ref()}
    assert {:ok, [^target], 1, state} = Export.refresh_batch(state, 1, fn _ -> true end, owner)
    assert {:ok, state} = Export.discovered(state, target, 1, %{group => first}, bound)
    assert {:ok, ^state} = Export.release_refresh(state, owner, [{target, 1}])
    assert {:ok, state} = Export.invalidate(state, group, group_version(2))
    assert {:ok, [^target], _visits, state} = drain_owned(state, owner)
    other = {make_ref(), make_ref()}
    assert {:ok, state} = Export.release_refresh(state, owner, [{target, 1}])
    assert {:ok, [^target], 1, state} = Export.refresh_batch(state, 1, fn _ -> true end, other)
    assert {:ok, ^state} = Export.release_refresh(state, owner, [{target, 1}])
  end

  defp drain_owned(state, owner), do: Export.refresh_batch(state, 16, fn _ -> true end, owner)

  test "failed targets stop refresh and are omitted from bounded preparation", c do
    {state, target, _descriptor, _bound, _ack} = copy_target(c, c.state, 1)
    {:ok, state} = Export.settle(state, c.epoch, target, Outcome.new(:failed, :network))
    assert state.dirty_count == 0
    assert state.unsettled == 0
    assert state.unprepared == 0
    assert {:error, :inactive_target} = Export.discovered(state, target, 1, %{}, %{})
    {:ok, token, state} = Export.close(state, c.epoch, proof(state), c.finalizer)
    assert {:ok, [], cursor} = Export.prepare_next(state, token, nil, 1)
    assert :done = Export.prepare_next(state, token, cursor, 1)
    assert {:ok, snapshot, _state} = Export.seal(state, token)
    assert snapshot.artifacts == %{}
  end

  test "duplicate canonical terminal settlement preserves counts and metadata debit", c do
    {state, target, _descriptor, _bound, _ack} = copy_target(c, c.state, 1)
    outcome = Outcome.new(:failed, :network)
    {:ok, state} = Export.settle(state, c.epoch, target, outcome)
    assert {:existing, ^state} = Export.settle(state, c.epoch, target, outcome)

    assert {:error, :outcome_exists} =
             Export.settle(state, c.epoch, target, Outcome.new(:succeeded))

    assert state.unsettled == 0
    assert state.unprepared == 0
    assert state.dirty_count == 0
  end

  test "owner terminal Session projection is monotonic and keeps helper debit", c do
    {:ok, token, state} = Export.close(c.state, c.epoch, proof(c.state), c.finalizer)
    {:ok, _snapshot, state} = Export.seal(state, token)
    debit = state.charged_bytes
    {:ok, cancelled} = Session.terminate(state.session, Outcome.new(:cancelled, :owner_revoked))
    assert {:ok, ended} = Export.put_session(state, cancelled)
    assert ended.session.manifest.state == :cancelled
    assert ended.charged_bytes >= debit
    assert ended.session.descriptor_bytes >= ended.charged_bytes
    assert {:error, :closed_export} = Export.admit(ended, c.epoch, job(c))
    assert {:error, :session_transition_bypass} = Export.put_session(ended, state.session)
  end

  test "owner rendering and readiness projections preserve sealed target bindings", c do
    {state, target, _descriptor, bound, ack} = copy_target(c, c.state, 1)
    {:ok, state} = Export.discovered(state, target, 1, %{}, bound)
    {:ok, state} = Export.settle(state, c.epoch, target, Outcome.new(:succeeded))
    {:ok, token, state} = Export.close(state, c.epoch, proof(state), c.finalizer)
    {:ok, state} = Export.prepared(state, token, target, ack, [])
    {:ok, snapshot, state} = Export.seal(state, token)
    edges = state.session.manifest.edges
    interpretations = state.session.manifest.interpretations

    {:ok, output_plan} =
      StagedIO.plan_bytes(:archive, snapshot.artifacts[target].path, <<0, 255, 1>>)

    {state, output_operation, _ack} = stage(state, output_plan)

    {:ok, session} =
      Session.rendered(state.session, c.epoch, snapshot.seal_token, target, output_operation)

    assert {:ok, state} = Export.put_session(state, session)
    assert state.session.manifest.rendered[target] == output_operation
    {:ok, public_plan} = StagedIO.plan_bytes(:archive, "manifest.json", "{}")
    {state, manifest_operation, _ack} = stage(state, public_plan)

    assert :ok =
             Session.validate_commit(
               state.session,
               c.epoch,
               snapshot.seal_token,
               c.finalizer.id,
               manifest_operation
             )

    {:ok, session} = Session.promoted(state.session, manifest_operation, Outcome.new(:succeeded))
    assert {:ok, state} = Export.put_session(state, session)
    assert state.session.manifest.state == :ready
    assert state.session.manifest.edges === edges
    assert state.session.manifest.interpretations === interpretations
    assert state.session.finalizer.id == c.finalizer.id
  end

  test "close needs settled clean targets, explicit owner proof and the same epoch", c do
    {state, target, _descriptor, bound, _ack} = copy_target(c, c.state, 1)
    assert {:busy, ^state} = Export.close(state, c.epoch, proof(state), c.finalizer)
    {:ok, state} = Export.discovered(state, target, 1, %{}, bound)
    assert {:busy, ^state} = Export.close(state, c.epoch, proof(state), c.finalizer)
    {:ok, state} = Export.settle(state, c.epoch, target, Outcome.new(:succeeded))

    assert {:error, :invalid_close_proof} =
             Export.close(state, c.epoch, %{proof(state) | quiescent?: false}, c.finalizer)

    assert {:error, :stale_mutation_version} =
             Export.close(
               state,
               c.epoch,
               %{proof(state) | expected_mutation_version: -1},
               c.finalizer
             )

    assert {:error, :stale_epoch} = Export.close(state, make_ref(), proof(state), c.finalizer)
    assert {:error, :invalid_finalizer} = Export.close(state, c.epoch, proof(state), job(c))
  end

  test "close pins owner CSS epoch independently and projects one canonical finalizer", c do
    css_epoch = make_ref()
    finalizer = %{c.finalizer | opts: %{payload: "private"}, prepared_request: %{body: "secret"}}
    proof = %{proof(c.state) | owner_css_epoch: css_epoch}
    {:ok, token, state} = Export.close(c.state, c.epoch, proof, finalizer)
    assert state.phase == :preparing
    assert state.session.manifest.state == :admitting
    assert state.close_proof.owner_css_epoch === css_epoch
    assert state.close_proof.mutation_version == c.state.mutation_version
    refute state.close_proof.owner_css_epoch === state.close_proof.mutation_version
    assert state.finalizer.id == finalizer.id
    assert state.finalizer.opts == %{}
    assert state.finalizer.prepared_request == nil
    assert {:error, :closed_export} = Export.close(state, c.epoch, proof, c.finalizer)
    assert {:error, :closed_export} = Export.admit(state, c.epoch, job(c))
    assert {:error, :closed_export} = Export.invalidate(state, make_ref(), group_version(1))
    assert {:ok, _snapshot, sealed} = Export.seal(state, token)
    assert sealed.session.finalizer.id == finalizer.id
    assert sealed.session.manifest.seal_token == proof.seal_token
    assert {:error, :stale_close} = Export.seal(sealed, token)
  end

  test "preparing permits staged final metadata but blocks response or interpretation bypass",
       c do
    {state, target, descriptor, bound, ack} = copy_target(c, c.state, 1)
    {:ok, state} = Export.discovered(state, target, 1, %{}, bound)
    {:ok, state} = Export.settle(state, c.epoch, target, Outcome.new(:succeeded))
    {:ok, token, state} = Export.close(state, c.epoch, proof(state), c.finalizer)
    assert {:error, :pending_preparation} = Export.seal(state, token)
    assert {:error, :closed_export} = Export.candidate(state, target, 1, descriptor, %{})
    assert {:error, :closed_export} = Export.discovered(state, target, 1, %{}, bound)

    assert {:error, :closed_export} =
             Export.settle(state, c.epoch, target, Outcome.new(:succeeded))

    {:ok, copied} = Session.copy(state.session, c.epoch, target, descriptor.public_id)
    assert {:error, :session_transition_bypass} = Export.put_session(state, copied)
    response = Map.fetch!(state.session.manifest.responses, target_representation(state, target))

    responses =
      Map.put(
        state.session.manifest.responses,
        target_representation(state, target),
        Map.put(response, :final_url, "https://example.test/changed")
      )

    assert {:error, :closed_response} =
             Export.put_session(state, %{
               state.session
               | manifest: %{state.session.manifest | responses: responses}
             })

    assert {:error, :stale_close} = Export.prepared(state, make_ref(), target, ack, [])
    assert {:ok, state} = Export.prepared(state, token, target, ack, [])
    assert state.unprepared == 0
    assert {:existing, ^state} = Export.prepared(state, token, target, ack, [])

    assert {:error, :invalid_copy_preparation} =
             Export.prepared(state, token, target, ack, [%{id: :changed}])

    assert {:error, :already_prepared} =
             Export.prepared(state, token, target, put_in(ack.ack.ticket, make_ref()), [])

    assert {:ok, snapshot, _sealed} = Export.seal(state, token)
    assert snapshot.artifacts[target].render_mode == :copy
    assert snapshot.edges[target] == %{}
  end

  test "rewrite final metadata may use a new operation only with exact revision stamp and edges",
       c do
    {state, target, descriptor, bound, edges, plan} = rewrite_target(c, c.state, 1, nil)
    {:ok, state} = Export.discovered(state, target, 1, %{}, bound)
    {:ok, state} = Export.settle(state, c.epoch, target, Outcome.new(:succeeded))
    {:ok, token, state} = Export.close(state, c.epoch, proof(state), c.finalizer)
    assert state.session.manifest.interpretations == %{}
    {state, final_operation, final_ack} = stage(state, %{plan | path: "metadata/final.bin"})
    refute final_operation == bound.operation

    assert {:error, :changed_occurrence_collection} =
             Export.prepared(state, token, target, final_ack, [])

    {changed_state, _operation, changed_ack} =
      stage(state, %{plan | path: "metadata/changed.bin", css_revision: make_ref()})

    assert {:error, :changed_occurrence_collection} =
             Export.prepared(changed_state, token, target, changed_ack, edges)

    assert {:ok, state} = Export.prepared(state, token, target, final_ack, edges)

    assert {:error, :changed_occurrence_collection} =
             Export.prepared(state, token, target, final_ack, [])

    assert state.session.manifest.interpretations[target].analysis_revision ==
             descriptor.analysis_revision

    assert state.session.manifest.interpretations[target].occurrences_handle == final_operation
    assert {:ok, _snapshot, _sealed} = Export.seal(state, token)
  end

  test "cycle bindings use exact canonical targets and fixed eligible paths at seal", c do
    left = job(c)
    right = job(c)
    {:ok, state} = Export.admit(c.state, c.epoch, left)
    {:ok, state} = Export.admit(state, c.epoch, right)

    {state, left_id, _, left_bound, left_edges, left_plan} =
      rewrite_target(c, state, 1, right.id, left)

    {state, right_id, _, right_bound, right_edges, right_plan} =
      rewrite_target(c, state, 2, left.id, right)

    {:ok, state} = Export.discovered(state, left_id, 1, %{}, left_bound)
    {:ok, state} = Export.discovered(state, right_id, 1, %{}, right_bound)
    {:ok, state} = Export.settle(state, c.epoch, left_id, Outcome.new(:succeeded))
    {:ok, state} = Export.settle(state, c.epoch, right_id, Outcome.new(:succeeded))
    {:ok, token, state} = Export.close(state, c.epoch, proof(state), c.finalizer)
    {:ok, [first], cursor} = Export.prepare_next(state, token, nil, 1)
    assert first.target == left_id
    {:ok, [second], next_cursor} = Export.prepare_next(state, token, cursor, 1)
    assert second.target == right_id
    assert :done = Export.prepare_next(state, token, next_cursor, 1)

    {:ok, state} =
      Export.prepared(
        state,
        token,
        left_id,
        staged_ack(left_bound.operation, left_plan),
        left_edges
      )

    {:ok, state} =
      Export.prepared(
        state,
        token,
        right_id,
        staged_ack(right_bound.operation, right_plan),
        right_edges
      )

    assert {:ok, [], completed_cursor} = Export.prepare_next(state, token, nil, 2)
    assert :done = Export.prepare_next(state, token, completed_cursor, 2)
    {:ok, snapshot, sealed} = Export.seal(state, token)
    assert {:local, "./" <> _} = Manifest.resolve(snapshot, left_id, hd(left_edges))
    assert {:local, "./" <> _} = Manifest.resolve(snapshot, right_id, hd(right_edges))
    assert snapshot.artifacts[left_id].path != snapshot.artifacts[right_id].path
    assert sealed.session.finalizer.id == c.finalizer.id
  end

  test "invalid batch limits and cursors cannot persist an iterator or reopen state", c do
    assert {:error, :invalid_batch_limit} = Export.refresh_batch(c.state, 0)
    {:ok, token, state} = Export.close(c.state, c.epoch, proof(c.state), c.finalizer)
    assert {:error, :invalid_batch_limit} = Export.prepare_next(state, token, nil, 0)
    assert {:error, :invalid_cursor} = Export.prepare_next(state, token, :iterator, 1)
    assert {:error, :invalid_cursor} = Export.prepare_next(state, token, 0, 1)
    assert {:error, :stale_close} = Export.prepare_next(state, make_ref(), nil, 1)
    refute Map.has_key?(Map.from_struct(state), :iterator)
    assert state.session.manifest.state == :admitting
  end

  defp job(c, attrs \\ []) do
    Job.new(
      :fetch,
      c.authority,
      Map.merge(%{representation_id: make_ref(), interpretation_id: make_ref()}, Map.new(attrs))
    )
  end

  defp public_id(n), do: n |> Integer.to_string(16) |> String.pad_leading(24, "0")
  defp group_version(serial), do: %{serial: serial, revision: make_ref()}

  defp proof(state) do
    %{
      close_token: make_ref(),
      seal_token: make_ref(),
      owner_css_epoch: make_ref(),
      quiescent?: true,
      expected_mutation_version: state.mutation_version
    }
  end

  defp copy_target(c, state, number, memberships \\ %{}) do
    job = job(c)
    {:ok, state} = Export.admit(state, c.epoch, job)
    revision = make_ref()

    {:ok, plan} =
      StagedIO.plan_source("source/#{public_id(number)}.bin", <<0, 255, number>>, revision)

    {state, operation, ack} = stage(state, plan)
    state = response(state, job.id, operation, "application/octet-stream")

    descriptor = %{
      source_operation: operation,
      lexical_operation: nil,
      source_revision: revision,
      analysis_revision: nil,
      public_id: public_id(number),
      render_mode: :copy
    }

    {:ok, 1, state} = Export.candidate(state, job.id, 0, descriptor, memberships)

    bound = %{
      operation: operation,
      source_revision: revision,
      analysis_revision: nil,
      css_stamp: nil,
      edges_digest: StagedIO.edge_digest([])
    }

    {state, job.id, descriptor, bound, ack}
  end

  defp rewrite_target(c, state, number, child, admitted_job \\ nil) do
    job = admitted_job || job(c)

    state =
      case Export.admit(state, c.epoch, job) do
        {:ok, state} -> state
        {:existing, state} -> state
      end

    source = ~s|<a href="https://user:password@example.test/child#part">child</a>|

    opts =
      Map.merge(@analysis_limits, %{
        url: "https://example.test/page",
        content_type: "text/html",
        assets: []
      })

    {:ok, analysis} = Analysis.analyze(source, opts)
    {:ok, original} = Analysis.occurrences_result(analysis, opts)
    {:ok, collection} = Analysis.bind(original, fn _occurrence -> child end)
    revision = make_ref()

    {:ok, source_plan} =
      StagedIO.plan_source("source/#{public_id(number)}.html", source, revision)

    {state, source_operation, _ack} = stage(state, source_plan)
    state = response(state, job.id, source_operation, "text/html")
    css_stamp = make_ref()

    {:ok, metadata_plan} =
      StagedIO.plan_metadata(
        "metadata/#{public_id(number)}.bin",
        analysis,
        original,
        collection,
        css_stamp,
        revision,
        %{unavailable: 0, root: :borrowed}
      )

    # An owner-supplied encoded-plan digest is sufficient for these pure transitions.
    # Encoding, physical writes and credit authority are tested by their real owners.
    metadata_plan = %{
      metadata_plan
      | digest:
          :crypto.hash(
            :sha256,
            :erlang.term_to_binary({number, analysis.revision, collection.occurrences})
          )
    }

    {state, metadata_operation, _ack} = stage(state, metadata_plan)

    descriptor = %{
      source_operation: source_operation,
      lexical_operation: metadata_operation,
      source_revision: revision,
      analysis_revision: analysis.revision,
      public_id: public_id(number),
      render_mode: :rewrite
    }

    {:ok, 1, state} = Export.candidate(state, job.id, 0, descriptor, %{})

    bound = %{
      operation: metadata_operation,
      source_revision: revision,
      analysis_revision: analysis.revision,
      css_stamp: css_stamp,
      edges_digest: metadata_plan.edges_digest
    }

    {state, job.id, descriptor, bound, StagedIO.compact_edges(collection.occurrences),
     metadata_plan}
  end

  defp stage(state, plan) do
    operation = make_ref()
    ack = %Ack{plan: plan, ticket: make_ref()}
    {:ok, session} = Session.reserve(state.session, state.session.epoch, operation, plan)
    {:ok, state} = Export.put_session(state, session)
    {:ok, session} = Session.written(state.session, state.session.epoch, operation, ack)
    {:ok, state} = Export.put_session(state, session)
    {state, operation, %{operation: operation, ack: ack}}
  end

  defp staged_ack(operation, plan),
    do: %{operation: operation, ack: %Ack{plan: plan, ticket: make_ref()}}

  defp response(state, target, operation, type) do
    {:ok, session} =
      Session.response(
        state.session,
        state.session.epoch,
        target,
        operation,
        type,
        "https://example.test/resource"
      )

    {:ok, state} = Export.put_session(state, session)
    state
  end

  defp target_representation(state, target),
    do: state.session.manifest.targets[target].representation_id

  defp clean_copies(c, count, memberships) do
    Enum.reduce(1..count, {c.state, []}, fn number, {state, targets} ->
      {state, target, _descriptor, bound, _ack} = copy_target(c, state, number, memberships)
      {:ok, state} = Export.discovered(state, target, 1, memberships, bound)
      {:ok, state} = Export.settle(state, c.epoch, target, Outcome.new(:succeeded))
      {state, targets ++ [target]}
    end)
  end

  defp drain_refresh(state, limit, remaining \\ 100, ids \\ [], visits \\ [])

  defp drain_refresh(_state, _limit, 0, _ids, _visits),
    do: flunk("bounded fixture refresh did not terminate")

  defp drain_refresh(state, limit, remaining, ids, visits) do
    case Export.refresh_batch(state, limit) do
      {:ok, batch, visited, next} ->
        assert visited <= limit
        drain_refresh(next, limit, remaining - 1, ids ++ batch, [visited | visits])

      {:waiting, state} ->
        {state, ids, visits}

      {:done, state} ->
        {state, ids, visits}
    end
  end
end
