defmodule Crawler.Phase2.SchedulerTest do
  use ExUnit.Case, async: true

  alias Crawler.Fetcher.Requester.PreparedRequest
  alias Crawler.Frontier
  alias Crawler.Frontier.Ring
  alias Crawler.Job.Outcome
  alias Crawler.Store.Scheduler

  test "replacing the final pending intent does not retain obsolete representation records" do
    {opts, prepared} = request()
    state = Scheduler.new()
    state = %{state | frontier: Frontier.new(max_representations: 1)}
    {:accepted, target, state} = Scheduler.admit(state, opts, prepared)

    state =
      Enum.reduce(1..100, state, fn _, state ->
        {:ok, claim, :fetch, job, state} = checkout(state, opts.queue)
        assert job.id == target
        state = Scheduler.park(state, claim)
        {:ok, ^target, state} = Scheduler.take_fork(state)
        state = Scheduler.reattempt(state, target, make_ref())
        assert map_size(state.representations) == 1
        assert map_size(state.frontier.representations) == 1
        assert Ring.size(state.run_representations[{opts.scope, opts.generation}]) == 1
        state
      end)

    assert map_size(state.frontier.jobs) == 1
  end

  test "terminal response replay is claimed for proof validation without settling a waiter" do
    {opts, prepared} = request()
    {:accepted, first, state} = Scheduler.admit(Scheduler.new(), opts, prepared)

    {:accepted, second, state} =
      Scheduler.admit(state, %{opts | javascript_goal: :module}, prepared)

    {:ok, claim, :fetch, _, state} = checkout(state, opts.queue)
    reuse = %{disposition: :candidate, dependency: {:redirect_jar, opts.cookie_proof}}
    state = Scheduler.note_response(state, claim, reuse)
    outcome = Outcome.new(:failed, :unauthorized)
    state = Scheduler.note_request_result(state, claim, outcome)
    {:ok, state} = Scheduler.complete(state, claim, outcome)
    state = state |> Scheduler.release(claim) |> drain()
    assert Frontier.outcome(state.frontier, first) == outcome
    assert Frontier.outcome(state.frontier, second) == nil
    assert {:ok, _claim, :terminal, job, state} = checkout(state, opts.queue)
    assert job.id == second
    assert {:ok, ^outcome, ^reuse} = Scheduler.terminal(state, job.representation_id)
  end

  test "unknown failed attempts fork pending and late contexts but keep their own outcome" do
    {opts, prepared} = request()
    {:accepted, first, state} = Scheduler.admit(Scheduler.new(), opts, prepared)

    {:accepted, pending, state} =
      Scheduler.admit(state, %{opts | javascript_goal: :module}, prepared)

    {:ok, claim, :fetch, _, state} = checkout(state, opts.queue)
    outcome = Outcome.new(:failed, :unauthorized)
    state = Scheduler.note_response(state, claim, nil)
    {:ok, state} = Scheduler.complete(state, claim, outcome)
    state = state |> Scheduler.release(claim) |> drain()
    assert Frontier.outcome(state.frontier, first) == outcome
    assert Frontier.outcome(state.frontier, pending) == nil
    assert {:ok, ^pending, state} = Scheduler.take_fork(state)
    {:accepted, late, state} = Scheduler.admit(state, Map.put(opts, :html_tag, "img"), prepared)
    state = drain(state)
    assert {:ok, ^late, state} = Scheduler.take_fork(state)
    assert map_size(state.frontier.jobs) == 3
    assert {:existing, ^first, _} = Scheduler.admit(state, opts, prepared)
  end

  test "a new idle root retries a failed target without changing its retained outcome" do
    {opts, prepared} = request()
    {:accepted, failed, state} = Scheduler.admit(Scheduler.new(), opts, prepared)
    {:ok, claim, :fetch, _, state} = checkout(state, opts.queue)
    outcome = Outcome.new(:failed, :callback)
    state = Scheduler.note_response(state, claim, nil)

    {:accepted, other, state} =
      Scheduler.admit(
        state,
        %{opts | url: "https://scheduler.test/other"},
        %{prepared | equivalence: :other}
      )

    {:ok, state} = Scheduler.complete(state, claim, outcome)
    assert {:existing, ^failed, _} = Scheduler.admit(state, opts, prepared, :fetch, :root)
    {:ok, other_claim, :fetch, %{id: ^other}, state} = checkout(state, opts.queue)
    {:ok, state} = Scheduler.complete(state, other_claim, Outcome.new(:succeeded))
    assert {:existing, ^failed, _} = Scheduler.admit(state, opts, prepared, :fetch, :root)
    state = state |> Scheduler.release(claim) |> Scheduler.release(other_claim) |> drain()
    assert {:existing, ^failed, _} = Scheduler.admit(state, opts, prepared, :fetch, :root)
    state = acknowledge_notifications(state)
    before = state.frontier.jobs[failed]
    {:accepted, retry, state} = Scheduler.admit(state, opts, prepared, :fetch, :root)
    assert retry != failed
    assert state.frontier.jobs[failed] == before
    state = drain(state)
    {:ok, ^retry, state} = Scheduler.take_fork(state)
    state = Scheduler.reattempt(state, retry, opts.cookie_proof) |> drain()
    assert {:ok, _, :fetch, %{id: ^retry}, state} = checkout(state, opts.queue)
    assert Frontier.outcome(state.frontier, failed) == outcome
  end

  test "idle retry keeps failed target accounting within the interpretation limit" do
    {opts, prepared} = request()
    state = %{Scheduler.new() | frontier: Frontier.new(max_interpretations: 1)}
    {:accepted, target, state} = Scheduler.admit(state, opts, prepared)
    {:ok, claim, :fetch, _, state} = checkout(state, opts.queue)
    state = Scheduler.note_response(state, claim, nil)
    outcome = Outcome.new(:failed, :callback)
    {:ok, state} = Scheduler.complete(state, claim, outcome)
    state = state |> Scheduler.release(claim) |> drain() |> acknowledge_notifications()

    assert {:limited, :max_interpretations, state} =
             Scheduler.admit(state, opts, prepared, :fetch, :root)

    assert map_size(state.frontier.jobs) == 1
    assert Frontier.outcome(state.frontier, target) == outcome
  end

  test "same-crawl admission preserves reusable terminal responses after idle" do
    for outcome <- [Outcome.new(:succeeded), Outcome.new(:failed, :status_503)] do
      {opts, prepared} = request()
      {:accepted, target, state} = Scheduler.admit(Scheduler.new(), opts, prepared)
      {:ok, claim, :fetch, _, state} = checkout(state, opts.queue)

      state =
        Scheduler.note_response(state, claim, %{disposition: :candidate, dependency: :initial})

      state = Scheduler.note_request_result(state, claim, outcome)
      {:ok, state} = Scheduler.complete(state, claim, outcome)
      state = state |> Scheduler.release(claim) |> drain() |> acknowledge_notifications()
      assert {:existing, ^target, _} = Scheduler.admit(state, opts, prepared)

      if outcome.status == :succeeded,
        do:
          assert({:existing, ^target, _} = Scheduler.admit(state, opts, prepared, :fetch, :root))
    end
  end

  test "a new idle root forks a rejected HTTP response into a fresh attempt" do
    {opts, prepared} = request()
    {:accepted, target, state} = Scheduler.admit(Scheduler.new(), opts, prepared)
    {:ok, claim, :fetch, _, state} = checkout(state, opts.queue)
    outcome = Outcome.new(:rejected, :status_404)

    state =
      Scheduler.note_response(state, claim, %{disposition: :candidate, dependency: :initial})

    state = Scheduler.note_request_result(state, claim, outcome)
    {:ok, state} = Scheduler.complete(state, claim, outcome)
    state = state |> Scheduler.release(claim) |> drain() |> acknowledge_notifications()
    {:accepted, retry, state} = Scheduler.admit(state, opts, prepared, :fetch, :root)
    state = drain(state)
    {:ok, ^retry, state} = Scheduler.take_fork(state)
    state = Scheduler.reattempt(state, retry, opts.cookie_proof) |> drain()
    assert {:ok, _, :fetch, %{id: ^retry}, state} = checkout(state, opts.queue)
    assert retry != target
    assert Frontier.outcome(state.frontier, target) == outcome
  end

  test "a new idle root retries a failed representation after its interpretation changes" do
    {opts, prepared} = request()
    {:accepted, target, state} = Scheduler.admit(Scheduler.new(), opts, prepared)
    {:ok, claim, :fetch, _, state} = checkout(state, opts.queue)
    outcome = Outcome.new(:failed, :status_503)

    state =
      Scheduler.note_response(state, claim, %{disposition: :candidate, dependency: :initial})

    state = Scheduler.note_request_result(state, claim, outcome)
    {:ok, state} = Scheduler.complete(state, claim, outcome)
    state = state |> Scheduler.release(claim) |> drain() |> acknowledge_notifications()
    changed = Map.put(opts, :store, Crawler.Store)
    {:accepted, shared, sharing} = Scheduler.admit(state, changed, prepared)
    assert {:ok, _, :terminal, %{id: ^shared}, _} = checkout(drain(sharing), opts.queue)
    old = state.frontier.jobs[target]
    {:accepted, retry, state} = Scheduler.admit(state, changed, prepared, :fetch, :root)
    assert state.frontier.jobs[target] == old
    assert state.frontier.identities[old.identity_key] == target
    state = drain(state)
    {:ok, ^retry, state} = Scheduler.take_fork(state)
    state = Scheduler.reattempt(state, retry, opts.cookie_proof) |> drain()
    assert {:ok, _, :fetch, %{id: ^retry}, state} = checkout(state, opts.queue)
    assert Frontier.outcome(state.frontier, target) == outcome
    assert state.frontier.representation_count == 2
  end

  test "a new idle root reinterprets a retained response after its earlier interpreter failed" do
    {opts, prepared} = request()
    opts = %{opts | scraper: __MODULE__}
    {:accepted, target, state} = Scheduler.admit(Scheduler.new(), opts, prepared)
    {:ok, claim, :fetch, job, state} = checkout(state, opts.queue)

    source = %{
      reuse: %{disposition: :candidate, dependency: :initial},
      receipt: make_ref(),
      value: :physical_response
    }

    {:ok, state} = Scheduler.publish(state, claim, source)
    outcome = Outcome.new(:failed, :interpreter_down)
    {:ok, state} = Scheduler.complete(state, claim, outcome)
    state = state |> Scheduler.release(claim) |> drain() |> acknowledge_notifications()
    changed = Map.put(opts, :scraper, Crawler.Scraper)
    {:accepted, retry, state} = Scheduler.admit(state, changed, prepared, :fetch, :root)

    assert {:ok, _, :interpret, %{id: ^retry, representation_id: representation}, state} =
             checkout(state, opts.queue)

    assert representation == job.representation_id
    assert Scheduler.response(state, representation) == {:ok, source}
    assert Frontier.outcome(state.frontier, target) == outcome
    assert state.frontier.representation_count == 1
  end

  test "a late interpretation of a private response receives a new bounded attempt" do
    {opts, prepared} = request()
    {:accepted, first, state} = Scheduler.admit(Scheduler.new(), opts, prepared)
    {:ok, claim, :fetch, _, state} = checkout(state, opts.queue)
    state = private_response(state, claim)
    {:ok, state} = Scheduler.complete(state, claim, Outcome.new(:succeeded))
    state = state |> Scheduler.release(claim) |> drain()
    assert Ring.size(state.outcomes) == 0

    {:accepted, target, state} =
      Scheduler.admit(state, Map.put(opts, :javascript_goal, :module), prepared)

    assert first != target
    assert Ring.size(state.outcomes) == 1
    state = drain(state)
    assert {:ok, ^target, state} = Scheduler.take_fork(state)
    state = Scheduler.reattempt(state, target, opts.cookie_proof) |> drain()
    assert {:ok, claim, :fetch, job, state} = checkout(state, opts.queue)
    assert job.id == target
    {:ok, state} = Scheduler.complete(state, claim, Outcome.new(:succeeded))
    state = state |> Scheduler.release(claim) |> drain()
    assert Frontier.counts(state.frontier, {opts.scope, opts.generation}).completed == 1
    assert map_size(state.frontier.jobs) == 2
    assert Ring.size(state.forks) == 0
  end

  test "a reattempt that joins another private response wakes after its publication was drained" do
    {opts, prepared} = request()
    {:accepted, _, state} = Scheduler.admit(Scheduler.new(), opts, prepared)
    {:ok, claim, :fetch, _, state} = checkout(state, opts.queue)
    state = private_response(state, claim)
    {:ok, state} = Scheduler.complete(state, claim, Outcome.new(:succeeded))
    state = state |> Scheduler.release(claim) |> drain()

    other_opts = %{opts | cookie_proof: make_ref(), javascript_goal: :module}
    {:accepted, target, state} = Scheduler.admit(state, other_opts, prepared)
    {:ok, other_claim, :fetch, _, state} = checkout(state, opts.queue)
    state = private_response(state, other_claim)
    {:ok, state} = Scheduler.complete(state, other_claim, Outcome.new(:succeeded))
    state = state |> Scheduler.release(other_claim) |> drain()

    # A waiting interpretation whose proof changes can join an older private identity.
    waiting_opts = Map.put(other_opts, :javascript_goal, :script)
    {:accepted, waiting, state} = Scheduler.admit(state, waiting_opts, prepared)
    state = drain(state)
    {:ok, ^waiting, state} = Scheduler.take_fork(state)
    state = Scheduler.reattempt(state, waiting, opts.cookie_proof)
    assert Ring.size(state.outcomes) == 1
    state = drain(state)
    assert {:ok, ^waiting, _} = Scheduler.take_fork(state)
    assert waiting != target
  end

  test "page-limited owners yield the same representation to an eligible context" do
    {opts, prepared} = request()
    y_opts = %{opts | url: "https://scheduler.test/first", max_pages: 1}
    y_prepared = %{prepared | equivalence: :first}
    {:accepted, y, state} = Scheduler.admit(Scheduler.new(), y_opts, y_prepared)
    {:ok, held, :fetch, %{id: ^y}, state} = checkout(state, opts.queue)
    {:accepted, owner, state} = Scheduler.admit(state, %{opts | max_pages: 1}, prepared)

    {:accepted, waiter, state} =
      Scheduler.admit(state, %{opts | max_pages: 2, javascript_goal: :module}, prepared)

    representation = state.frontier.jobs[owner].job.representation_id
    {:ok, state} = Scheduler.complete(state, held, Outcome.new(:succeeded))
    state = state |> Scheduler.release(held) |> drain()

    assert %{status: :limited, reason: {:limit, :max_pages}} =
             Frontier.outcome(state.frontier, owner)

    assert Frontier.outcome(state.frontier, waiter) == nil
    assert %{owner: ^waiter, status: :pending} = state.representations[representation]
    assert state.frontier.representation_count == 2
    assert state.frontier.claims == %{}
    assert Ring.size(state.forks) == 0
    assert Map.has_key?(state.notifications.members, owner)

    {:ok, claim, :fetch, %{id: ^waiter, representation_id: ^representation}, state} =
      checkout(state, opts.queue)

    {:ok, state} = Scheduler.complete(state, claim, Outcome.new(:succeeded))
    state = state |> Scheduler.release(claim) |> drain()

    assert %{completed: 2, reserved: 0} =
             Frontier.counts(state.frontier, {opts.scope, opts.generation})

    assert state.claims == %{}
  end

  test "queue retirement transfers a response-less owner without another representation slot" do
    {opts, prepared} = request()
    state = %{Scheduler.new() | frontier: Frontier.new(max_representations: 1)}
    {:accepted, owner, state} = Scheduler.admit(state, opts, prepared)
    sibling = %{opts | queue: nil, javascript_goal: :module}
    {:accepted, waiter, state} = Scheduler.admit(state, sibling, prepared)
    representation = state.frontier.jobs[owner].job.representation_id
    {token, frontier} = Frontier.retire_queue(state.frontier, opts.queue)
    {:done, [], [^owner], frontier} = Frontier.retire_queue_batch(frontier, token)
    state = Scheduler.observe_terminal(%{state | frontier: frontier}, owner) |> drain()
    assert %{status: :cancelled, reason: :queue_retired} = Frontier.outcome(state.frontier, owner)

    assert %{owner: ^waiter, status: :pending, terminal_reuse: nil} =
             state.representations[representation]

    assert state.frontier.representation_count == 1
    {:ok, claim, :fetch, %{id: ^waiter}, state} = checkout(state, sibling.queue)
    {:ok, state} = Scheduler.complete(state, claim, Outcome.new(:succeeded))
    state = state |> Scheduler.release(claim) |> drain()
    assert %{status: :succeeded} = Frontier.outcome(state.frontier, waiter)
    assert state.frontier.claims == %{}
    assert Ring.size(state.forks) == 0
  end

  for ending <- [:queue_retired, :deadline] do
    test "#{ending} never replays an earlier response as its owner's cancellation" do
      {opts, prepared} = request()
      state = %{Scheduler.new() | frontier: Frontier.new(max_representations: 2)}
      {:accepted, owner, state} = Scheduler.admit(state, opts, prepared)

      {:accepted, waiter, state} =
        Scheduler.admit(state, %{opts | javascript_goal: :module}, prepared)

      {:ok, claim, :fetch, _, state} = checkout(state, opts.queue)

      state =
        Scheduler.note_response(state, claim, %{disposition: :candidate, dependency: :initial})

      state = Scheduler.note_request_result(state, claim, Outcome.new(:failed, :unavailable))

      outcome =
        if unquote(ending) == :deadline,
          do: Outcome.new(:limited, {:deadline, :attempt}),
          else: Outcome.new(:cancelled, :queue_retired)

      {:ok, state} = Scheduler.complete(state, claim, outcome, :local)
      state = state |> Scheduler.release(claim) |> drain()
      assert Frontier.outcome(state.frontier, owner) == outcome
      assert Frontier.outcome(state.frontier, waiter) == nil
      assert {:ok, ^waiter, state} = Scheduler.take_fork(state)
      state = Scheduler.reattempt(state, waiter, opts.cookie_proof) |> drain()
      assert {:ok, next, :fetch, %{id: ^waiter}, state} = checkout(state, opts.queue)
      assert state.frontier.representation_count == 2
      {:ok, state} = Scheduler.complete(state, next, Outcome.new(:succeeded))
      assert state |> Scheduler.release(next) |> Map.fetch!(:claims) == %{}
    end
  end

  for ceiling <- [1, 2], ending <- [:local, :different_result, :next_attempt] do
    test "#{ending} cannot reuse earlier completed-response evidence at cap #{ceiling}" do
      {opts, prepared} = request()
      opts = %{opts | max_representations: unquote(ceiling)}
      state = %{Scheduler.new() | frontier: Frontier.new(max_representations: unquote(ceiling))}
      {:accepted, owner, state} = Scheduler.admit(state, opts, prepared)

      {:accepted, waiter, state} =
        Scheduler.admit(state, %{opts | javascript_goal: :module}, prepared)

      {:ok, claim, :fetch, _, state} = checkout(state, opts.queue)
      physical = Outcome.new(:failed, :status_503)

      state =
        Scheduler.note_response(state, claim, %{disposition: :candidate, dependency: :initial})

      state = Scheduler.note_request_result(state, claim, physical)

      state =
        if unquote(ending) == :next_attempt,
          do: Scheduler.note_response(state, claim, nil),
          else: state

      actual =
        if unquote(ending) == :different_result, do: Outcome.new(:failed, :other), else: physical

      origin = if unquote(ending) == :local, do: :local, else: :completion
      {:ok, state} = Scheduler.complete(state, claim, actual, origin)
      state = state |> Scheduler.release(claim) |> drain()
      assert Frontier.outcome(state.frontier, owner) == actual
      assert Frontier.outcome(state.frontier, waiter) == nil
      assert {:ok, ^waiter, state} = Scheduler.take_fork(state)
      state = Scheduler.reattempt(state, waiter, opts.cookie_proof) |> drain()

      if unquote(ceiling) == 1 do
        assert %{status: :limited, reason: {:limit, :max_representations}} =
                 Frontier.outcome(state.frontier, waiter)

        assert state.frontier.representation_count == 1
        assert Map.has_key?(state.notifications.members, waiter)
      else
        assert {:ok, _, :fetch, %{id: ^waiter}, state} = checkout(state, opts.queue)
        assert state.frontier.representation_count == 2
      end

      assert Ring.size(state.forks) == 0
    end
  end

  test "a policy rejection before any transport leaves a reusable vacant request slot" do
    {opts, prepared} = request()
    state = %{Scheduler.new() | frontier: Frontier.new(max_representations: 1)}
    {:accepted, owner, state} = Scheduler.admit(state, opts, prepared)
    {:ok, claim, :fetch, _, state} = checkout(state, opts.queue)
    {:ok, state} = Scheduler.complete(state, claim, Outcome.new(:rejected, :robots))
    state = state |> Scheduler.release(claim) |> drain()

    {:accepted, waiter, state} =
      Scheduler.admit(state, %{opts | javascript_goal: :module}, prepared)

    state = drain(state)
    assert {:ok, _, :fetch, %{id: ^waiter}, state} = checkout(state, opts.queue)
    assert state.frontier.representation_count == 1
    assert %{status: :rejected, reason: :robots} = Frontier.outcome(state.frontier, owner)
    assert Ring.size(state.forks) == 0
  end

  test "implicit executor death notifies its canonical target and preserves private attempt rules" do
    {opts, prepared} = request()
    {:accepted, owner, state} = Scheduler.admit(Scheduler.new(), opts, prepared)

    {:accepted, waiter, state} =
      Scheduler.admit(state, %{opts | javascript_goal: :module}, prepared)

    {:ok, claim, :fetch, _, state} = checkout(state, opts.queue)
    state = state |> Scheduler.release(claim) |> drain()
    assert %{status: :cancelled, reason: :executor_down} = Frontier.outcome(state.frontier, owner)
    assert {:ok, ^waiter, state} = Scheduler.take_fork(state)
    assert {:ok, ^owner, state} = Scheduler.take_notification(state)
    assert :empty = Scheduler.take_notification(state)
    assert state.claims == %{}
  end

  test "retired terminal records stay funded until the canonical notification is consumed" do
    {opts, prepared} = request()
    {:accepted, owner, state} = Scheduler.admit(Scheduler.new(), opts, prepared)
    key = {opts.scope, opts.generation}
    state = Scheduler.retire(state, key)
    {:done, [^owner], frontier} = Frontier.settle_batch(state.frontier, key)
    state = Scheduler.observe_terminal(%{state | frontier: frontier}, owner)
    assert {:more, 0, frontier} = Frontier.dispose_batch(state.frontier, key, 1)
    assert %{status: :cancelled} = Frontier.outcome(frontier, owner)
    assert %Crawler.Job{id: ^owner, opts: %{}, prepared_request: nil} = frontier.jobs[owner].job
    assert {:ok, ^owner, state} = Scheduler.take_notification(%{state | frontier: frontier})
    assert {:done, 2, frontier} = Frontier.dispose_batch(state.frontier, key)
    assert frontier.jobs == %{}
    assert frontier.metadata_bytes == 0
  end

  defp private_response(state, claim) do
    {:ok, state} =
      Scheduler.publish(state, claim, %{
        reuse: %{disposition: :private, dependency: :initial},
        value: nil,
        receipt: make_ref()
      })

    state
  end

  defp request do
    scope = make_ref()

    opts =
      Crawler.Options.assign_defaults(%{
        scope: scope,
        generation: {make_ref(), scope, make_ref()},
        queue: self(),
        url: "https://scheduler.test/script",
        javascript_goal: :script,
        cookie_proof: make_ref()
      })

    prepared = %PreparedRequest{
      request: nil,
      equivalence: :frozen,
      context: %PreparedRequest.Context{allow_redirect: true, policy: %{}, cookie_partition: nil}
    }

    {opts, prepared}
  end

  defp checkout(state, queue) do
    case Scheduler.checkout(state, queue) do
      {:maintenance, state} -> checkout(drain(state), queue)
      result -> result
    end
  end

  defp drain(state) do
    case Scheduler.maintenance(state, 32) do
      {:more, _, state} -> drain(state)
      {:done, _, state} -> state
    end
  end

  defp acknowledge_notifications(state) do
    case Scheduler.take_notification(state) do
      {:ok, _, state} -> acknowledge_notifications(state)
      :empty -> state
    end
  end
end
