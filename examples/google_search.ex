defmodule Crawler.Example.GoogleSearch do
  @moduledoc """
  This example performs a Google search, then scrapes the results to find Github
  projects and output their name and description.

  Example output:

      Crawler.Example.GoogleSearch.run() #=> %{
        "crawler" => %{
          desc: "A high performance web crawler / scraper in Elixir.",
          url: "https://github.com/fredwu/crawler"
        },
        "crawly" => %{
          desc: "Crawly, a high-level web crawling & scraping framework for Elixir.",
          url: "https://github.com/elixir-crawly/crawly"
        },
        "elixir_scraper" => %{
          desc: "Elixir/Hound web scraper example",
          url: "https://github.com/jaydorsey/elixir_scraper"
        },
        "mechanize" => %{
          desc: "Build web scrapers and automate interaction with websites in Elixir with ease!",
          url: "https://github.com/gushonorato/mechanize"
        }
      }
  """

  alias Crawler.Example.GoogleSearch.Data
  alias Crawler.Example.GoogleSearch.Scraper
  alias Crawler.Example.GoogleSearch.UrlFilter

  @site_url "https://www.google.com/search?"
  @search_term "github web scrapers in Elixir"

  def run do
    {:ok, data} = Agent.start_link(fn -> %{} end, name: Data)

    try do
      crawl(data)
    after
      Agent.stop(data)
    end
  end

  defp crawl(data) do
    {:ok, opts} =
      Crawler.crawl(
        search_url(),
        workers: 2,
        max_depths: 2,
        max_pages: 10,
        interval: 80,
        user_agent: "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/118.0",
        scraper: Scraper,
        url_filter: UrlFilter
      )

    try do
      wait(opts, System.monotonic_time(:millisecond) + 5_000)
      results = Agent.get(data, & &1)
      IO.puts(inspect(results))
      results
    after
      Crawler.stop(opts)
    end
  end

  defp search_url do
    @site_url <> URI.encode_query(%{"q" => @search_term})
  end

  defp wait(opts, deadline) do
    if Crawler.running?(opts) do
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        raise "Google search crawl did not finish within 5 seconds"
      end

      Process.sleep(min(remaining, 500))
      wait(opts, deadline)
    else
      :ok
    end
  end
end
