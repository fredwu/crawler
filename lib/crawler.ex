defmodule Crawler do
  use Application

  alias Crawler.Options

  def start(_type, _args) do
    Crawler.Store.init
    Crawler.WorkerSupervisor.start_link()
  end

  def crawl(url, opts \\ []) do
    opts = opts |> Options.assign_defaults |> Options.assign_url(url)

    {:ok, worker} = Crawler.WorkerSupervisor.start_child(opts)

    Crawler.Worker.cast(worker, opts)
  end
end
