defmodule Crawler.Worker.Fetcher do
  alias Crawler.{Store, Store.Page}

  @fetch_opts [
    follow_redirect: true,
    max_redirect:    5
  ]

  def fetch(opts) do
    with {:ok, opts} <- fetchable(opts),
         _           <- store_url(opts),
         opts        <- store_url_level(opts)
    do
      fetch_url(opts)
    end
  end

  defp fetchable(opts) do
    case fetchable_check(opts) do
      true  -> {:ok, opts}
      false -> nil
    end
  end

  defp fetchable_check(opts) do
    within_fetch_level?(opts[:level], opts[:max_levels])
      && not_fetched?(opts[:url])
  end

  defp within_fetch_level?(current_level, max_levels) do
    current_level < max_levels
  end

  defp not_fetched?(url) do
    !Store.find(url)
  end

  defp store_url(opts) do
    Store.add(opts[:url])
  end

  defp store_url_level(opts) do
    case Keyword.has_key?(opts, :level) do
      true  -> Keyword.replace(opts, :level, opts[:level] + 1)
      false -> opts
    end
  end

  defp fetch_url(opts) do
    case HTTPoison.get(opts[:url], [], @fetch_opts) do
      {:ok, %{status_code: 200, body: body}} ->
        store_page(opts[:url], body)
        return_page(body, opts)
      _ -> nil
    end
  end

  defp store_page(url, body) do
    Store.add_body(url, body)
  end

  defp return_page(body, opts) do
    %{
      page: %Page{url: opts[:url], body: body},
      opts: opts
    }
  end
end
