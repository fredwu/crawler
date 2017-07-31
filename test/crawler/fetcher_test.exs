defmodule Crawler.FetcherTest do
  use Crawler.TestCase, async: true

  alias Crawler.Fetcher

  doctest Fetcher

  test "success", %{bypass: bypass, url: url} do
    Bypass.expect_once bypass, "GET", "/", fn (conn) ->
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end

    Fetcher.fetch(url: url, level: 0)

    page = Crawler.Store.find(url)

    assert page.url  == url
    assert page.body == "<html>200</html>"
  end

  test "failure: 500", %{bypass: bypass, url: url} do
    url = "#{url}/500"

    Bypass.expect_once bypass, "GET", "/500", fn (conn) ->
      Plug.Conn.resp(conn, 500, "<html>500</html>")
    end

    fetcher = Fetcher.fetch(url: url, level: 0)

    assert fetcher == {:error, "Failed to fetch #{url}, status code: 500"}
    refute Crawler.Store.find(url).body
  end

  test "failure: timeout", %{bypass: bypass, url: url} do
    url = "#{url}/timeout"

    Bypass.expect_once bypass, "GET", "/timeout", fn (conn) ->
      :timer.sleep(2)
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end

    fetcher = Fetcher.fetch(url: url, level: 0, timeout: 1)
    :timer.sleep(10)

    assert fetcher == {:error, "Failed to fetch #{url}, reason: timeout"}
    refute Crawler.Store.find(url).body
  end
end
