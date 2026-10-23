defmodule Crawler.Store.AliasesTest do
  use ExUnit.Case, async: false

  alias Crawler.Store

  import Crawler.TestHelpers, only: [unique_scope: 1]

  setup do
    scope = unique_scope("alias-ownership")
    generation = Store.generation(scope)
    queue = self()
    :ok = Store.note_enqueued(scope, generation, queue)
    on_exit(fn -> Store.drop_scope(scope) end)

    %{scope: scope, generation: generation, queue: queue}
  end

  test "reuses an unprocessed page only after its canonical requested claim finishes", context do
    url = "http://EXAMPLE.com/dir/../landing#fragment"
    key = {"http://example.com/landing", context.scope}
    worker = start_claim(context, url)

    assert {:ok, :skip} = Store.register_alias(key, context.generation, context.queue)
    finish_claim(worker)
    assert {:ok, :reused} = Store.register_alias(key, context.generation, context.queue)
    assert Store.find(key)
  end

  test "protects an alias held by another active redirect and clears rolled-back ownership",
       context do
    key = {"http://example.com/landing", context.scope}
    worker = start_claim(context, "http://example.com/old", key)

    assert {:ok, :skip} = Store.register_alias(key, context.generation, context.queue)

    send(worker, {:rollback, key, true})
    assert_receive {:rolled_back, ^worker}
    assert {:ok, :created} = Store.register_alias(key, context.generation, context.queue)
    finish_claim(worker)
  end

  test "releases a reused alias after an error while preserving its failed registration",
       context do
    key = {"http://example.com/failed", context.scope}
    assert {:ok, _} = Store.add(key, context.generation, context.queue)
    original = Store.find(key)
    worker = start_claim(context, "http://example.com/old")

    send(worker, {:acquire, key})
    assert_receive {:alias_acquired, ^worker, :reused}
    assert {:ok, :skip} = Store.register_alias(key, context.generation, context.queue)

    send(worker, {:rollback, key, false})
    assert_receive {:rolled_back, ^worker}
    assert Store.find(key) == original
    assert {:ok, :reused} = Store.register_alias(key, context.generation, context.queue)
    finish_claim(worker)
  end

  test "same-canonical alias rollback keeps the active requested key protected", context do
    key = {"http://example.com/page/", context.scope}
    worker = start_claim(context, "http://example.com/page")

    send(worker, {:acquire, key})
    assert_receive {:alias_acquired, ^worker, :reused}
    send(worker, {:rollback, key, false})
    assert_receive {:rolled_back, ^worker}

    assert {:ok, :skip} = Store.register_alias(key, context.generation, context.queue)
    finish_claim(worker)
    assert {:ok, :reused} = Store.register_alias(key, context.generation, context.queue)
  end

  test "canonical callers exclusively own reused aliases without replacing the stored page",
       context do
    key = {"http://example.com/reused", context.scope}
    assert {:ok, _} = Store.add(key, context.generation, context.queue)
    original = Store.find(key)
    first = start_claim(context, "http://example.com/first")
    second = start_claim(context, "http://example.com/second")

    send(first, {:acquire, key})
    assert_receive {:alias_acquired, ^first, :reused}
    held = Store.find(key)
    assert is_reference(held.alias_owner)
    assert held.target_handle === original.target_handle
    assert held.body === original.body

    send(second, {:acquire, key})
    assert_receive {:alias_acquired, ^second, :skip}
    send(second, {:rollback, key, false})
    assert_receive {:rolled_back, ^second}
    assert Store.find(key) === held

    send(first, {:rollback, key, false})
    assert_receive {:rolled_back, ^first}
    assert Store.find(key) === original

    send(second, {:acquire, key})
    assert_receive {:alias_acquired, ^second, :reused}
    held = Store.find(key)
    refute held.alias_owner === original.alias_owner
    send(first, {:rollback, key, true})
    assert_receive {:rolled_back, ^first}
    assert Store.find(key) === held

    send(second, {:rollback, key, false})
    assert_receive {:rolled_back, ^second}
    assert Store.find(key) === original

    send(first, {:acquire, key})
    assert_receive {:alias_acquired, ^first, :reused}
    finish_claim(first)
    send(second, {:acquire, key})
    assert_receive {:alias_acquired, ^second, :reused}
    send(second, {:rollback, key, false})
    assert_receive {:rolled_back, ^second}
    assert Store.find(key) === original
    finish_claim(second)
  end

  test "requested claim keys preserve exact numeric scope identity", context do
    integer_scope = {context.scope, 1}
    float_scope = {context.scope, 1.0}
    integer_generation = Store.generation(integer_scope)
    float_generation = Store.generation(float_scope)
    integer_context = %{context | scope: integer_scope, generation: integer_generation}
    url = "http://example.com/page"

    on_exit(fn ->
      Store.drop_scope(integer_scope)
      Store.drop_scope(float_scope)
    end)

    assert :ok = Store.note_enqueued(integer_scope, integer_generation, context.queue)
    assert :ok = Store.note_enqueued(float_scope, float_generation, context.queue)
    assert {:ok, _} = Store.add({url, float_scope}, float_generation, context.queue)
    worker = start_claim(integer_context, url)

    assert {:ok, :reused} =
             Store.register_alias({url, float_scope}, float_generation, context.queue)

    finish_claim(worker)
  end

  test "a successful source's bare alias lock does not prove landing completion", context do
    landing_url = "http://example.com/provisional-landing"
    key = {landing_url, context.scope}
    source = start_claim(context, "http://example.com/successful-source")
    admitted = admit_claim(context, landing_url)

    assert :ok =
             Crawler.Store.Execution.run(admitted, fn owned ->
               assert {:ok, _} =
                        Store.add(key, owned.generation, owned.queue, nil, owned.target_handle)

               assert :stored = Store.add_page_data(key, "ORIGINAL LANDING", owned)
               :ok
             end)

    original = Store.find(key)
    assert is_reference(original.target_handle)
    assert original.body == "ORIGINAL LANDING"
    assert Store.target_outcome(original.target_handle) == nil
    send(source, {:acquire, key})
    assert_receive {:alias_acquired, ^source, :reused}
    locked = Store.find(key)
    assert is_reference(locked.alias_owner)
    assert locked.target_handle === original.target_handle
    assert locked.body === original.body

    assert {_, _} = Store.processed(key, context.generation, context.queue)
    assert Store.find_processed(key)
    refute Crawler.Store.Aliases.completed?(:sys.get_state(Store), key)
    finish_claim(source, Crawler.Job.Outcome.new(:succeeded))
    assert %{status: :succeeded} = Store.target_outcome(locked.alias_owner)
    assert Store.target_outcome(original.target_handle) == nil
    page = Store.find_processed(key)
    assert page.alias_owner === locked.alias_owner
    assert page.target_handle === original.target_handle
    assert page.body === original.body
    refute Crawler.Store.Aliases.completed?(:sys.get_state(Store), key)
  end

  for {status, reason} <- [failed: :fixture_failure, limited: {:limit, :max_body}] do
    test "reacquires a #{status} processed orphan through its canonical queue", context do
      key = {"http://example.com/orphan-#{unquote(status)}", context.scope}
      landing = start_claim(context, elem(key, 0))
      source = start_claim(context, "http://example.com/orphan-source-#{unquote(status)}")
      send(landing, {:complete_requested, "ORIGINAL ORPHAN"})
      assert_receive {:requested_completed, ^landing}
      original = Store.find_processed(key)
      assert original.body == "ORIGINAL ORPHAN"
      assert is_reference(original.target_handle)
      assert Crawler.Store.State.page_owner(:sys.get_state(Store), key) == {:owned, context.queue}
      outcome = Crawler.Job.Outcome.new(unquote(status), unquote(Macro.escape(reason)))
      finish_claim(landing, outcome)
      assert Store.target_outcome(original.target_handle) == outcome
      assert Store.find_processed(key) === original
      refute Crawler.Store.Aliases.completed?(:sys.get_state(Store), key)
      assert Crawler.Store.State.page_owner(:sys.get_state(Store), key) == {:owned, context.queue}

      send(source, {:acquire, key})
      assert_receive {:alias_acquired, ^source, :reused}
      reacquired = Store.find_processed(key)
      assert is_reference(reacquired.alias_owner)
      assert reacquired.target_handle === original.target_handle
      assert reacquired.body === original.body
      assert Store.target_outcome(original.target_handle) == outcome
      assert Crawler.Store.State.page_owner(:sys.get_state(Store), key) == {:owned, context.queue}
      refute Crawler.Store.Aliases.completed?(:sys.get_state(Store), key)

      send(source, {:rollback, key, false})
      assert_receive {:rolled_back, ^source}
      assert Store.find_processed(key) === original
      assert Store.target_outcome(original.target_handle) == outcome
      finish_claim(source)
    end
  end

  test "leaves another queue's unprocessed page untouched", context do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    key = {"http://example.com/other-queue", context.scope}
    assert :ok = Store.note_enqueued(context.scope, context.generation, owner)
    assert {:ok, _} = Store.add(key, context.generation, owner)

    assert {:ok, :skip} = Store.register_alias(key, context.generation, context.queue)
    assert Store.find(key)
    assert :ok = Store.finish_work(context.scope, context.generation, false, context.queue)
    assert Store.find(key)
  end

  test "leaves processed pages untouched", context do
    key = {"http://example.com/processed", context.scope}
    assert {:ok, _} = Store.add(key, context.generation, context.queue)
    assert {_, _} = Store.processed(key, context.generation, context.queue)

    assert {:ok, :skip} = Store.register_alias(key, context.generation, context.queue)
    assert Store.find_processed(key)
  end

  test "creates direct aliases but does not adopt existing direct registrations", context do
    key = {"http://example.com/direct", context.scope}
    assert {:ok, :created} = Store.register_alias(key, context.generation, nil)
    assert {:ok, :skip} = Store.register_alias(key, context.generation, nil)
  end

  test "rejects stale generations and retired queues without registering aliases", context do
    key = {"http://example.com/stale", context.scope}
    assert :ok = Store.release_queue(context.queue)
    assert {:error, :stale} = Store.register_alias(key, context.generation, context.queue)
    refute Store.find(key)

    generation = Store.generation(context.scope)
    assert {:error, :stale} = Store.register_alias(key, generation, context.queue)
    refute Store.find(key)
  end

  defp start_claim(context, url, alias_key \\ nil) do
    parent = self()
    admit_claim(context, url)

    owner =
      spawn(fn ->
        assert {:ok, claim, :fetch, admitted} = Store.checkout_job(context.queue)

        result =
          Crawler.Store.Execution.run(admitted, &run_claim(parent, url, alias_key, &1))

        {executor, outcome} =
          case result do
            {executor, %Crawler.Job.Outcome{} = outcome} -> {executor, outcome}
            executor -> {executor, Crawler.Job.Outcome.new(:failed, :fixture_finished)}
          end

        :ok = Store.complete_job(claim, outcome)
        send(parent, {:claim_finished, executor})
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    assert_receive {:claim_ready, executor}, 2_000
    executor
  end

  defp admit_claim(context, url) do
    opts =
      context
      |> Map.merge(%{
        url: url,
        max_pages: :infinity,
        max_body: 1_024,
        max_analysis_bytes: 2_097_152,
        respect_robots: false
      })
      |> Crawler.Options.assign_defaults()

    assert {:ok, prepared} = Crawler.Fetcher.Requester.prepare(opts)
    assert {:ok, admitted} = Store.admit_job(opts, prepared)
    admitted
  end

  defp run_claim(parent, url, alias_key, owned) do
    {:ok, _} = Store.add({url, owned.scope}, owned.generation, owned.queue)

    if alias_key do
      {:ok, :created} = Store.register_alias(alias_key, owned.generation, owned.queue)
    end

    send(parent, {:claim_ready, self()})
    await_finish(parent, owned)
  end

  defp await_finish(parent, context) do
    receive do
      {:acquire, key} ->
        {:ok, status} = Store.register_alias(key, context.generation, context.queue)
        send(parent, {:alias_acquired, self(), status})
        await_finish(parent, context)

      {:rollback, key, created?} ->
        :ok = Store.rollback_alias(key, context.generation, context.queue, created?)
        send(parent, {:rolled_back, self()})
        await_finish(parent, context)

      {:complete_requested, body} ->
        key = {context.url, context.scope}
        :stored = Store.add_page_data(key, body, context)
        :ok = Store.complete_page(key, context.generation, context.queue)
        send(parent, {:requested_completed, self()})
        await_finish(parent, context)

      {:finish, outcome} ->
        {self(), outcome}

      :finish ->
        self()
    end
  end

  defp finish_claim(worker, outcome \\ nil) do
    send(worker, if(outcome, do: {:finish, outcome}, else: :finish))
    assert_receive {:claim_finished, ^worker}
  end
end
