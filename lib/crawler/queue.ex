defmodule Crawler.Queue do
  @moduledoc """
  Owns the queue processes a crawl starts.

  The crawl supervisor starts this process. It starts the queue and shuts those
  processes down when the crawl stops, including the worker pool and the rate
  limiter. A queue created outside Crawler has no owner, and `Crawler.stop/1`
  leaves it running. Stopping the scope that started a queue still shuts that
  queue down.
  """

  use GenServer

  alias Crawler.Store

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def feeder(pid) when is_pid(pid), do: GenServer.call(pid, :feeder)

  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:links, existing} = Process.info(self(), :links)

    try do
      {:ok, feeder} =
        OPQ.start_link(
          worker: Crawler.Dispatcher.Worker,
          workers: opts[:workers],
          interval: opts[:interval],
          timeout: opts[:timeout]
        )

      :ok = Store.attach_owner(feeder, self(), opts[:scope])
      {:links, links} = Process.info(self(), :links)
      {:ok, %{feeder: feeder, children: links -- existing}}
    catch
      kind, reason ->
        shutdown_started(existing)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @impl true
  def handle_call(:feeder, _from, state), do: {:reply, state.feeder, state}

  @impl true
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{feeder: feeder, children: children}) do
    Store.release_queue(feeder)
    shutdown_children(children, feeder)
    :ok
  catch
    :exit, _ ->
      shutdown_children(children, feeder)
      :ok
  end

  # `init/1` does not run `terminate/2` when it fails. Shut down anything
  # already started; the worker supervisor traps exits and would otherwise stay up.
  defp shutdown_started(existing) do
    {:links, links} = Process.info(self(), :links)
    shutdown_children(links -- existing, nil)
  catch
    _, _ -> :ok
  end

  # Stop the worker supervisor before the feeder. It traps exits. A killed
  # worker does not run its `after` clause; callers clear slots before stop.
  defp shutdown_children(children, feeder) do
    children = Enum.uniq(children)
    {supervisors, rest} = Enum.split_with(children, &worker_supervisor?/1)
    rest = List.delete(rest, feeder)

    Enum.each(supervisors, &shutdown_one(&1, 2_000))
    Enum.each(rest, &shutdown_one(&1, 2_000))
    shutdown_one(feeder, 2_000)
  end

  defp worker_supervisor?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> match?({:supervisor, _, _}, dictionary[:"$initial_call"])
      _ -> false
    end
  end

  defp shutdown_one(pid, timeout) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)

      try do
        GenServer.stop(pid, :shutdown, timeout)
      catch
        :exit, _ -> :ok
      end

      if Process.alive?(pid) do
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          1_000 ->
            Process.demonitor(ref, [:flush])
            :ok
        end
      else
        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          0 -> :ok
        end
      end
    else
      :ok
    end
  end

  defp shutdown_one(_pid, _timeout), do: :ok
end
