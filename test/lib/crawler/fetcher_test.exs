defmodule Crawler.FetcherTest do
  use Crawler.TestCase, async: true

  alias Crawler.Fetcher
  alias Crawler.Fetcher.Modifier
  alias Crawler.Fetcher.Retrier
  alias Crawler.Fetcher.UrlFilter
  alias Crawler.Store

  @moduletag capture_log: true

  doctest Fetcher

  defmodule DummyRetrier do
    @behaviour Retrier.Spec

    def perform(fetch_url, _opts), do: fetch_url.()
  end

  @defaults %{
    depth: 0,
    retries: 2,
    url_filter: UrlFilter,
    modifier: Modifier,
    retrier: DummyRetrier,
    store: Store,
    html_tag: "a"
  }

  test "success", %{bypass: bypass, url: url} do
    url = "#{url}/fetcher/200"

    Bypass.expect_once(bypass, "GET", "/fetcher/200", fn conn ->
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end)

    @defaults
    |> Map.merge(%{url: url})
    |> Fetcher.fetch()

    page = Store.find({url, nil})

    assert page.url == url
    assert page.body == "<html>200</html>"
  end

  test "success: 301", %{bypass: bypass, url: url} do
    Bypass.expect_once(bypass, "GET", "/fetcher/301", fn conn ->
      conn
      |> Plug.Conn.merge_resp_headers([{"location", "#{url}/fetcher/301_200"}])
      |> Plug.Conn.resp(301, "")
    end)

    Bypass.expect_once(bypass, "GET", "/fetcher/301_200", fn conn ->
      Plug.Conn.resp(conn, 200, "<html>301_200</html>")
    end)

    url = "#{url}/fetcher/301"

    @defaults
    |> Map.merge(%{url: url})
    |> Fetcher.fetch()

    page = Store.find({url, nil})

    assert page.url == url
    assert page.body == "<html>301_200</html>"
  end

  test "failure: 500", %{bypass: bypass, url: url} do
    url = "#{url}/fetcher/500"

    Bypass.expect_once(bypass, "GET", "/fetcher/500", fn conn ->
      Plug.Conn.resp(conn, 500, "<html>500</html>")
    end)

    fetcher =
      @defaults
      |> Map.merge(%{url: url})
      |> Fetcher.fetch()

    assert fetcher == {:warn, "Failed to fetch #{url}, status code: 500"}
    refute Store.find({url, nil}).body
  end

  test "failure: timeout", %{bypass: bypass, url: url} do
    url = "#{url}/fetcher/timeout"

    Bypass.expect_once(bypass, "GET", "/fetcher/timeout", fn conn ->
      Process.flag(:trap_exit, true)
      :timer.sleep(100)
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end)

    fetcher =
      @defaults
      |> Map.merge(%{url: url, timeout: 50})
      |> Fetcher.fetch()

    assert fetcher == {:warn, "Failed to fetch #{url}, reason: :timeout"}
    refute Store.find({url, nil}).body
  end

  test "failure: retries", %{bypass: bypass, url: url} do
    url = "#{url}/fetcher/retries"

    Bypass.expect(bypass, "GET", "/fetcher/retries", fn conn ->
      Plug.Conn.resp(conn, 500, "<html>500</html>")
    end)

    wait(fn ->
      fetcher =
        @defaults
        |> Map.merge(%{url: url, timeout: 100, retrier: Retrier})
        |> Fetcher.fetch()

      assert fetcher == {:warn, "Failed to fetch #{url}, status code: 500"}
      refute Store.find({url, nil}).body
    end)
  end

  test "failure: unable to write", %{bypass: bypass, url: url, path: path} do
    url = "#{url}/fetcher/fail.html"

    Bypass.expect_once(bypass, "GET", "/fetcher/fail.html", fn conn ->
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end)

    fetcher =
      @defaults
      |> Map.merge(%{url: url, save_to: "nope"})
      |> Fetcher.fetch()

    assert {:error, "Cannot write to file nope/#{path}/fetcher/fail.html, reason: enoent"} ==
             fetcher
  end

  test "snap /fetcher/page.html", %{bypass: bypass, url: url, path: path} do
    url = "#{url}/fetcher/page.html"

    Bypass.expect_once(bypass, "GET", "/fetcher/page.html", fn conn ->
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end)

    @defaults
    |> Map.merge(%{url: url, save_to: tmp("fetcher")})
    |> Fetcher.fetch()

    wait(fn ->
      assert {:ok, "<html>200</html>"} == File.read(tmp("fetcher/#{path}/fetcher", "page.html"))
    end)
  end
end
