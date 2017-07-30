defmodule Crawler.Worker.Fetcher.Recorder do
  alias Crawler.Store

  def store_url(opts) do
    Store.add(opts[:url])
  end

  def store_url_level(opts) do
    Keyword.replace(opts, :level, opts[:level] + 1)
  end

  def store_page(url, body) do
    Store.add_body(url, body)
  end
end
