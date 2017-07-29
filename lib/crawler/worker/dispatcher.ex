defmodule Crawler.Worker.Dispatcher do
  def dispatch(request) do
    case request do
      {_, url} -> Crawler.crawl(url)
      _        -> nil
    end
  end
end
