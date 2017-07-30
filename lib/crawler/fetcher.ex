defmodule Crawler.Fetcher do
  alias Crawler.{Fetcher.Policer, Fetcher.Recorder, Store.Page}

  @fetch_opts [
    follow_redirect: true,
    max_redirect:    5
  ]

  def fetch(opts) do
    with {:ok, opts} <- Policer.police(opts),
         _           <- Recorder.store_url(opts),
         opts        <- Recorder.store_url_level(opts)
    do
      fetch_url(opts)
    end
  end

  defp fetch_url(opts) do
    case HTTPoison.get(opts[:url], [], @fetch_opts) do
      {:ok, %{status_code: 200, body: body}} ->
        Recorder.store_page(opts[:url], body)
        return_page(body, opts)
      _ -> nil
    end
  end

  defp return_page(body, opts) do
    %{
      page: %Page{url: opts[:url], body: body},
      opts: opts
    }
  end
end
