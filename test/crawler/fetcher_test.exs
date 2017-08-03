defmodule Crawler.FetcherTest do
  use Crawler.TestCase, async: true

  alias Crawler.{Fetcher, Store}

  doctest Fetcher

  test "success", %{bypass: bypass, url: url} do
    Bypass.expect_once bypass, "GET", "/", fn (conn) ->
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end

    Fetcher.fetch(url: url, level: 0)

    page = Store.find(url)

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
    refute Store.find(url).body
  end

  test "failure: timeout", %{bypass: bypass, url: url} do
    url = "#{url}/timeout"

    Bypass.expect_once bypass, "GET", "/timeout", fn (conn) ->
      :timer.sleep(5)
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end

    fetcher = Fetcher.fetch(url: url, level: 0, timeout: 1)
    :timer.sleep(10)

    assert fetcher == {:error, "Failed to fetch #{url}, reason: timeout"}
    refute Store.find(url).body
  end

  test "failure: unable to write", %{bypass: bypass, url: url, path: path} do
    url = "#{url}/fail.html"

    Bypass.expect_once bypass, "GET", "/fail.html", fn (conn) ->
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end

    fetcher = Fetcher.fetch(url: url, level: 0, save_to: "nope")

    assert {:error, "Cannot write to file nope/#{path}/fail.html, reason: enoent"} == fetcher
  end

  test "snap /page.html", %{bypass: bypass, url: url, path: path} do
    url = "#{url}/page.html"

    Bypass.expect_once bypass, "GET", "/page.html", fn (conn) ->
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end

    Fetcher.fetch(url: url, level: 0, save_to: tmp("fetcher"))

    wait fn ->
      assert {:ok, "<html>200</html>"} == File.read(tmp("fetcher/#{path}", "page.html"))
    end
  end
end
