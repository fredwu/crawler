defmodule Crawler.Worker.Fetcher do
  @fetch_opts [
    follow_redirect: true,
    max_redirect:    5
  ]

  def fetch(opts) do
    url = opts[:url]

    case HTTPoison.get(url, [], @fetch_opts) do
      {:ok, %{status_code: 200, body: body}} ->
        store_fetched_page(url, body)
      _ ->
        nil
    end
  end

  defp store_fetched_page(url, body) do
    Crawler.Store.add(url, body)
  end
end
