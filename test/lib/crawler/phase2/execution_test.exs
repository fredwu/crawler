defmodule Crawler.Store.ExecutionTest do
  use ExUnit.Case, async: false

  alias Crawler.Deadline
  alias Crawler.Store
  alias Crawler.Store.Authority
  alias Crawler.Store.Execution

  test "a stale run returns before starting a nested executor" do
    scope = make_ref()
    generation = Store.generation(scope)
    Store.dispose_scope(scope)
    parent = self()

    assert Execution.run(%{scope: scope, generation: generation}, fn _ ->
             send(parent, :stale_callback)
           end) == {:error, :stale}

    refute_received :stale_callback
  end

  test "intentional retirement returns typed stale without leaking its revocation signal" do
    scope = make_ref()
    generation = Store.generation(scope)

    assert Execution.run(%{scope: scope, generation: generation}, fn _ ->
             Store.dispose_scope(scope)

             receive do
               :never -> :ok
             end
           end) == {:error, :stale}

    refute_received {:crawler_execution_revoked, _, _, _}
  end

  test "a manually acquired lease revokes without terminating its caller" do
    scope = make_ref()
    generation = Store.generation(scope)
    deadline = Deadline.after_ms(5_000)
    opts = Crawler.Options.assign_defaults(%{scope: scope, generation: generation})
    {:ok, lease} = Store.begin_execution(opts, deadline)
    send(Process.whereis(Store), {:expire_execution, lease})
    :sys.get_state(Store)
    refute Authority.execution_current?(lease)
    assert :ok = Store.end_execution(lease)
    Store.dispose_scope(scope)
    assert Process.alive?(self())
  end

  test "an unexpected executor kill remains an exit" do
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)

    assert catch_exit(Execution.run(%{scope: scope}, fn _ -> Process.exit(self(), :kill) end)) ==
             :killed

    refute_received {:crawler_execution_revoked, _, _, _}
  end

  test "an already queued mutation cannot commit after absolute expiry" do
    scope = make_ref()
    parent = self()
    opts = %{scope: scope, attempt_timeout: 150, respect_robots: false}
    on_exit(fn -> Store.dispose_scope(scope) end)

    caller =
      spawn(fn ->
        result =
          Execution.run(opts, fn bound ->
            send(parent, {:executor, self(), bound})

            receive do
              :mutate -> :ok
            end

            send(parent, :mutation_sent)
            Store.add({"http://queued-expiry/", scope}, bound.generation)
          end)

        send(parent, {:finished, result})
      end)

    assert_receive {:executor, executor, bound}
    :sys.suspend(Store)

    try do
      send(executor, :mutate)
      assert_receive :mutation_sent
      wait_until(bound.crawler_deadline.at + 5)
      refute Authority.current?(scope, bound.generation, nil, bound.execution_lease)
    after
      :sys.resume(Store)
    end

    assert_receive {:finished, {:error, {:deadline, :attempt}}}, 1_000
    assert Store.find({"http://queued-expiry/", scope}) == nil
    refute Process.alive?(executor)
    refute Process.alive?(caller)
  end

  test "expiry revokes only the executor lease and sibling work remains authorized" do
    scope = make_ref()
    generation = Store.generation(scope)
    opts = %{scope: scope, generation: generation, attempt_timeout: 500}
    on_exit(fn -> Store.dispose_scope(scope) end)
    parent = self()

    task =
      Task.async(fn ->
        Execution.run(opts, fn bound ->
          send(parent, {:sibling, bound})

          receive do
            :finish -> :ok
          end

          assert Store.add({"http://live-sibling/", scope}, generation) |> elem(0) == :ok
          :live
        end)
      end)

    assert_receive {:sibling, sibling}

    assert Execution.run(%{opts | attempt_timeout: 20}, fn _ ->
             receive do
               :never -> :ok
             end
           end) == {:error, {:deadline, :attempt}}

    assert Authority.current?(scope, generation, nil, sibling.execution_lease)
    send(task.pid, :finish)
    # The executor is distinct from the direct caller.
    [{_, executor, _, _, _, _}] = :ets.lookup(Execution, sibling.execution_lease)
    send(executor, :finish)
    assert Task.await(task) == :live
    assert Store.current?(scope, generation)
  end

  test "expiry charges only active control transports, including nested intervals" do
    for active <- 0..2 do
      scope = make_ref()
      on_exit(fn -> Store.dispose_scope(scope) end)

      assert Execution.run(%{scope: scope, attempt_timeout: 35, max_body: 100}, fn bound ->
               assert :ok = Store.account_control_entity(bound, 1, 7)

               for _ <- 1..active//1, active > 0 do
                 assert :ok = Store.control_transport_started(bound)
               end

               receive do: (:never -> :ok)
             end) == {:error, {:deadline, :attempt}}

      assert :sys.get_state(Store).scopes[scope].control_bytes == 7 + 100 * active
    end
  end

  test "a closed transport is not charged again during later executor work" do
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)

    assert Execution.run(%{scope: scope, attempt_timeout: 35, max_body: 100}, fn bound ->
             assert :ok = Store.control_transport_started(bound)
             assert :ok = Store.account_control_entity(bound, 1, 7)
             assert :ok = Store.control_transport_finished(bound)
             receive do: (:never -> :ok)
           end) == {:error, {:deadline, :attempt}}

    assert :sys.get_state(Store).scopes[scope].control_bytes == 7
  end

  test "a live execution cannot borrow a sibling run's mutation authority" do
    scope = make_ref()
    sibling = make_ref()
    generation = Store.generation(sibling)

    on_exit(fn ->
      Store.dispose_scope(scope)
      Store.dispose_scope(sibling)
    end)

    assert :ok =
             Execution.run(%{scope: scope}, fn _owned ->
               assert {:error, :stale} =
                        Store.add({"https://execution.test/foreign", sibling}, generation)

               assert {:ok, _} = Store.add({"https://execution.test/own", scope})
               :ok
             end)

    assert Store.find({"https://execution.test/foreign", sibling}) == nil
    assert Store.find({"https://execution.test/own", scope}) != nil
    assert Store.current?(sibling, generation)
  end

  defp wait_until(at) do
    reference = make_ref()
    Process.send_after(self(), reference, max(at - Deadline.now(), 0))

    receive do
      ^reference -> :ok
    end
  end
end
