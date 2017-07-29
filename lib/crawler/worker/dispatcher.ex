defmodule Crawler.Worker.Dispatcher do
  def dispatch(request, opts) do
    case request do
      {_, url} -> Crawler.crawl(url, opts)
      _        -> nil
    end
  end
end
