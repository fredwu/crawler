defmodule Crawler.Store.Counter do
  use Agent

  def start_link(_args) do
    Agent.start_link(fn -> 0 end, name: __MODULE__)
  end

  def value do
    Agent.get(__MODULE__, & &1)
  end

  def inc do
    Agent.update(__MODULE__, &(&1 + 1))
  end

  def reset do
    Agent.update(__MODULE__, fn _ -> 0 end)
  end
end
