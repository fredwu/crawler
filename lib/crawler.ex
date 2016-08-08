defmodule Crawler do
  use Application

  def start(_type, _args) do
    Crawler.Supervisor.start_link()
  end

  def crawl(url, opts \\ []) do
    opts = opts ++ [url: url]

    {:ok, worker} = Crawler.Supervisor.start_child(opts)

    Crawler.Worker.cast(worker, opts)
  end
end
