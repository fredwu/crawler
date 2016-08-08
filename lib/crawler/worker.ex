defmodule Crawler.Worker do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def handle_cast(_req, state) do
    {:noreply, state}
  end

  def cast(pid, term \\ []) do
    GenServer.cast(pid, term)
  end
end
