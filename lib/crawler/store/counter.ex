defmodule Crawler.Store.Counter do
  use GenServer

  def inc(pid) when is_pid(pid) do
    GenServer.call(pid, :inc)
  end

  def count(pid) when is_pid(pid) do
    GenServer.call(pid, :count)
  end

  def reset(pid) when is_pid(pid) do
    GenServer.call(pid, :reset)
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, 0, opts)
  end

  def init(args) do
    {:ok, args}
  end

  def handle_call(:inc, _from, state) do
    count = state + 1
    {:reply, count, count}
  end

  def handle_call(:count, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, 0, 0}
  end
end
