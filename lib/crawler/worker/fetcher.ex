defmodule Crawler.Worker.Fetcher do
  @fetch_opts [
    follow_redirect: true,
    max_redirect:    5
  ]

  def fetch(opts) do
    fetch_page(opts[:url])
  end

  def fetch_page(url) do
    case HTTPoison.get(url, [], @fetch_opts) do
      {:ok, %{status_code: 200, body: body}} ->
        store_fetched_page(url, body)
      _ ->
        false
    end
  end

  def store_fetched_page(url, body) do
    CrawlerDB.Page.add(0, url, body)
  end
end
