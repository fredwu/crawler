defmodule Crawler.Supervisor do
  alias Experimental.DynamicSupervisor

  use DynamicSupervisor

  def init(_args) do
    children = [
      worker(Crawler.Worker, [], restart: :temporary)
    ]

    {:ok, children, strategy: :one_for_one}
  end

  def start_link do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def start_child(args \\ []) do
    DynamicSupervisor.start_child(__MODULE__, [args])
  end
end
