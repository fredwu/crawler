defmodule Crawler.Worker.Fetcher do
  @fetch_opts [
    follow_redirect: true,
    max_redirect:    5
  ]

  def fetch(opts) do
    url = opts[:url]

    unless already_fetched?(url) do
      url |> store_url |> fetch_url
    end
  end

  defp fetch_url(url) do
    case HTTPoison.get(url, [], @fetch_opts) do
      {:ok, %{status_code: 200, body: body}} -> store_fetched_page(url, body)
      _                                      -> nil
    end
  end

  defp already_fetched?(url) do
    !!Crawler.Store.find(url)
  end

  defp store_url(url) do
    Crawler.Store.add(url)
  end

  defp store_fetched_page(url, body) do
    Crawler.Store.add_body(url, body)
  end
end
