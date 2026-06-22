defmodule Crawler.FetcherTest do
  use Crawler.TestCase, async: true

  alias Crawler.Fetcher
  alias Crawler.Fetcher.Modifier
  alias Crawler.Fetcher.Retrier
  alias Crawler.Fetcher.UrlFilter
  alias Crawler.Store

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

  test "success", %{site: site, url: url, req_options: req_options} do
    url = "#{url}/fetcher/200"

    ReqTestSite.expect_once(site, "GET", "/fetcher/200", fn conn ->
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end)

    @defaults
    |> Map.merge(%{url: url, req_options: req_options})
    |> Fetcher.fetch()

    page = Store.find({url, nil})

    assert page.url == url
    assert page.body == "<html>200</html>"
  end

  test "success: 301", %{site: site, url: url, req_options: req_options} do
    ReqTestSite.expect_once(site, "GET", "/fetcher/301", fn conn ->
      conn
      |> Plug.Conn.merge_resp_headers([{"location", "#{url}/fetcher/301_200"}])
      |> Plug.Conn.resp(301, "")
    end)

    ReqTestSite.expect_once(site, "GET", "/fetcher/301_200", fn conn ->
      Plug.Conn.resp(conn, 200, "<html>301_200</html>")
    end)

    url = "#{url}/fetcher/301"

    @defaults
    |> Map.merge(%{url: url, req_options: req_options})
    |> Fetcher.fetch()

    page = Store.find({url, nil})

    assert page.url == url
    assert page.body == "<html>301_200</html>"
  end

  test "failure: 500", %{site: site, url: url, req_options: req_options} do
    url = "#{url}/fetcher/500"

    ReqTestSite.expect_once(site, "GET", "/fetcher/500", fn conn ->
      Plug.Conn.resp(conn, 500, "<html>500</html>")
    end)

    fetcher =
      @defaults
      |> Map.merge(%{url: url, req_options: req_options})
      |> Fetcher.fetch()

    assert fetcher == {:warn, "Failed to fetch #{url}, status code: 500"}
    refute Store.find({url, nil}).body
  end

  test "failure: timeout", %{site: site, url: url, req_options: req_options} do
    url = "#{url}/fetcher/timeout"

    ReqTestSite.expect_once(site, "GET", "/fetcher/timeout", fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    fetcher =
      @defaults
      |> Map.merge(%{url: url, timeout: 50, req_options: req_options})
      |> Fetcher.fetch()

    assert fetcher == {:warn, "Failed to fetch #{url}, reason: :timeout"}
    refute Store.find({url, nil}).body
  end

  test "failure: too many redirects", %{site: site, url: url, req_options: req_options} do
    url = "#{url}/fetcher/too_many_redirects"

    ReqTestSite.expect_once(site, "GET", "/fetcher/too_many_redirects", fn conn ->
      Req.Test.redirect(conn, to: "/fetcher/too_many_redirects")
    end)

    fetcher =
      @defaults
      |> Map.merge(%{url: url, req_options: Keyword.merge(req_options, max_redirects: 0)})
      |> Fetcher.fetch()

    assert fetcher == {:warn, "Failed to fetch #{url}, reason: too many redirects (0)"}
    refute Store.find({url, nil}).body
  end

  test "failure: retries", %{site: site, url: url, req_options: req_options} do
    url = "#{url}/fetcher/retries"

    ReqTestSite.expect(site, "GET", "/fetcher/retries", fn conn ->
      Plug.Conn.resp(conn, 500, "<html>500</html>")
    end)

    wait(fn ->
      fetcher =
        @defaults
        |> Map.merge(%{url: url, timeout: 100, retrier: Retrier, req_options: req_options})
        |> Fetcher.fetch()

      assert fetcher == {:warn, "Failed to fetch #{url}, status code: 500"}
      refute Store.find({url, nil}).body
    end)
  end

  test "failure: unable to write", %{site: site, url: url, path: path, req_options: req_options} do
    url = "#{url}/fetcher/fail.html"

    ReqTestSite.expect_once(site, "GET", "/fetcher/fail.html", fn conn ->
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end)

    fetcher =
      @defaults
      |> Map.merge(%{url: url, save_to: "nope", req_options: req_options})
      |> Fetcher.fetch()

    assert {:error, "Cannot write to file nope/#{path}/fetcher/fail.html, reason: enoent"} ==
             fetcher
  end

  test "snap /fetcher/page.html", %{
    site: site,
    url: url,
    path: path,
    req_options: req_options
  } do
    url = "#{url}/fetcher/page.html"

    ReqTestSite.expect_once(site, "GET", "/fetcher/page.html", fn conn ->
      Plug.Conn.resp(conn, 200, "<html>200</html>")
    end)

    @defaults
    |> Map.merge(%{url: url, save_to: tmp("fetcher"), req_options: req_options})
    |> Fetcher.fetch()

    wait(fn ->
      assert {:ok, "<html>200</html>"} == File.read(tmp("fetcher/#{path}/fetcher", "page.html"))
    end)
  end
end
