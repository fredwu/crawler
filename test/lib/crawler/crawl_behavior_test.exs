defmodule Crawler.CrawlBehaviorTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  test "keeps pages after the crawl is idle and does not fetch them again", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    page = "#{url}/behavior/stored"

    ReqTestSite.expect_once(site, "GET", "/behavior/stored", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "<html>stored</html>")
    end)

    {:ok, opts} =
      start_crawl(page,
        scope: "stored",
        workers: 1,
        timeout: 50,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)

      assert %Store.Page{url: ^page, body: "<html>stored</html>"} =
               Store.find_processed({page, "stored"})

      assert page in Store.all_urls()
    end)

    {:ok, again} =
      start_crawl(page, scope: "stored", queue: opts[:queue], req_options: req_options)

    wait(fn ->
      refute Crawler.running?(again)
      assert Store.find_processed({page, "stored"})
    end)
  end

  test "a single page is not reported as running after it finishes", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    page = "#{url}/behavior/one"

    ReqTestSite.expect_once(site, "GET", "/behavior/one", fn conn ->
      conn |> Plug.Conn.put_resp_header("content-type", "text/html") |> Plug.Conn.resp(200, "one")
    end)

    {:ok, opts} = start_crawl(page, scope: "one-page", workers: 1, req_options: req_options)

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({page, "one-page"})
    end)
  end

  test "worker limit, pause, and running? follow in-flight fetches", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()

    for path <- ["/behavior/limit/a", "/behavior/limit/b"] do
      ReqTestSite.stub(site, "GET", path, fn conn ->
        send(parent, {:started, path, self()})

        receive do
          :release ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/html")
            |> Plug.Conn.resp(200, path)
        after
          5_000 -> Plug.Conn.resp(conn, 500, "late")
        end
      end)
    end

    {:ok, opts} =
      start_crawl("#{url}/behavior/limit/a",
        scope: "limit",
        workers: 1,
        interval: 0,
        req_options: req_options
      )

    assert_receive {:started, "/behavior/limit/a", first}, 1_000
    assert Crawler.running?(opts)

    {:ok, _second} =
      start_crawl("#{url}/behavior/limit/b",
        scope: "limit",
        queue: opts[:queue],
        workers: 1,
        req_options: req_options
      )

    refute_receive {:started, "/behavior/limit/b", _pid}, 200

    Crawler.pause(opts)
    assert Process.alive?(first)
    refute Crawler.running?(opts)

    Crawler.resume(opts)
    send(first, :release)

    assert_receive {:started, "/behavior/limit/b", second}, 1_000
    assert Crawler.running?(opts)
    send(second, :release)

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.ops_count("limit") == 2
    end)
  end

  test "timeout infinity still crawls", %{site: site, url: url, req_options: req_options} do
    page = "#{url}/behavior/forever"

    ReqTestSite.expect_once(site, "GET", "/behavior/forever", fn conn ->
      conn |> Plug.Conn.put_resp_header("content-type", "text/html") |> Plug.Conn.resp(200, "ok")
    end)

    {:ok, opts} =
      start_crawl(page,
        scope: "forever",
        timeout: :infinity,
        workers: 1,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({page, "forever"})
    end)
  end
end
