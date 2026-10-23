defmodule Crawler.DeadlineTest do
  use ExUnit.Case, async: true

  alias Crawler.Deadline

  test "a work deadline cannot extend the run deadline" do
    run = Deadline.after_ms(1_000, :run)
    assert Deadline.cap(run, 10_000) == run
    assert %Deadline{kind: :attempt, at: at} = Deadline.cap(run, 100)
    assert at < run.at
    assert Deadline.check(Deadline.after_ms(0, :run)) == {:error, {:deadline, :run}}
  end

  test "returns callback values without changing caller exit trapping" do
    before = Process.info(self(), :trap_exit)

    assert Deadline.run(Deadline.after_ms(1_000), fn -> {:error, :ordinary_value} end) ==
             {:ok, {:error, :ordinary_value}}

    assert Process.info(self(), :trap_exit) == before
  end

  test "preserves callback errors, throws and exits" do
    assert_raise ArgumentError, "callback failure", fn ->
      Deadline.run(Deadline.after_ms(1_000), fn -> raise ArgumentError, "callback failure" end)
    end

    assert catch_throw(Deadline.run(Deadline.after_ms(1_000), fn -> throw(:thrown) end)) ==
             :thrown

    assert catch_exit(Deadline.run(Deadline.after_ms(1_000), fn -> exit(:custom_exit) end)) ==
             :custom_exit
  end

  test "a raised callback discards pending returns after its executor ends" do
    parent = self()

    assert_raise ArgumentError, "callback failure", fn ->
      Deadline.run(
        Deadline.after_ms(1_000),
        fn ->
          raise ArgumentError, "callback failure"
        end,
        fn _ -> flunk("live callback must not expire") end,
        fn executor ->
          send(parent, {:discarded_raised, Process.alive?(executor)})
        end
      )
    end

    assert_receive {:discarded_raised, false}
  end

  test "settles before killing the executor and leaves its caller alive" do
    parent = self()

    task =
      Task.async(fn ->
        Deadline.run(
          Deadline.after_ms(100),
          fn ->
            send(parent, {:started, self()})

            receive do
              :never -> :ok
            end
          end,
          fn executor -> send(parent, {:settled, executor, Process.alive?(executor)}) end
        )
      end)

    assert_receive {:started, executor}
    monitor = Process.monitor(executor)
    assert_receive {:settled, ^executor, true}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}
    assert Task.await(task) == {:error, {:deadline, :attempt}}
    assert Process.alive?(self())
  end

  test "already expired executions do not invoke the callback" do
    parent = self()

    assert Deadline.run(Deadline.after_ms(0), fn -> send(parent, :executed) end) ==
             {:error, {:deadline, :attempt}}

    refute_received :executed
  end

  test "a failing settlement still terminates the executor and propagates its failure" do
    parent = self()

    assert_raise ArgumentError, "settlement failed", fn ->
      Deadline.run(Deadline.after_ms(0), fn -> :never end, fn executor ->
        send(parent, {:executor, executor})
        raise ArgumentError, "settlement failed"
      end)
    end

    assert_received {:executor, executor}
    refute Process.alive?(executor)
  end

  test "caller death also terminates blocked owned work" do
    parent = self()

    caller =
      spawn(fn ->
        Deadline.run(Deadline.after_ms(10_000), fn ->
          send(parent, {:owned, self()})

          receive do
            :never -> :ok
          end
        end)
      end)

    assert_receive {:owned, executor}
    monitor = Process.monitor(executor)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}, 1_000
  end

  for terminal <- [:result, :raised, :killed] do
    test "a queued #{terminal} cannot bypass an expired absolute deadline" do
      held_terminal(unquote(terminal))
    end
  end

  defp held_terminal(terminal) do
    parent = self()
    deadline = Deadline.after_ms(1_000)

    caller =
      spawn(fn ->
        result =
          try do
            Deadline.run(
              deadline,
              fn ->
                send(parent, {:held_executor, self()})

                receive do
                  :finish -> terminal(terminal)
                end
              end,
              fn executor -> send(parent, {:expired, executor}) end
            )
          catch
            kind, reason -> {:unexpected, kind, reason}
          end

        send(parent, {:returned, result, Process.info(self(), :messages)})
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:held_executor, executor}, 1_000
    assert :erlang.suspend_process(caller)
    monitor = Process.monitor(executor)
    send(executor, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^executor, _reason}, 1_000
    assert {:messages, [_ | _]} = Process.info(caller, :messages)

    timer_ref = make_ref()
    Process.send_after(self(), {:deadline_elapsed, timer_ref}, Deadline.remaining(deadline))
    assert_receive {:deadline_elapsed, ^timer_ref}, 2_000
    assert Deadline.check(deadline) == {:error, {:deadline, :attempt}}
    assert :erlang.resume_process(caller)
    assert_receive {:expired, ^executor}, 1_000

    assert_receive {:returned, {:error, {:deadline, :attempt}}, {:messages, []}}, 1_000
    refute_received {:expired, ^executor}
  end

  defp terminal(:result), do: :late_result
  defp terminal(:raised), do: raise(ArgumentError, "late failure")
  defp terminal(:killed), do: Process.exit(self(), :kill)
end
