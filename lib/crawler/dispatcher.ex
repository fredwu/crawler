defmodule Crawler.Dispatcher do
  @moduledoc """
  Dispatches `Crawler.crawl/2` for recursive crawling.
  """

  def dispatch(request, opts) do
    case request do
      {_, _link, _, url} -> Crawler.crawl(url, opts)
      {_, url}           -> Crawler.crawl(url, opts)
    end
  end
end
