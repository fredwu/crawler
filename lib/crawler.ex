defmodule Crawler do
  use Application

  alias Crawler.{Options, Store, WorkerSupervisor, Worker}

  def start(_type, _args) do
    Store.init
    WorkerSupervisor.start_link()
  end

  def crawl(url, opts \\ []) do
    opts = opts |> Options.assign_defaults |> Options.assign_url(url)

    {:ok, worker} = WorkerSupervisor.start_child(opts)

    Worker.cast(worker, opts)
  end
end
