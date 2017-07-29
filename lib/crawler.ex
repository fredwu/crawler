defmodule Crawler do
  use Application

  @max_levels 3

  def start(_type, _args) do
    Crawler.Store.init
    Crawler.WorkerSupervisor.start_link()
  end

  def crawl(url, opts \\ []) do
    opts = opts |> assign_defaults |> assign_url(url)

    {:ok, worker} = Crawler.WorkerSupervisor.start_child(opts)

    Crawler.Worker.cast(worker, opts)
  end

  defp assign_defaults(opts) do
    Keyword.merge([
      max_levels: max_levels(),
    ], opts ++ [level: 0])
  end

  defp assign_url(opts, url) do
    case Keyword.has_key?(opts, :url) do
      true  -> Keyword.replace(opts, :url, url)
      false -> opts ++ [url: url]
    end
  end

  defp max_levels, do: Application.get_env(:crawler, :max_levels) || @max_levels
end
