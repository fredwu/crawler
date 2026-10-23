defmodule Crawler.FrontierTest do
  use ExUnit.Case, async: true

  alias Crawler.Frontier
  alias Crawler.Job
  alias Crawler.Job.Identity
  alias Crawler.Job.Outcome

  setup do
    scope = make_ref()
    %{authority: {scope, {make_ref(), scope, make_ref()}, self()}, queue: self()}
  end

  test "duplicate fan-out retains one bounded interpretation after frozen identity", context do
    job = job(context, :same, :anonymous)
    identity = identity(:same, :anonymous, :module)
    {:accepted, accepted, state} = Frontier.admit(Frontier.new(), job, identity, charge())

    state =
      Enum.reduce(1..1_000, state, fn _, state ->
        assert {:existing, interpretation, same} = Frontier.admit(state, job, identity, charge())
        assert interpretation == accepted.id
        assert same == state
        same
      end)

    assert Frontier.pending(state) == 1
    assert map_size(state.jobs) == 1
    assert Frontier.bytes(state).metadata > 16
    assert Frontier.bytes(state).payload == 32
    assert {:error, :unprepared_request, ^state} = Frontier.admit(state, job, nil, charge())
  end

  test "provisional commands are bounded without consuming effective representation slots",
       context do
    state = Frontier.new(max_representations: 1, max_pending: 2)

    provisional = fn ->
      %Identity{
        representation: make_ref(),
        interpretation: :control,
        representation_class: :provisional
      }
    end

    one = job(context, :same, :anonymous, kind: :sitemap)
    two = job(context, :same, :anonymous, kind: :sitemap)
    {:accepted, one, state} = Frontier.admit(state, one, provisional.(), charge())
    {:accepted, two, state} = Frontier.admit(state, two, provisional.(), charge())
    assert state.representation_count == 0
    assert state.runs[Frontier.run_key(one)].representation_count == 0
    assert map_size(state.representations) == 2

    assert {:limited, :max_pending, _} =
             Frontier.admit(
               state,
               job(context, :third, :anonymous, kind: :sitemap),
               provisional.(),
               charge()
             )

    {:ok, state} = Frontier.wait(state, one.id, :prepare)

    {:ok, one, state} =
      Frontier.rebind(state, one.id, identity(:same, :anonymous, :control), one.opts)

    assert state.representation_count == 1
    {:ok, state} = Frontier.wait(state, two.id, :prepare)

    assert {:limited, :max_representations, ^state} =
             Frontier.rebind(state, two.id, identity(:same, :different, :control), two.opts)

    {:ok, two, state} =
      Frontier.rebind(state, two.id, identity(:same, :anonymous, :control), two.opts)

    assert one.representation_id == two.representation_id
    assert state.representation_count == 1
    key = Frontier.run_key(one)
    {:retired, state} = Frontier.retire_run(state, key)
    {:done, settled, state} = Frontier.settle_batch(state, key)
    assert length(settled) == 2
    {:done, 3, state} = Frontier.dispose_batch(state, key)
    assert state.representation_count == 0
    assert state.representations == %{}
    assert state.jobs == %{}
    assert Frontier.bytes(state).metadata == 0
  end

  test "one job handle cannot overwrite a distinct admitted identity", context do
    job = job(context, :same, :anonymous)

    {:accepted, _, state} =
      Frontier.admit(Frontier.new(), job, identity(:same, :anonymous, :module), charge())

    assert {:error, :job_id_reused, ^state} =
             Frontier.admit(state, job, identity(:same, :credentialed, :module), charge())

    assert map_size(state.jobs) == 1
  end

  for first <- [:succeeded, :failed] do
    test "concurrent representations reserve/count once when first is #{first}", context do
      {one, state} = admit(Frontier.new(), context, :same, :anonymous, :module, max_pages: 1)
      {two, state} = admit(state, context, :same, :credentialed, :module, max_pages: 1)
      assert one.representation_id != two.representation_id
      assert {:ok, claim_one, _, state} = Frontier.checkout(state, context.queue)
      assert {:ok, claim_two, _, state} = Frontier.checkout(state, context.queue)
      key = Frontier.run_key(one)
      assert Frontier.counts(state, key).reserved == 1
      assert {:ok, state} = Frontier.complete(state, claim_one, Outcome.new(unquote(first)))
      second = if unquote(first) == :succeeded, do: :failed, else: :succeeded
      assert {:ok, state} = Frontier.complete(state, claim_two, Outcome.new(second))
      assert Frontier.counts(state, key) == %{completed: 1, reserved: 0, controls: 0}
      assert {:stale, ^state} = Frontier.complete(state, claim_one, Outcome.new(:failed))
    end
  end

  test "a processed alias updates an active and pending logical group without changing outcomes",
       context do
    {source, state} = admit(Frontier.new(), context, :source, :anonymous, :module, max_pages: 2)
    {:ok, source_claim, _, state} = Frontier.checkout(state, context.queue)
    {active, state} = admit(state, context, :landing, :anonymous, :module, max_pages: 2)
    {:ok, active_claim, _, state} = Frontier.checkout(state, context.queue)
    {pending, state} = admit(state, context, :landing, :credentialed, :module, max_pages: 1)
    key = Frontier.run_key(source)
    assert Frontier.counts(state, key) == %{completed: 0, reserved: 2, controls: 0}
    claims = state.claims
    state = Frontier.seed(state, key, 0, :landing, true)
    assert state.claims == claims
    assert Frontier.outcome(state, active.id) == nil
    assert Frontier.outcome(state, pending.id) == nil
    assert Frontier.counts(state, key) == %{completed: 0, reserved: 1, controls: 0}
    assert Frontier.seed(state, key, 0, :landing, true) == state
    state = drain_maintenance(state, key)
    assert {:ok, pending_claim, %{id: id}, state} = Frontier.checkout(state, context.queue)
    assert id == pending.id
    {:ok, state} = Frontier.complete(state, source_claim, Outcome.new(:succeeded))
    {:ok, state} = Frontier.complete(state, active_claim, Outcome.new(:failed, :status_503))
    {:ok, state} = Frontier.complete(state, pending_claim, Outcome.new(:succeeded))
    assert Frontier.counts(state, key) == %{completed: 1, reserved: 0, controls: 0}
    assert Frontier.outcome(state, active.id) == Outcome.new(:failed, :status_503)
    assert Frontier.outcome(state, pending.id) == Outcome.new(:succeeded)
    assert active.representation_id != pending.representation_id
  end

  test "resetting completed counts wakes pending work and preserves active reservations",
       context do
    {kept, state} = admit(Frontier.new(), context, :kept, :anonymous, :module, max_pages: 2)
    {:ok, kept_claim, _, state} = Frontier.checkout(state, context.queue)
    {:ok, state} = Frontier.complete(state, kept_claim, Outcome.new(:succeeded))
    {:ok, state} = Frontier.release(state, kept_claim)
    {held, state} = admit(state, context, :held, :anonymous, :module, max_pages: 3)
    {:ok, held_claim, _, state} = Frontier.checkout(state, context.queue)
    {pending, state} = admit(state, context, :pending, :anonymous, :module, max_pages: 2)
    key = Frontier.run_key(kept)
    state = drain_maintenance(state, key)
    assert Frontier.checkout(state, context.queue) == :empty
    claims = state.claims
    state = Frontier.reset_completed(state, key)
    assert Frontier.counts(state, key) == %{completed: 0, reserved: 1, controls: 0}
    assert state.claims == claims
    assert Frontier.outcome(state, kept.id) == Outcome.new(:succeeded)
    assert Frontier.outcome(state, held.id) == nil
    state = drain_maintenance(state, key)
    assert {:ok, pending_claim, %{id: id}, state} = Frontier.checkout(state, context.queue)
    assert id == pending.id
    {:ok, state} = Frontier.complete(state, pending_claim, Outcome.new(:succeeded))
    {:ok, state} = Frontier.complete(state, held_claim, Outcome.new(:failed))
    assert Frontier.counts(state, key) == %{completed: 1, reserved: 0, controls: 0}
  end

  test "all failed variants release a single slot and wake an eligible sibling", context do
    {one, state} = admit(Frontier.new(), context, :same, :anonymous, :module, max_pages: 1)
    {_two, state} = admit(state, context, :same, :credentialed, :module, max_pages: 1)
    {other, state} = admit(state, context, :other, :anonymous, :module, max_pages: 1)
    {:ok, first, _, state} = Frontier.checkout(state, context.queue)
    {:ok, second, _, state} = Frontier.checkout(state, context.queue)
    assert Frontier.checkout(state, context.queue) == :empty
    {:ok, state} = Frontier.complete(state, first, Outcome.new(:failed))
    assert Frontier.counts(state, Frontier.run_key(one)).reserved == 1
    assert Frontier.checkout(state, context.queue) == :empty
    {:ok, state} = Frontier.complete(state, second, Outcome.new(:failed))
    assert Frontier.counts(state, Frontier.run_key(one)).reserved == 0
    assert {:ok, _, %{id: id}, _state} = Frontier.checkout(state, context.queue)
    assert id == other.id
  end

  test "counted logical variants bypass page ceilings but retain independent outcomes", context do
    {one, state} = admit(Frontier.new(), context, :same, :anonymous, :module, max_pages: 1)
    {:ok, claim, _, state} = Frontier.checkout(state, context.queue)
    {:ok, state} = Frontier.complete(state, claim, Outcome.new(:succeeded))
    {:ok, state} = Frontier.release(state, claim)
    {variant, state} = admit(state, context, :same, :credentialed, :script, max_pages: 0)
    assert {:ok, _, %{id: id}, state} = Frontier.checkout(state, context.queue)
    assert id == variant.id

    assert Frontier.counts(state, Frontier.run_key(one)) == %{
             completed: 1,
             reserved: 0,
             controls: 0
           }
  end

  test "a parked small ceiling cannot block another job with a larger ceiling", context do
    {_root, state} = admit(Frontier.new(), context, :root, :anonymous, :module, max_pages: 3)
    {:ok, _held, _, state} = Frontier.checkout(state, context.queue)
    {_small, state} = admit(state, context, :small, :anonymous, :module, max_pages: 1)
    {large, state} = admit(state, context, :large, :anonymous, :module, max_pages: 2)
    assert {:ok, _, %{id: id}, _state} = Frontier.checkout(state, context.queue)
    assert id == large.id
  end

  test "interpretation and control work do not reserve more page slots", context do
    {root, state} = admit(Frontier.new(), context, :root, :anonymous, :module, max_pages: 1)
    {:ok, _held, _, state} = Frontier.checkout(state, context.queue)
    {_interpret, state} = admit(state, context, :root, :anonymous, :script, kind: :interpret)
    {_sitemap, state} = admit(state, context, :map, :anonymous, :catalog, kind: :sitemap)
    {:ok, _interpret_claim, %{kind: :interpret}, state} = Frontier.checkout(state, context.queue)
    {:ok, _control_claim, %{kind: :sitemap}, state} = Frontier.checkout(state, context.queue)

    assert Frontier.counts(state, Frontier.run_key(root)) == %{
             completed: 0,
             reserved: 1,
             controls: 1
           }
  end

  test "eligible scopes rotate fairly while one scope has a large backlog", context do
    other_scope = make_ref()
    other = %{context | authority: {other_scope, {make_ref(), other_scope, make_ref()}, self()}}

    state =
      Enum.reduce(1..5, Frontier.new(), fn i, state ->
        {_job, state} = admit(state, context, {:first, i}, :anonymous, :module)
        {_job, state} = admit(state, other, {:second, i}, :anonymous, :module)
        state
      end)

    {scopes, _state} =
      Enum.map_reduce(1..10, state, fn _, state ->
        {:ok, claim, %{authority: {scope, _, _}}, state} = Frontier.checkout(state, context.queue)
        {:ok, state} = Frontier.complete(state, claim, Outcome.new(:succeeded))
        {:ok, state} = Frontier.release(state, claim)
        {scope, state}
      end)

    assert scopes ==
             List.duplicate([elem(context.authority, 0), other_scope], 5) |> List.flatten()
  end

  test "payload capacity survives completion until the executor releases it", context do
    {_one, state} = admit(Frontier.new(), context, :one, :anonymous, :module)
    cap = state.active_metadata_bytes + state.payload_bytes
    state = %{state | limits: %{state.limits | max_frontier_bytes: cap}}
    {:ok, claim, _, state} = Frontier.checkout(state, context.queue)
    {:ok, state} = Frontier.complete(state, claim, Outcome.new(:succeeded))
    candidate = job(context, :two, :anonymous)

    assert {:limited, :max_frontier_bytes, state} =
             Frontier.admit(state, candidate, identity(:two, :anonymous, :module), charge())

    assert Frontier.pending(state) == 0
    {:ok, state} = Frontier.release(state, claim)
    assert Frontier.bytes(state).metadata > 16
    assert Frontier.bytes(state).payload == 0

    assert {:accepted, _, _state} =
             Frontier.admit(state, candidate, identity(:two, :anonymous, :module), charge())
  end

  test "rejected fan-out only changes a finite aggregate counter", context do
    {_one, state} = admit(Frontier.new(max_pending: 1), context, :one, :anonymous, :module)
    before = {map_size(state.jobs), map_size(state.identities), map_size(state.runs)}

    state =
      Enum.reduce(1..500, state, fn i, state ->
        assert {:limited, :max_pending, state} =
                 Frontier.admit(
                   state,
                   job(context, i, :anonymous),
                   identity(i, :anonymous, :module),
                   charge()
                 )

        state
      end)

    assert {map_size(state.jobs), map_size(state.identities), map_size(state.runs)} == before
    assert state.limited == %{max_pending: 500}
  end

  test "permanently full work settles in bounded batches and another scope progresses", context do
    {root, state} = admit(Frontier.new(), context, :root, :anonymous, :module, max_pages: 1)
    {:ok, claim, _, state} = Frontier.checkout(state, context.queue)

    state =
      Enum.reduce(1..100, state, fn i, state ->
        {_job, state} = admit(state, context, i, :anonymous, :module, max_pages: 1)
        state
      end)

    {:ok, state} = Frontier.complete(state, claim, Outcome.new(:succeeded))
    assert {:more, settled, state} = Frontier.settle_batch(state, Frontier.run_key(root))
    assert length(settled) == 64
    assert Frontier.pending(state) == 36

    scope = make_ref()
    other = %{context | authority: {scope, {make_ref(), scope, make_ref()}, self()}}
    {other_job, state} = admit(state, other, :independent, :anonymous, :module)
    assert {:ok, _, %{id: id}, state} = Frontier.checkout(state, context.queue)
    assert id == other_job.id
    assert {:done, settled, _state} = Frontier.settle_batch(state, Frontier.run_key(root))
    assert length(settled) == 36
  end

  test "failure-heavy frontier work grows linearly in measured scheduler transitions", context do
    small = failures(100, context)
    large = failures(200, context)
    assert small.selected == 101
    assert large.selected == 201
    assert large.group_updates <= small.group_updates * 2 + 10
    assert small.settled == 0
    assert large.settled == 0
  end

  test "page-free controls have their own admission and depth limits", context do
    state = Frontier.new(max_control_documents: 2, max_control_depth: 3)
    {one, state} = admit(state, context, :one, :anonymous, :catalog, kind: :sitemap)
    {_two, state} = admit(state, context, :two, :anonymous, :catalog, kind: :sitemap)
    candidate = job(context, :three, :anonymous, kind: :sitemap)

    assert {:limited, :max_control_documents, _state} =
             Frontier.admit(state, candidate, identity(:three, :anonymous, :catalog), charge())

    assert Frontier.counts(state, Frontier.run_key(one)) == %{
             completed: 0,
             reserved: 0,
             controls: 2
           }

    candidate = job(context, :deep, :anonymous, kind: :sitemap, control_depth: 4)

    assert {:limited, :max_control_depth, _state} =
             Frontier.admit(
               Frontier.new(max_control_depth: 3),
               candidate,
               identity(:deep, :anonymous, :catalog),
               charge()
             )
  end

  test "retirement revokes jobs but retains payload until its executor releases", context do
    {job, state} = admit(Frontier.new(), context, :body, :anonymous, :module)
    key = Frontier.run_key(job)
    {:ok, claim, _, state} = Frontier.checkout(state, context.queue)
    assert {:retired, state} = Frontier.retire_run(state, key)
    assert Frontier.checkout(state, context.queue) == :empty
    assert {:done, [^claim], state} = Frontier.retire_claims_batch(state, key)
    assert {:waiting, 0, ^state} = Frontier.dispose_batch(state, key)
    assert Frontier.bytes(state).payload == 32
    {:ok, state} = Frontier.release(state, claim)
    assert {:done, 2, state} = Frontier.dispose_batch(state, key)
    assert state.runs == %{}
    assert state.representations == %{}
    assert state.identities == %{}
    assert state.queues == %{}

    assert Frontier.bytes(state) == %{
             metadata: 0,
             payload: 0
           }
  end

  test "queue retirement uses a bounded snapshot and preserves later queue reuse", context do
    {first, state} = admit(Frontier.new(), context, :first, :anonymous, :module)
    {_second, state} = admit(state, context, :second, :anonymous, :module)
    {:ok, claim, _, state} = Frontier.checkout(state, context.queue)
    {token, state} = Frontier.retire_queue(state, context.queue)
    {new, state} = admit(state, context, :new, :anonymous, :module)
    assert {:more, [^claim], [_], state} = Frontier.retire_queue_batch(state, token, 1)
    assert Frontier.outcome(state, first.id).status == :cancelled
    assert {:done, [], [_], state} = Frontier.retire_queue_batch(state, token, 1)
    assert state.retired_queue_jobs == %{}
    assert {:ok, _, %{id: id}, _} = Frontier.checkout(state, context.queue)
    assert id == new.id
  end

  test "pending retired controls settle and dispose through bounded batches", context do
    {first, state} = admit(Frontier.new(), context, :one, :anonymous, :catalog, kind: :sitemap)
    {_second, state} = admit(state, context, :two, :anonymous, :catalog, kind: :sitemap)
    key = Frontier.run_key(first)
    assert {:retired, state} = Frontier.retire_run(state, key)
    assert {:more, settled, state} = Frontier.settle_batch(state, key, 1)
    assert length(settled) == 1
    assert Frontier.pending(state) == 1
    assert {:done, settled, state} = Frontier.settle_batch(state, key, 1)
    assert length(settled) == 1
    assert Frontier.pending(state) == 0
    assert Frontier.outcome(state, first.id).status == :cancelled
    assert {:more, 1, state} = Frontier.dispose_batch(state, key, 1)
    assert {:more, 1, state} = Frontier.dispose_batch(state, key, 1)
    assert {:done, 1, state} = Frontier.dispose_batch(state, key, 1)
    assert state.jobs == %{}
    assert Frontier.bytes(state).metadata == 0
  end

  test "repeated completed run disposal does not retain identities, queues or byte charges",
       context do
    state =
      Enum.reduce(1..30, Frontier.new(max_representations: 1, max_interpretations: 1), fn _,
                                                                                          state ->
        scope = make_ref()
        fresh = %{context | authority: {scope, {make_ref(), scope, make_ref()}, self()}}
        {job, state} = admit(state, fresh, :same_url, :anonymous, :module)
        {:ok, claim, _, state} = Frontier.checkout(state, context.queue)
        {:ok, state} = Frontier.complete(state, claim, Outcome.new(:succeeded))
        {:ok, state} = Frontier.release(state, claim)
        {:retired, state} = Frontier.retire_run(state, Frontier.run_key(job))
        assert {:done, 2, state} = Frontier.dispose_batch(state, Frontier.run_key(job))
        state
      end)

    assert state.jobs == %{}
    assert state.runs == %{}
    assert state.representations == %{}
    assert state.representation_counts == %{}
    assert state.queue_runs == %{}
    assert state.queues == %{}

    assert Frontier.bytes(state) == %{
             metadata: 0,
             payload: 0
           }
  end

  for status <- [:failed, :limited, :rejected, :cancelled] do
    test "released #{status} outcome is reused across duplicate failure fanout", context do
      {first, state} = admit(Frontier.new(), context, :same, :anonymous, :module)
      {:ok, claim, _, state} = Frontier.checkout(state, context.queue)
      {:ok, state} = Frontier.complete(state, claim, Outcome.new(unquote(status)))
      {:ok, state} = Frontier.release(state, claim)
      original = state

      state =
        Enum.reduce(1..1_000, state, fn _, state ->
          candidate = job(context, :same, :anonymous)

          assert {:existing, interpretation, ^state} =
                   Frontier.admit(
                     state,
                     candidate,
                     identity(:same, :anonymous, :module),
                     charge()
                   )

          assert interpretation == first.id
          state
        end)

      assert state == original
      assert map_size(state.jobs) == 1
      assert Frontier.outcome(state, first.id).status == unquote(status)
      {:retired, state} = Frontier.retire_run(state, Frontier.run_key(first))
      assert {:done, 2, state} = Frontier.dispose_batch(state, Frontier.run_key(first))
      assert state.identities == %{}
      assert state.representation_counts == %{}
    end
  end

  test "many queues share logical claims through bounded reindex batches", context do
    queues = test_queues(150)

    state =
      Enum.reduce(Enum.with_index(queues), Frontier.new(), fn {queue, index}, state ->
        local = on_queue(context, queue)
        {_job, state} = admit(state, local, :same, {:variant, index}, :module, max_pages: 1)
        state
      end)

    [first | _] = queues
    before = state.stats.group_updates
    {:ok, claim, job, state} = Frontier.checkout(state, first)
    assert state.stats.group_updates - before == 1
    key = Frontier.run_key(job)
    assert Frontier.counts(state, key).reserved == 1
    assert {:more, 64, state} = Frontier.maintain_batch(state, key, 64)

    scope = make_ref()

    independent = %{
      context
      | authority: {scope, {make_ref(), scope, make_ref()}, first},
        queue: first
    }

    {other, state} = admit(state, independent, :independent, :anonymous, :module)
    assert {:ok, _, %{id: other_id}, state} = Frontier.checkout(state, first)
    assert other_id == other.id

    state = drain_maintenance(state, key)
    second = Enum.at(queues, 80)
    assert {:ok, second_claim, _, state} = Frontier.checkout(state, second)
    assert Frontier.counts(state, key).reserved == 1
    before = state.stats.group_updates
    {:ok, state} = Frontier.complete(state, claim, Outcome.new(:succeeded))
    assert state.stats.group_updates - before == 1
    {:ok, state} = Frontier.complete(state, second_claim, Outcome.new(:failed))
    state = drain_maintenance(state, key)
    assert Frontier.counts(state, key) == %{completed: 1, reserved: 0, controls: 0}
    assert {:ok, _, _, _} = Frontier.checkout(state, Enum.at(queues, 140))
  end

  test "run revocation is constant time across queues and claim cleanup is bounded", context do
    queues = test_queues(130)

    {jobs, state} =
      Enum.map_reduce(Enum.with_index(queues), Frontier.new(), fn {queue, index}, state ->
        admit(state, on_queue(context, queue), {:url, index}, :anonymous, :module)
      end)

    key = Frontier.run_key(hd(jobs))

    {claims, state} =
      Enum.map_reduce(queues, state, fn queue, state ->
        {:ok, claim, _, state} = Frontier.checkout(state, queue)
        {claim, state}
      end)

    [claim | _] = claims
    before = state.stats
    {:retired, state} = Frontier.retire_run(state, key)
    assert state.stats.group_updates == before.group_updates
    assert state.stats.retired == before.retired + 1
    assert {:stale, ^state} = Frontier.complete(state, claim, Outcome.new(:succeeded))
    assert {:more, cancelled, state} = Frontier.retire_claims_batch(state, key, 17)
    assert length(cancelled) == 17
    assert Frontier.pending(state) == 113
    assert {:more, 13, state} = Frontier.maintain_batch(state, key, 13)
    assert state.stats.group_updates - before.group_updates <= 30
    assert Frontier.checkout(state, List.last(queues), 1) == :empty
  end

  test "capacity changes during a partial readiness pass revisit earlier queues", context do
    queues = test_queues(6)

    {jobs, state} =
      Enum.map_reduce(Enum.with_index(queues), Frontier.new(), fn {queue, i}, state ->
        admit(state, on_queue(context, queue), {:url, i}, :anonymous, :module, max_pages: 1)
      end)

    key = Frontier.run_key(hd(jobs))
    [one, two, three | _] = queues
    {:ok, claim, _, state} = Frontier.checkout(state, one)
    state = drain_maintenance(state, key)
    {:ok, state} = Frontier.complete(state, claim, Outcome.new(:failed))
    {:more, 1, state} = Frontier.maintain_batch(state, key, 1)
    {:ok, claim, _, state} = Frontier.checkout(state, two)
    {:more, 1, state} = Frontier.maintain_batch(state, key, 1)
    assert Frontier.checkout(state, three) == :empty
    {:ok, state} = Frontier.complete(state, claim, Outcome.new(:failed))
    state = drain_maintenance(state, key)
    assert {:ok, _, _, _} = Frontier.checkout(state, three)
  end

  test "queue fanout work scales in bounded measured maintenance operations", context do
    small = queue_fanout(100, context)
    large = queue_fanout(200, context)
    assert large.group_updates <= small.group_updates * 2 + 10
    assert large.selected == 1
    assert small.selected == 1
  end

  test "metadata roots indices and cursors consume retained capacity", context do
    candidate = job(context, :metadata, :anonymous)

    assert {:limited, :max_retained_bytes, state} =
             Frontier.admit(
               Frontier.new(max_retained_bytes: 100),
               candidate,
               identity(:metadata, :anonymous, :module),
               %{metadata: 0, payload: 0}
             )

    assert state.runs == %{}
    assert state.jobs == %{}
    {job, state} = admit(Frontier.new(), context, :metadata, :anonymous, :module)
    assert state.jobs[job.id].charge.metadata > 8_192
    {:ok, claim, _, state} = Frontier.checkout(state, context.queue)
    metadata = Frontier.bytes(state).metadata
    {:ok, state} = Frontier.complete(state, claim, Outcome.new(:failed))
    {:ok, state} = Frontier.release(state, claim)
    assert Frontier.bytes(state).metadata == metadata
    assert Frontier.bytes(state).payload == 0
  end

  describe "claim_target/2" do
    test "claims only the canonical target and preserves unrelated checkout order", context do
      {first, state} = admit(Frontier.new(), context, :same, :anonymous, :module)
      {target, state} = admit(state, context, :same, :credentialed, :module)
      {last, state} = admit(state, context, :last, :anonymous, :module)
      before = state
      key = Frontier.run_key(target)

      assert {:ok, claim, ^target, state} = Frontier.claim_target(state, target.id)
      assert state.jobs[first.id] == before.jobs[first.id]
      assert state.jobs[last.id] == before.jobs[last.id]

      assert state.runs[key].pending_order.members ==
               Map.delete(before.runs[key].pending_order.members, target.id)

      assert state.runs[key].dirs[context.queue].groups[:same].entries ==
               Map.delete(before.runs[key].dirs[context.queue].groups[:same].entries, target.id)

      assert state.queue_jobs == before.queue_jobs
      assert Frontier.pending(state) == Frontier.pending(before)
      assert state.stats.selected == before.stats.selected + 1
      assert {:waiting, ^state} = Frontier.claim_target(state, target.id)
      assert {:ok, _, %{id: first_id}, state} = Frontier.checkout(state, context.queue)
      assert first_id == first.id
      assert {:ok, _, %{id: last_id}, _} = Frontier.checkout(state, context.queue)
      assert last_id == last.id
      assert state.claims[claim].id == target.id
    end

    test "accepts admission handles and does not resolve URLs or interpretation IDs", context do
      {target, state} = admit(Frontier.new(), context, :same, :anonymous, :module)
      duplicate = job(context, :same, :anonymous)

      assert {:existing, id, ^state} =
               Frontier.admit(state, duplicate, identity(:same, :anonymous, :module), charge())

      assert id == target.id

      for stale <- [duplicate.id, target.interpretation_id, target.representation_id, :same, nil] do
        assert {:error, :stale, ^state} = Frontier.claim_target(state, stale)
      end

      assert {:ok, _, ^target, _} = Frontier.claim_target(state, id)
    end

    for first <- [:succeeded, :failed] do
      test "shares one logical reservation when the first variant #{first}", context do
        {one, state} = admit(Frontier.new(), context, :same, :anonymous, :module, max_pages: 1)
        {two, state} = admit(state, context, :same, :credentialed, :script, max_pages: 1)
        {other, state} = admit(state, context, :other, :anonymous, :module, max_pages: 1)
        key = Frontier.run_key(one)
        assert {:ok, first_claim, ^one, state} = Frontier.claim_target(state, one.id)
        assert {:ok, second_claim, ^two, state} = Frontier.claim_target(state, two.id)
        assert Frontier.counts(state, key).reserved == 1
        assert {:waiting, ^state} = Frontier.claim_target(state, other.id)
        {:ok, state} = Frontier.complete(state, first_claim, Outcome.new(unquote(first)))
        assert {:waiting, ^state} = Frontier.claim_target(state, two.id)
        second = if unquote(first) == :succeeded, do: :failed, else: :succeeded
        {:ok, state} = Frontier.complete(state, second_claim, Outcome.new(second))
        assert Frontier.counts(state, key) == %{completed: 1, reserved: 0, controls: 0}
        assert {:maintenance, ^state} = Frontier.claim_target(state, other.id)
      end
    end

    test "temporary page blocking does not select another job and clears after release",
         context do
      {held, state} = admit(Frontier.new(), context, :held, :anonymous, :module, max_pages: 1)
      {blocked, state} = admit(state, context, :blocked, :anonymous, :module, max_pages: 1)
      {eligible, state} = admit(state, context, :eligible, :anonymous, :module, max_pages: 2)
      {:ok, claim, ^held, state} = Frontier.claim_target(state, held.id)
      assert {:waiting, ^state} = Frontier.claim_target(state, blocked.id)
      assert state.jobs[eligible.id].status == :pending
      {:ok, state} = Frontier.release(state, claim)
      assert Frontier.outcome(state, held.id) == Outcome.new(:cancelled, :executor_down)
      assert Frontier.counts(state, Frontier.run_key(held)).reserved == 0
      assert {:ok, _, ^blocked, _} = Frontier.claim_target(state, blocked.id)
    end

    test "uses the target ceiling when its logical group has a larger eligible ceiling",
         context do
      {held, state} = admit(Frontier.new(), context, :held, :anonymous, :module, max_pages: 1)
      {:ok, _, ^held, state} = Frontier.claim_target(state, held.id)
      {small, state} = admit(state, context, :same, :small, :module, max_pages: 1)
      {large, state} = admit(state, context, :same, :large, :module, max_pages: 2)
      assert {:waiting, ^state} = Frontier.claim_target(state, small.id)
      assert state.jobs[large.id].status == :pending
      assert {:ok, _, ^large, state} = Frontier.claim_target(state, large.id)
      assert {:waiting, ^state} = Frontier.claim_target(state, small.id)
    end

    test "permanent page blocking requests existing bounded settlement", context do
      {held, state} = admit(Frontier.new(), context, :held, :anonymous, :module, max_pages: 1)
      {blocked, state} = admit(state, context, :blocked, :anonymous, :module, max_pages: 1)
      {:ok, claim, ^held, state} = Frontier.claim_target(state, held.id)
      {:ok, state} = Frontier.complete(state, claim, Outcome.new(:succeeded))
      assert {:maintenance, ^state} = Frontier.claim_target(state, blocked.id)
      assert Frontier.outcome(state, blocked.id) == nil
      assert {:done, settled, state} = Frontier.settle_batch(state, Frontier.run_key(held), 1)
      assert length(settled) == 1
      outcome = Frontier.outcome(state, blocked.id)
      assert outcome == Outcome.limited(:max_pages)
      assert {:terminal, ^outcome, ^state} = Frontier.claim_target(state, blocked.id)
    end

    test "counted variants use checkout eligibility even with a zero page ceiling", context do
      {first, state} = admit(Frontier.new(), context, :same, :anonymous, :module, max_pages: 1)
      {:ok, claim, ^first, state} = Frontier.claim_target(state, first.id)
      {:ok, state} = Frontier.complete(state, claim, Outcome.new(:succeeded))
      {variant, state} = admit(state, context, :same, :credentialed, :script, max_pages: 0)
      assert {:ok, _, ^variant, state} = Frontier.claim_target(state, variant.id)

      assert Frontier.counts(state, Frontier.run_key(first)) ==
               %{completed: 1, reserved: 0, controls: 0}
    end

    test "repairs only the target queue group in one maintenance transition", context do
      [one_queue, two_queue, three_queue] = test_queues(3)

      {one, state} =
        admit(Frontier.new(), on_queue(context, one_queue), :same, :one, :module, max_pages: 1)

      {two, state} =
        admit(state, on_queue(context, two_queue), :same, :two, :module, max_pages: 1)

      {three, state} =
        admit(state, on_queue(context, three_queue), :same, :three, :module, max_pages: 1)

      {:ok, claim, ^one, state} = Frontier.claim_target(state, one.id)
      before = state
      key = Frontier.run_key(one)
      assert {:maintenance, state} = Frontier.claim_target(state, two.id)
      assert state.stats.group_updates == before.stats.group_updates + 1
      assert state.stats.selected == before.stats.selected
      assert state.jobs == before.jobs
      assert state.runs[key].dirs[one_queue] == before.runs[key].dirs[one_queue]
      assert state.runs[key].dirs[three_queue] == before.runs[key].dirs[three_queue]
      assert {:ok, _, ^two, state} = Frontier.claim_target(state, two.id)
      assert Frontier.counts(state, key).reserved == 1
      {:ok, state} = Frontier.complete(state, claim, Outcome.new(:succeeded))
      assert {:maintenance, state} = Frontier.claim_target(state, three.id)
      assert {:ok, _, ^three, state} = Frontier.claim_target(state, three.id)
      assert Frontier.counts(state, key) == %{completed: 1, reserved: 0, controls: 0}
    end

    test "does not select work from other queues or runs, including nil queue work", context do
      other_scope = make_ref()

      other = %{
        context
        | authority: {other_scope, {make_ref(), other_scope, make_ref()}, nil},
          queue: nil
      }

      {unrelated, state} = admit(Frontier.new(), other, :unrelated, :anonymous, :module)
      {queued, state} = admit(state, context, :queued, :anonymous, :module)
      {target, state} = admit(state, on_queue(context, nil), :target, :anonymous, :module)
      before = state
      assert {:ok, _, ^target, state} = Frontier.claim_target(state, target.id)
      assert state.runs[Frontier.run_key(unrelated)] == before.runs[Frontier.run_key(unrelated)]
      assert state.jobs[unrelated.id] == before.jobs[unrelated.id]
      assert state.jobs[queued.id] == before.jobs[queued.id]
      assert Frontier.checkout(state, nil) == Frontier.checkout(before, nil)
      assert {:ok, _, ^unrelated, _} = Frontier.claim_target(state, unrelated.id)
      assert {:ok, _, ^queued, _} = Frontier.checkout(state, context.queue)
    end

    for kind <- [:interpret, :robots, :sitemap, :css_settlement, :alias_settlement, :finalize] do
      test "#{kind} targets retain page-free eligibility", context do
        {page, state} = admit(Frontier.new(), context, :page, :anonymous, :module, max_pages: 1)
        {:ok, _, ^page, state} = Frontier.claim_target(state, page.id)

        {target, state} =
          admit(state, context, :target, :anonymous, :module, kind: unquote(kind), max_pages: 0)

        assert {:ok, _, ^target, state} = Frontier.claim_target(state, target.id)
        assert Frontier.counts(state, Frontier.run_key(page)).reserved == 1
      end
    end

    test "fetch targets with count_page false do not reserve a page slot", context do
      target = job(context, :asset, :anonymous)
      target = %{target | opts: %{max_pages: 0, count_page: false}}

      {:accepted, target, state} =
        Frontier.admit(Frontier.new(), target, identity(:asset, :anonymous, :module), charge())

      assert {:ok, _, ^target, state} = Frontier.claim_target(state, target.id)
      assert Frontier.counts(state, Frontier.run_key(target)).reserved == 0
    end

    for dependency <- [:cookie_proof, :representation] do
      test "does not bypass #{dependency} waits or claim unrelated ready work", context do
        {target, state} = admit(Frontier.new(), context, :target, :anonymous, :module)
        {ready, state} = admit(state, context, :ready, :anonymous, :module)
        dependency = {unquote(dependency), target.representation_id}
        {:ok, state} = Frontier.wait(state, target.id, dependency)
        assert {:waiting, ^state} = Frontier.claim_target(state, target.id)
        assert state.jobs[ready.id].status == :pending
        {:ok, state} = Frontier.resume(state, target.id)
        assert {:ok, _, ^target, _} = Frontier.claim_target(state, target.id)
      end
    end

    test "a parked claim retains its admission handle through private rebinding", context do
      {target, state} = admit(Frontier.new(), context, :target, :anonymous, :module, max_pages: 1)
      {:ok, claim, ^target, state} = Frontier.claim_target(state, target.id)
      {:ok, state} = Frontier.park_claim(state, claim, :cookie_proof)
      assert {:waiting, ^state} = Frontier.claim_target(state, target.id)
      assert Frontier.counts(state, Frontier.run_key(target)).reserved == 0

      assert {:ok, rebound, state} =
               Frontier.rebind(
                 state,
                 target.id,
                 identity(:target, :private, :module),
                 target.opts
               )

      assert rebound.id == target.id
      assert rebound.representation_id != target.representation_id
      assert {:waiting, ^state} = Frontier.claim_target(state, target.id)
      {:ok, state} = Frontier.resume(state, target.id)
      assert {:ok, new_claim, ^rebound, state} = Frontier.claim_target(state, target.id)
      assert new_claim != claim
      assert {:stale, ^state} = Frontier.release(state, claim)
    end

    test "claim release frees payload exactly once", context do
      {target, state} = admit(Frontier.new(), context, :target, :anonymous, :module)
      {:ok, claim, ^target, state} = Frontier.claim_target(state, target.id)
      {:ok, state} = Frontier.complete(state, claim, Outcome.new(:failed))
      assert Frontier.bytes(state).payload == 32
      {:ok, state} = Frontier.release(state, claim)
      assert Frontier.bytes(state).payload == 0
      assert Frontier.counts(state, Frontier.run_key(target)).reserved == 0
      assert {:stale, ^state} = Frontier.release(state, claim)
    end

    for status <- [:succeeded, :failed, :limited, :rejected, :cancelled] do
      test "replays the canonical #{status} outcome before and after claim release", context do
        {target, state} = admit(Frontier.new(), context, :target, :anonymous, :module)
        {:ok, claim, ^target, state} = Frontier.claim_target(state, target.id)

        outcome = %{
          Outcome.new(unquote(status), :original)
          | representation_id: target.representation_id,
            interpretation_id: target.interpretation_id
        }

        {:ok, state} = Frontier.complete(state, claim, outcome)
        assert {:terminal, ^outcome, ^state} = Frontier.claim_target(state, target.id)
        {:ok, state} = Frontier.release(state, claim)
        assert {:terminal, ^outcome, ^state} = Frontier.claim_target(state, target.id)
        assert Frontier.bytes(state).payload == 0
        assert {:stale, ^state} = Frontier.release(state, claim)
      end
    end

    test "retired targets are stale in every state and remain stale after disposal", context do
      {pending, state} = admit(Frontier.new(), context, :pending, :anonymous, :module)
      {running, state} = admit(state, context, :running, :anonymous, :module)
      {terminal, state} = admit(state, context, :terminal, :anonymous, :module)
      {:ok, _, ^running, state} = Frontier.claim_target(state, running.id)
      {:ok, claim, ^terminal, state} = Frontier.claim_target(state, terminal.id)
      {:ok, state} = Frontier.complete(state, claim, Outcome.new(:succeeded))
      {:ok, state} = Frontier.release(state, claim)
      key = Frontier.run_key(pending)
      {:retired, state} = Frontier.retire_run(state, key)

      for target <- [pending, running, terminal] do
        assert {:error, :stale, ^state} = Frontier.claim_target(state, target.id)
      end

      {:done, claims, state} = Frontier.retire_claims_batch(state, key)

      state =
        Enum.reduce(claims, state, fn claim, state ->
          {:ok, state} = Frontier.release(state, claim)
          state
        end)

      {:done, settled, state} = Frontier.settle_batch(state, key)
      assert length(settled) == 1
      {:done, _, state} = Frontier.dispose_batch(state, key)

      for target <- [pending, running, terminal] do
        assert {:error, :stale, ^state} = Frontier.claim_target(state, target.id)
      end
    end
  end

  test "caller representation ceilings are scoped and allow existing-context reuse", context do
    {first, state} =
      admit(Frontier.new(), context, :same, :anonymous, :module, max_representations: 1)

    {_other_context, state} =
      admit(state, context, :same, :anonymous, :script, max_representations: 1)

    second = job(context, :other, :credentialed)
    second = %{second | opts: %{max_representations: 1}}

    assert {:limited, :max_representations, limited} =
             Frontier.admit(state, second, identity(:other, :credentialed, :module), charge())

    assert limited.jobs == state.jobs
    assert limited.representations == state.representations
    assert limited.runs == state.runs

    scope = make_ref()
    other = %{context | authority: {scope, {make_ref(), scope, make_ref()}, context.queue}}

    {accepted, state} =
      admit(state, other, :other, :credentialed, :module, max_representations: 1)

    assert state.runs[Frontier.run_key(first)].representation_count == 1
    assert state.runs[Frontier.run_key(accepted)].representation_count == 1
  end

  test "rebinding enforces the caller's run ceiling before allocating a new identity", context do
    {one, state} = admit(Frontier.new(), context, :same, :anonymous, :module)
    {two, state} = admit(state, context, :same, :anonymous, :script)
    {:ok, state} = Frontier.wait(state, two.id, :private)

    assert {:limited, :max_representations, ^state} =
             Frontier.rebind(state, two.id, identity(:same, :private, :script), %{
               max_representations: 1
             })

    assert state.runs[Frontier.run_key(one)].representation_count == 1
  end

  test "rebinding rejects a new representation while the old identity still has another target",
       context do
    {one, state} =
      admit(Frontier.new(max_representations: 1), context, :same, :anonymous, :module)

    {two, state} = admit(state, context, :same, :anonymous, :script)
    {:ok, state} = Frontier.wait(state, two.id, :private)

    assert {:limited, :max_representations, ^state} =
             Frontier.rebind(state, two.id, identity(:same, :private, :script), two.opts)

    assert map_size(state.representations) == 1
    assert state.jobs[one.id].job.representation_id == two.representation_id
  end

  test "rebinding can replace the final old reference at the exact representation ceiling",
       context do
    {target, state} =
      admit(Frontier.new(max_representations: 1), context, :same, :anonymous, :module)

    {:ok, state} = Frontier.wait(state, target.id, :private)

    assert {:ok, rebound, state} =
             Frontier.rebind(state, target.id, identity(:same, :private, :module), target.opts)

    assert rebound.id == target.id
    assert rebound.representation_id != target.representation_id
    assert map_size(state.representations) == 1
    assert map_size(state.representation_counts) == 1
  end

  test "rebinding to an existing identity needs no new representation slot", context do
    {one, state} =
      admit(Frontier.new(max_representations: 2), context, :same, :anonymous, :module)

    {two, state} = admit(state, context, :same, :credentialed, :script)
    {:ok, state} = Frontier.wait(state, two.id, :private)

    assert {:ok, rebound, state} =
             Frontier.rebind(state, two.id, identity(:same, :anonymous, :script), two.opts)

    assert rebound.representation_id == one.representation_id
    assert map_size(state.representations) == 1
    assert Map.values(state.representation_counts) == [2]
  end

  test "same-identity rebinding preserves its representation handle at the ceiling", context do
    {target, state} =
      admit(Frontier.new(max_representations: 1), context, :same, :anonymous, :module)

    {:ok, state} = Frontier.wait(state, target.id, :private)

    assert {:ok, rebound, state} =
             Frontier.rebind(state, target.id, identity(:same, :anonymous, :module), target.opts)

    assert rebound.representation_id == target.representation_id
    assert Map.values(state.representation_counts) == [1]
  end

  defp queue_fanout(count, context) do
    queues = test_queues(count)

    {jobs, state} =
      Enum.map_reduce(Enum.with_index(queues), Frontier.new(), fn {queue, i}, state ->
        admit(state, on_queue(context, queue), :same, {:variant, i}, :module, max_pages: 1)
      end)

    key = Frontier.run_key(hd(jobs))
    {:ok, claim, _, state} = Frontier.checkout(state, hd(queues))
    state = drain_maintenance(state, key)
    {:ok, state} = Frontier.complete(state, claim, Outcome.new(:succeeded))
    drain_maintenance(state, key).stats
  end

  defp drain_maintenance(state, key) do
    case Frontier.maintain_batch(state, key, 31) do
      {:done, _, state} -> state
      {:more, 31, state} -> drain_maintenance(state, key)
    end
  end

  defp test_queues(count) do
    queues =
      for _ <- 1..count,
          do:
            spawn(fn ->
              receive do
                :stop -> :ok
              end
            end)

    on_exit(fn -> Enum.each(queues, &send(&1, :stop)) end)
    queues
  end

  defp on_queue(context, queue) do
    {scope, generation, _} = context.authority
    %{context | authority: {scope, generation, queue}, queue: queue}
  end

  defp failures(n, context) do
    {_root, state} = admit(Frontier.new(), context, :root, :anonymous, :module, max_pages: 2)
    {:ok, claim, _, state} = Frontier.checkout(state, context.queue)
    {:ok, state} = Frontier.complete(state, claim, Outcome.new(:succeeded))
    {:ok, state} = Frontier.release(state, claim)

    state =
      Enum.reduce(1..n, state, fn i, state ->
        {_job, state} = admit(state, context, i, :anonymous, :module, max_pages: 2)
        state
      end)

    state =
      Enum.reduce(1..n, state, fn _, state ->
        {:ok, claim, _, state} = Frontier.checkout(state, context.queue)
        {:ok, state} = Frontier.complete(state, claim, Outcome.new(:failed))
        {:ok, state} = Frontier.release(state, claim)
        state
      end)

    assert Frontier.pending(state) == 0
    state.stats
  end

  test "executor release before the retirement drain preserves the exact run terminal outcome",
       context do
    for outcome <- [
          Outcome.new(:cancelled, :run_retired),
          Outcome.new(:limited, {:deadline, :run})
        ] do
      {job, state} = admit(Frontier.new(), context, :held, :anonymous, :module)
      {:ok, claim, _, state} = Frontier.checkout(state, context.queue)
      {:retired, state} = Frontier.retire_run(state, Frontier.run_key(job), outcome)
      {:ok, state} = Frontier.release(state, claim)
      assert Frontier.outcome(state, job.id) == outcome
      assert Frontier.pending(state) == 0
      assert Frontier.inflight(state, Frontier.run_key(job)) == 0
      assert Frontier.bytes(state).payload == 0
      assert state.claims == %{}
      assert {:done, [], ^state} = Frontier.retire_claims_batch(state, Frontier.run_key(job), 1)
    end
  end

  defp admit(state, context, url, representation, interpretation, extra \\ []) do
    job = job(context, url, representation, extra)

    assert {:accepted, job, state} =
             Frontier.admit(state, job, identity(url, representation, interpretation), charge())

    {job, state}
  end

  defp job(context, url, _representation, extra \\ []) do
    Job.new(Keyword.get(extra, :kind, :fetch), context.authority, %{
      logical_key: url,
      control_depth: Keyword.get(extra, :control_depth, 0),
      opts: %{max_pages: Keyword.get(extra, :max_pages, :infinity)}
    })
  end

  defp identity(url, representation, interpretation),
    do: %Identity{representation: {url, representation}, interpretation: interpretation}

  defp charge, do: %{metadata: 16, payload: 32}
end
