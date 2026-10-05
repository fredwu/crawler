defmodule Crawler.Example.GoogleSearch.ScraperTest do
  use ExUnit.Case, async: false

  alias Crawler.Example.GoogleSearch.Data
  alias Crawler.Example.GoogleSearch.Scraper
  alias Crawler.Store.Page

  @body """
  <div id="repository-container-header"><strong><a>crawler</a></strong></div>
  <div class="Layout-sidebar"><p class="f4"> A web crawler. </p></div>
  """

  setup do
    initial = %{"kept" => %{url: "https://github.com/kept/project", desc: "Existing project."}}

    data =
      start_supervised!(%{
        id: Data,
        start: {Agent, :start_link, [fn -> initial end, [name: Data]]}
      })

    %{data: data, initial: initial}
  end

  test "scrapes only the GitHub host and preserves existing entries", %{
    data: data,
    initial: initial
  } do
    for url <- [
          "https://github.com/fredwu/crawler",
          "HTTPS://GITHUB.COM./fredwu/crawler",
          "https://github.com:8443/fredwu/crawler"
        ] do
      page = %Page{url: url, body: @body}

      assert {:ok, ^page} = Scraper.scrape(page)

      assert Agent.get(data, & &1) ==
               Map.put(initial, "crawler", %{url: url, desc: "A web crawler."})
    end
  end

  test "leaves other hosts and credentials untouched when called directly", %{
    data: data,
    initial: initial
  } do
    for url <- [
          "https://github.com.evil.test/project",
          "https://github.com@evil.test/project",
          "https://evil.test@github.com/project",
          "https://github.com../project",
          "https://www.google.com/search",
          "https://api.github.com/project",
          "http://github.com/project",
          "https://github.com:invalid/project",
          "/github.com/project",
          nil
        ] do
      page = %Page{url: url, body: @body}

      assert {:ok, ^page} = Scraper.scrape(page)
      assert Agent.get(data, & &1) == initial
    end
  end

  test "does not parse the body of a rejected host", %{data: data, initial: initial} do
    page = %Page{url: "https://github.com.evil.test/project", body: :not_html}

    assert {:ok, ^page} = Scraper.scrape(page)
    assert Agent.get(data, & &1) == initial
  end
end
