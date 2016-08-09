defmodule Crawler.Worker.FetcherTest do
  use Crawler.TestCase, async: true

  alias Crawler.Worker.Fetcher

  doctest Crawler.Worker.Fetcher

  test ".fetch_page", %{bypass: bypass, url: url} do
    Bypass.expect bypass, fn (conn) ->
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end

    assert Fetcher.fetch_page(url) == "<html>200</html>"
  end
end
