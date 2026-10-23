defmodule Crawler.Parser.SitemapIngestTest do
  use ExUnit.Case, async: false

  alias Crawler.Limits
  alias Crawler.Parser
  alias Crawler.Store.Page

  test "standalone and managed feeds propagate ingestion limits without calling the scraper" do
    body =
      "<rss><channel><item><link>/one</link></item><item><link>/two</link></item></channel></rss>"

    scope = make_ref()
    on_exit(fn -> Crawler.Store.dispose_scope(scope) end)

    for generation <- [nil, Crawler.Store.generation(scope)],
        {limit, value} <- [max_body: 0, max_control_entries: 1] do
      opts =
        Limits.defaults()
        |> Map.merge(%{
          url: "https://example.test/feed.xml",
          content_type: "application/rss+xml",
          html_tag: "a",
          scraper: Crawler.Scraper,
          generation: generation,
          scope: scope
        })
        |> Map.put(limit, value)

      assert Parser.parse(%Page{body: body, opts: opts}) == {:error, {:limit, limit}}
    end
  end
end
