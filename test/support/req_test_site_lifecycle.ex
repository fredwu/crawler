defmodule Crawler.ReqTestSite.Lifecycle do
  @moduledoc false

  @settle_timeout 5_000

  def initial_state do
    %{
      requests: %{},
      closing?: false,
      waiters: [],
      crawls: MapSet.new(),
      owned_queues: MapSet.new()
    }
  end

  def track_crawl(agent, opts, tracking_opts) do
    work = {opts[:scope], opts[:generation], opts[:queue]}
    owner = if tracking_opts[:owned_queue?], do: owned_queue(opts)

    case register_crawl(agent, work, owner) do
      :ok ->
        :ok

      :closed ->
        if owner, do: Crawler.Queue.stop(owner)
        {:error, :fixture_closed}
    end
  end

  defp register_crawl(agent, work, owner) do
    Agent.get_and_update(agent, fn state ->
      if state.closing? do
        {:closed, state}
      else
        {:ok, register_work(state, work, owner)}
      end
    end)
  catch
    :exit, _ -> :closed
  end

  defp register_work(state, work, nil), do: %{state | crawls: MapSet.put(state.crawls, work)}

  defp register_work(state, work, owner) do
    %{
      state
      | crawls: MapSet.put(state.crawls, work),
        owned_queues: MapSet.put(state.owned_queues, owner)
    }
  end

  def start_request(state, token, caller, agent) do
    watcher = watch_request(agent, token, caller)
    state = update_in(state, [:requests], &Map.put(&1, token, watcher))
    {state, watcher}
  end

  def cleanup(agent) do
    {queues, watchers} =
      Agent.get_and_update(agent, fn state ->
        {{state.owned_queues, Map.values(state.requests)}, %{state | closing?: true}}
      end)

    Enum.each(queues, &Crawler.Queue.stop/1)
    Enum.each(watchers, &finish_request/1)
  end

  defp owned_queue(%{queue: queue, queue_owner: owner, scope: scope}) do
    case Crawler.Store.queue_record(queue) do
      %{owner: ^owner, scope: ^scope} when is_pid(owner) ->
        owner

      _ ->
        nil
    end
  end

  defp owned_queue(_opts), do: nil

  def cleanup_on_exit(opts) do
    ExUnit.Callbacks.on_exit(fn -> Crawler.stop(opts) end)
  end

  defp watch_request(agent, token, request) do
    spawn(fn ->
      request_ref = Process.monitor(request)
      agent_ref = Process.monitor(agent)

      try do
        receive do
          :finished ->
            :ok

          {:handler, fun, timeout} ->
            run_handler(fun, timeout, request, request_ref, agent_ref)

          {:DOWN, ^request_ref, _, _, _} ->
            :ok

          {:DOWN, ^agent_ref, _, _, _} ->
            :ok
        end

        release_request(agent, token)
      after
        Process.demonitor(request_ref, [:flush])
        Process.demonitor(agent_ref, [:flush])
      end
    end)
  end

  def handler_result(watcher, fun, timeout) do
    ref = Process.monitor(watcher)
    send(watcher, {:handler, fun, timeout})

    receive do
      {:req_test_site_result, ^watcher, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^watcher, reason} ->
        {:error, "exited: #{inspect(reason)}"}
    end
  end

  defp await_handler_start(watcher) do
    ref = Process.monitor(watcher)

    receive do
      {:req_test_site_start, ^watcher} ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, ^watcher, _} ->
        exit(:normal)
    end
  end

  def finish_request(watcher) do
    ref = Process.monitor(watcher)
    send(watcher, :finished)

    receive do
      {:DOWN, ^ref, :process, ^watcher, _} -> :ok
    after
      @settle_timeout ->
        Process.demonitor(ref, [:flush])

        raise ExUnit.AssertionError,
          message: "Timed out waiting for ReqTestSite request cleanup"
    end
  end

  defp run_handler(fun, timeout, request, request_ref, agent_ref) do
    watcher = self()

    task =
      Task.async(fn ->
        await_handler_start(watcher)
        fun.()
      end)

    Process.unlink(task.pid)
    handler_ref = Process.monitor(task.pid)
    send(task.pid, {:req_test_site_start, watcher})

    try do
      watch_handler(task, handler_ref, timeout, request, request_ref, agent_ref)
    after
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      Process.demonitor(handler_ref, [:flush])
    end
  end

  defp watch_handler(task, handler_ref, timeout, request, request_ref, agent_ref) do
    receive do
      {:DOWN, ^handler_ref, :process, _, _} ->
        send_result(request, task_result(Task.yield(task, 0)))
        await_request_finish(request_ref, agent_ref)

      :finished ->
        send_result(request, task_result(Task.shutdown(task, :brutal_kill)))

      {:DOWN, ^request_ref, _, _, _} ->
        Task.shutdown(task, :brutal_kill)

      {:DOWN, ^agent_ref, _, _, _} ->
        send_result(request, task_result(Task.shutdown(task, :brutal_kill)))
    after
      timeout ->
        Task.shutdown(task, :brutal_kill)
        send_result(request, {:error, "timed out after #{timeout} ms"})
        await_request_finish(request_ref, agent_ref)
    end
  end

  defp task_result({:ok, result}), do: result
  defp task_result({:exit, reason}), do: {:error, "exited: #{inspect(reason)}"}
  defp task_result(nil), do: {:error, "exited: :killed"}

  defp send_result(request, result), do: send(request, {:req_test_site_result, self(), result})

  defp await_request_finish(request_ref, agent_ref) do
    receive do
      :finished -> :ok
      {:DOWN, ^request_ref, _, _, _} -> :ok
      {:DOWN, ^agent_ref, _, _, _} -> :ok
    end
  end

  defp release_request(agent, token) do
    Agent.update(agent, fn state ->
      notify_waiters(%{state | requests: Map.delete(state.requests, token)})
    end)
  catch
    :exit, _ -> :ok
  end

  defp notify_waiters(state) do
    if map_size(state.requests) == 0 do
      Enum.each(state.waiters, &notify_waiter/1)
      %{state | waiters: []}
    else
      state
    end
  end

  defp notify_waiter({pid, ref}), do: send(pid, {:req_test_site_idle, ref})

  def wait_until_settled(agent) do
    wait_until_settled(agent, deadline())
  end

  defp wait_until_settled(agent, deadline) do
    wait_for_crawls(agent, deadline)
    wait_until_idle(agent, deadline)

    unless crawls_idle?(agent) do
      wait_until_settled(agent, deadline)
    end
  end

  defp wait_until_idle(agent, deadline) do
    ref = make_ref()

    case register_idle_waiter(agent, ref) do
      :idle ->
        :ok

      :waiting ->
        receive do
          {:req_test_site_idle, ^ref} ->
            :ok
        after
          remaining_timeout(deadline) ->
            raise ExUnit.AssertionError,
              message: "Timed out waiting for ReqTestSite requests to finish"
        end
    end
  end

  defp register_idle_waiter(agent, ref) do
    caller = self()

    Agent.get_and_update(agent, fn state ->
      if map_size(state.requests) == 0 do
        {:idle, state}
      else
        {:waiting, update_in(state, [:waiters], &[{caller, ref} | &1])}
      end
    end)
  end

  defp wait_for_crawls(agent, deadline) do
    if crawls_idle?(agent) do
      :ok
    else
      wait_for_timeout(10, deadline)
      wait_for_crawls(agent, deadline)
    end
  end

  defp crawls_idle?(agent) do
    agent
    |> Agent.get(& &1.crawls)
    |> Enum.all?(fn {scope, generation, queue} ->
      not Crawler.Store.work_pending?(scope, generation, queue)
    end)
  end

  defp deadline do
    System.monotonic_time(:millisecond) + @settle_timeout
  end

  defp wait_for_timeout(timeout, deadline) do
    timeout = min(timeout, remaining_timeout(deadline))

    if timeout <= 0 do
      raise ExUnit.AssertionError,
        message: "Timed out waiting for ReqTestSite requests to settle"
    end

    receive do
    after
      timeout -> :ok
    end
  end

  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
