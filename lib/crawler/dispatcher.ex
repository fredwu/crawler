defmodule Crawler.Dispatcher do
  @moduledoc """
  Dispatches requests to a queue for crawling.
  """

  @doc """
  Takes the `request` argument which is a tuple containing either:

  - `{_, link, _, url}` when it's a link that got transformed into a URL
  - `{_, url}` when it's a URL already

  And issues `Crawler.crawl/2` to initiate the crawl.

  Response data from the parent page is removed first. A linked page must not
  keep the parent's redirect target or response headers.
  """
  def dispatch(request, opts) do
    opts =
      opts
      |> Enum.into(%{})
      |> Map.drop([
        :alias_url,
        :alias_created,
        :alias_candidate,
        :headers,
        :content_type,
        :referrer_url,
        :robots_nofollow,
        :before_publish
      ])

    case request do
      {_, _link, _, url} -> Crawler.crawl(url, opts)
      {_, url} -> Crawler.crawl(url, opts)
    end
  end
end
