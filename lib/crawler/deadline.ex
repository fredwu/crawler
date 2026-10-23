defmodule Crawler.Deadline do
  @moduledoc false

  @enforce_keys [:at, :kind]
  defstruct [:at, :kind]

  def now, do: System.monotonic_time(:millisecond)

  def after_ms(timeout, kind \\ :attempt)
      when is_integer(timeout) and timeout >= 0 and kind in [:attempt, :run] do
    %__MODULE__{at: now() + timeout, kind: kind}
  end

  def remaining(%__MODULE__{at: at}), do: max(at - now(), 0)

  def check(%__MODULE__{} = deadline) do
    if remaining(deadline) == 0, do: {:error, {:deadline, deadline.kind}}, else: :ok
  end

  def cap(%__MODULE__{} = run, timeout) when is_integer(timeout) and timeout > 0 do
    attempt = after_ms(timeout)
    if run.at <= attempt.at, do: run, else: attempt
  end

  def run(%__MODULE__{} = deadline, fun, on_expire \\ fn _executor -> :ok end)
      when is_function(fun, 0) and is_function(on_expire, 1),
      do: run(deadline, fun, on_expire, fn _executor -> :ok end)

  def run(%__MODULE__{} = deadline, fun, on_expire, on_discard)
      when is_function(fun, 0) and is_function(on_expire, 1) and is_function(on_discard, 1) do
    caller = self()
    callers = [caller | Process.get(:"$callers", [])]

    {executor, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        executor = self()
        spawn(fn -> watch_caller(caller, executor) end)

        receive do
          {:execute, ^caller, reference} ->
            result =
              try do
                {:ok, fun.()}
              catch
                kind, reason -> {:raised, kind, reason, __STACKTRACE__}
              end

            send(caller, {reference, result})
        end
      end)

    if check(deadline) == :ok do
      send(executor, {:execute, caller, monitor})
      await(executor, monitor, deadline, on_expire, on_discard)
    else
      expire(executor, monitor, deadline, on_expire, on_discard)
    end
  end

  defp await(executor, monitor, deadline, on_expire, on_discard) do
    receive do
      {^monitor, {:ok, result}} ->
        accept_terminal({:ok, result}, executor, monitor, deadline, on_expire, on_discard)

      {^monitor, {:raised, kind, reason, stacktrace}} ->
        accept_terminal(
          {:raised, kind, reason, stacktrace},
          executor,
          monitor,
          deadline,
          on_expire,
          on_discard
        )

      {:DOWN, ^monitor, :process, ^executor, reason} ->
        if check(deadline) == :ok do
          case on_discard.(executor) do
            {:revoked, result} -> {:ok, result}
            _ -> exit(reason)
          end
        else
          expire(executor, monitor, deadline, on_expire, on_discard, true)
        end
    after
      remaining(deadline) -> expire(executor, monitor, deadline, on_expire, on_discard)
    end
  end

  defp accept_terminal(result, executor, monitor, deadline, on_expire, on_discard) do
    if check(deadline) == :ok do
      if match?({:raised, _, _, _}, result) do
        await_down(executor, monitor)
        on_discard.(executor)
      else
        Process.demonitor(monitor, [:flush])
      end

      terminal_result(result)
    else
      expire(executor, monitor, deadline, on_expire, on_discard)
    end
  end

  defp terminal_result({:ok, result}), do: {:ok, result}

  defp terminal_result({:raised, kind, reason, stacktrace}),
    do: :erlang.raise(kind, reason, stacktrace)

  defp expire(executor, monitor, deadline, on_expire, on_discard, down_received? \\ false) do
    try do
      on_expire.(executor)
    after
      Process.exit(executor, :kill)
      if down_received?, do: flush_result(monitor), else: await_down(executor, monitor)
      on_discard.(executor)
    end

    {:error, {:deadline, deadline.kind}}
  end

  defp await_down(executor, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^executor, _reason} ->
        flush_result(monitor)
    end
  end

  defp flush_result(monitor) do
    receive do
      {^monitor, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp watch_caller(caller, executor) do
    caller_monitor = Process.monitor(caller)
    executor_monitor = Process.monitor(executor)

    receive do
      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        Process.exit(executor, :kill)

      {:DOWN, ^executor_monitor, :process, ^executor, _reason} ->
        :ok
    end
  end
end
