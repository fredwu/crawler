defmodule Crawler.Dispatcher do
  def dispatch(request, opts) do
    case request do
      {_, _link, _, url} -> Crawler.crawl(url, opts)
      {_, url}           -> Crawler.crawl(url, opts)
    end
  end
end
