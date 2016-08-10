defmodule Crawler.Worker.FetcherTest do
  use Crawler.TestCase, async: true

  alias Crawler.Worker.Fetcher

  doctest Crawler.Worker.Fetcher

  test ".fetch_page", %{bypass: bypass, url: url} do
    Bypass.expect bypass, fn (conn) ->
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end

    Fetcher.fetch_page(url)

    page = CrawlerDB.Page.find(url)

    assert page.parent_id == 0
    assert page.url       == url
    assert page.body      == "<html>200</html>"
  end
end
