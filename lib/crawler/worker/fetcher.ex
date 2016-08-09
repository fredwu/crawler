defmodule Crawler.Worker.Fetcher do
  def fetch(opts) do
    fetch_page(opts[:url])
  end

  def fetch_page(url) do
    case HTTPoison.get(url, [], [follow_redirect: true, max_redirect: 5]) do
      {:ok, %{status_code: 200, body: body}} -> body
      _ -> false
    end
  end
end
