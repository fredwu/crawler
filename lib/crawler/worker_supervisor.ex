defmodule Crawler.WorkerSupervisor do
  @moduledoc """
  A supervisor for dynamically starting workers.
  """

  use Supervisor

  alias Crawler.Worker

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def start_child(args) do
    Supervisor.start_child(__MODULE__, [args])
  end

  def init(_args) do
    Supervisor.init([Worker], strategy: :simple_one_for_one)
  end
end
