defmodule Crawler.WorkerSupervisor do
  use Supervisor

  def init(_args) do
    children = [
      worker(Crawler.Worker, [], restart: :transient)
    ]

    supervise(children, strategy: :simple_one_for_one)
  end

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def start_child(args \\ []) do
    Supervisor.start_child(__MODULE__, [args])
  end
end
