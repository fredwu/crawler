defmodule Crawler do
  use Application

  def start(_type, _args) do
    Crawler.Store.init
    Crawler.WorkerSupervisor.start_link()
  end

  def crawl(url, opts \\ []) do
    opts = opts ++ [url: url]

    {:ok, worker} = Crawler.WorkerSupervisor.start_child(opts)

    Crawler.Worker.cast(worker, opts)
  end
end
