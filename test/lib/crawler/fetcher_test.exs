defmodule Crawler.FetcherTest do
  use Crawler.TestCase, async: true

  alias Crawler.{Fetcher, Fetcher.UrlFilter, Fetcher.Retrier, Fetcher.Modifier, Store}

  doctest Fetcher

  defmodule DummyRetrier do
    @behaviour Retrier.Spec

    def perform(fetch_url, _opts), do: fetch_url.()
  end

  @defaults %{depth: 0, url_filter: UrlFilter, modifier: Modifier, retrier: DummyRetrier, html_tag: "a"}

  test "success", %{bypass: bypass, url: url} do
    url = "#{url}/fetcher/200"

    Bypass.expect_once bypass, "GET", "/fetcher/200", fn (conn) ->
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end

    @defaults
    |> Map.merge(%{url: url})
    |> Fetcher.fetch

    page = Store.find(url)

    assert page.url  == url
    assert page.body == "<html>200</html>"
  end

  test "failure: 500", %{bypass: bypass, url: url} do
    url = "#{url}/fetcher/500"

    Bypass.expect_once bypass, "GET", "/fetcher/500", fn (conn) ->
      Plug.Conn.resp(conn, 500, "<html>500</html>")
    end

    fetcher = @defaults
    |> Map.merge(%{url: url})
    |> Fetcher.fetch

    assert fetcher == {:error, "Failed to fetch #{url}, status code: 500"}
    refute Store.find(url).body
  end

  test "failure: timeout", %{bypass: bypass, url: url} do
    url = "#{url}/fetcher/timeout"

    Bypass.expect_once bypass, "GET", "/fetcher/timeout", fn (conn) ->
      :timer.sleep(10)
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end

    wait fn ->
      fetcher = @defaults
      |> Map.merge(%{url: url, timeout: 5})
      |> Fetcher.fetch

      assert fetcher == {:error, "Failed to fetch #{url}, reason: timeout"}
      refute Store.find(url).body
    end
  end

  test "failure: retries", %{bypass: bypass, url: url} do
    url = "#{url}/fetcher/retries"

    Bypass.expect bypass, "GET", "/fetcher/retries", fn (conn) ->
      Plug.Conn.resp(conn, 500, "<html>500</html>")
    end

    wait fn ->
      fetcher = @defaults
      |> Map.merge(%{url: url, timeout: 100, retrier: Retrier})
      |> Fetcher.fetch

      assert fetcher == {:error, "Failed to fetch #{url}, status code: 500"}
      refute Store.find(url).body
    end
  end

  test "failure: unable to write", %{bypass: bypass, url: url, path: path} do
    url = "#{url}/fetcher/fail.html"

    Bypass.expect_once bypass, "GET", "/fetcher/fail.html", fn (conn) ->
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end

    fetcher = @defaults
    |> Map.merge(%{url: url, save_to: "nope"})
    |> Fetcher.fetch

    assert {:error, "Cannot write to file nope/#{path}/fetcher/fail.html, reason: enoent"} == fetcher
  end

  test "snap /fetcher/page.html", %{bypass: bypass, url: url, path: path} do
    url = "#{url}/fetcher/page.html"

    Bypass.expect_once bypass, "GET", "/fetcher/page.html", fn (conn) ->
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end

    @defaults
    |> Map.merge(%{url: url, save_to: tmp("fetcher")})
    |> Fetcher.fetch

    wait fn ->
      assert {:ok, "<html>200</html>"} == File.read(tmp("fetcher/#{path}/fetcher", "page.html"))
    end
  end
end
