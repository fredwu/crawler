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

  test "requested claim keys preserve exact numeric scope identity", context do
    integer_scope = {context.scope, 1}
    float_scope = {context.scope, 1.0}
    integer_context = %{context | scope: integer_scope}
    url = "http://example.com/page"

    on_exit(fn ->
      Store.drop_scope(integer_scope)
      Store.drop_scope(float_scope)
    end)

    assert :ok = Store.note_enqueued(integer_scope, context.generation, context.queue)
    assert :ok = Store.note_enqueued(float_scope, context.generation, context.queue)
    assert {:ok, _} = Store.add({url, float_scope}, context.generation, context.queue)
    worker = start_claim(integer_context, url)

    assert {:ok, :reused} =
             Store.register_alias({url, float_scope}, context.generation, context.queue)

    finish_claim(worker)
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
    :ok = Store.note_enqueued(context.scope, context.generation, context.queue)

    worker =
      spawn(fn ->
        opts = Map.merge(context, %{url: url, max_pages: :infinity})
        {:ok, claim} = Store.start_work(opts)
        {:ok, _} = Store.add({url, context.scope}, context.generation, context.queue)

        if alias_key do
          {:ok, :created} = Store.register_alias(alias_key, context.generation, context.queue)
        end

        send(parent, {:claim_ready, self()})
        await_finish(parent, claim, context)
      end)

    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive {:claim_ready, ^worker}
    worker
  end

  defp await_finish(parent, claim, context) do
    receive do
      {:acquire, key} ->
        {:ok, status} = Store.register_alias(key, context.generation, context.queue)
        send(parent, {:alias_acquired, self(), status})
        await_finish(parent, claim, context)

      {:rollback, key, created?} ->
        :ok = Store.rollback_alias(key, context.generation, context.queue, created?)
        send(parent, {:rolled_back, self()})
        await_finish(parent, claim, context)

      :finish ->
        :ok = Store.finish_claim(claim)
        send(parent, {:claim_finished, self()})
    end
  end

  defp finish_claim(worker) do
    send(worker, :finish)
    assert_receive {:claim_finished, ^worker}
  end
end
