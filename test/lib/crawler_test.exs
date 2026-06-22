defmodule CrawlerTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  doctest Crawler

  test ".crawl", %{site: site, url: url, req_options: req_options} do
    Store.ops_reset()

    url = "#{url}/crawler"
    linked_url1 = "#{url}/link1"
    linked_url2 = "#{url}/link2"
    linked_url3 = "#{url}/link3"
    linked_url4 = "#{url}/link4"

    ReqTestSite.expect_once(site, "GET", "/crawler", fn conn ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url1}">1</a></html>
        <html><a href="#{linked_url2}">2</a></html>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/crawler/link1", fn conn ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url2}">2</a></html>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/crawler/link2", fn conn ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url3}">3</a></html>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/crawler/link3", fn conn ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url4}">4</a></html>
      """)
    end)

    {:ok, opts} =
      Crawler.crawl(url,
        max_depths: 3,
        workers: 3,
        interval: 100,
        store: Store,
        req_options: req_options
      )

    assert Crawler.running?(opts)

    Crawler.pause(opts)

    refute Crawler.running?(opts)

    assert opts[:workers] == 3

    Crawler.resume(opts)

    assert Crawler.running?(opts)

    wait(fn ->
      assert Store.ops_count() == 4
    end)

    wait(fn ->
      assert %Store.Page{url: ^url, opts: %{workers: 3}} = Store.find_processed({url, nil})

      assert Store.find_processed({linked_url1, nil})
      assert Store.find_processed({linked_url2, nil})
      assert Store.find_processed({linked_url3, nil})
      refute Store.find({linked_url4, nil})

      urls = Crawler.Store.all_urls()

      assert Enum.member?(urls, {url, nil})
      assert Enum.member?(urls, {linked_url1, nil})
      assert Enum.member?(urls, {linked_url2, nil})
      assert Enum.member?(urls, {linked_url3, nil})
      refute Enum.member?(urls, {linked_url4, nil})
    end)

    wait(fn ->
      refute Crawler.running?(opts)
      assert OPQ.info(opts[:queue]) == {:normal, %OPQ.Queue{data: {[], []}}, 3}
    end)
  end

  test ".crawl without a store", %{site: site, url: url, req_options: req_options} do
    url = "#{url}/crawler_without_store"

    ReqTestSite.expect_once(site, "GET", "/crawler_without_store", fn conn ->
      Plug.Conn.resp(conn, 200, "200")
    end)

    {:ok, opts} =
      Crawler.crawl(url,
        max_depths: 1,
        workers: 1,
        interval: 100,
        store: nil,
        req_options: req_options
      )

    wait(fn ->
      assert %Store.Page{url: ^url, body: nil, opts: nil} = Store.find_processed({url, nil})
    end)

    wait(fn ->
      assert OPQ.info(opts[:queue]) == {:normal, %OPQ.Queue{data: {[], []}}, 1}
    end)
  end

  test ".crawl with max_pages", %{site: site, url: url, req_options: req_options} do
    Store.ops_reset()

    url = "#{url}/crawler_with_max_pages"
    linked_url1 = "#{url}/link1"
    linked_url2 = "#{url}/link2"
    linked_url3 = "#{url}/link3"
    linked_url4 = "#{url}/link4"
    linked_url5 = "#{url}/link5"

    ReqTestSite.expect_once(site, "GET", "/crawler_with_max_pages", fn conn ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url1}">1</a></html>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/crawler_with_max_pages/link1", fn conn ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url2}">2</a></html>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/crawler_with_max_pages/link2", fn conn ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url3}">3</a></html>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/crawler_with_max_pages/link3", fn conn ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url4}">4</a></html>
        <html><a href="#{linked_url5}">5</a></html>
      """)
    end)

    {:ok, opts} =
      Crawler.crawl(url,
        max_depths: 4,
        force: true,
        workers: 1,
        max_pages: 4,
        interval: 20,
        req_options: req_options
      )

    wait(fn ->
      assert Store.ops_count() == 4
    end)

    wait(fn ->
      assert Store.find_processed({url, opts[:scope]})
      assert Store.find_processed({linked_url1, opts[:scope]})
      assert Store.find_processed({linked_url2, opts[:scope]})
      assert Store.find_processed({linked_url3, opts[:scope]})
      refute Store.find({linked_url4, opts[:scope]})
      refute Store.find({linked_url5, opts[:scope]})
    end)

    wait(fn ->
      assert OPQ.info(opts[:queue]) == {:normal, %OPQ.Queue{data: {[], []}}, 1}
    end)
  end

  test ".crawl with an existing queue", %{site: site, url: url, req_options: req_options} do
    Store.ops_reset()

    url = "#{url}/crawler_with_queue"
    linked_url1 = "#{url}/link1"
    linked_url2 = "#{url}/link2"
    linked_url3 = "#{url}/link3"
    linked_url4 = "#{url}/link4"

    ReqTestSite.expect_once(site, "GET", "/crawler_with_queue/link1", fn conn ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url2}">2</a></html>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/crawler_with_queue/link2", fn conn ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url3}">3</a></html>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/crawler_with_queue/link3", fn conn ->
      Plug.Conn.resp(conn, 200, """
        <html>ok</html>
      """)
    end)

    {:ok, queue} = OPQ.init(worker: Crawler.Dispatcher.Worker, workers: 2, interval: 100)

    {:ok, opts1} =
      Crawler.crawl(linked_url1, store: Store, queue: queue, req_options: req_options)

    {:ok, opts2} =
      Crawler.crawl(linked_url2, store: Store, queue: queue, req_options: req_options)

    wait(fn ->
      assert Store.ops_count() == 3
    end)

    wait(fn ->
      assert Store.find_processed({linked_url1, nil})
      assert Store.find_processed({linked_url2, nil})
      assert Store.find_processed({linked_url3, nil})
      refute Store.find_processed({linked_url4, nil})

      urls = Crawler.Store.all_urls()

      assert Enum.member?(urls, {linked_url1, nil})
      assert Enum.member?(urls, {linked_url2, nil})
      assert Enum.member?(urls, {linked_url3, nil})
      refute Enum.member?(urls, {linked_url4, nil})
    end)

    wait(fn ->
      assert OPQ.info(opts1[:queue]) == {:normal, %OPQ.Queue{data: {[], []}}, 2}
      assert OPQ.info(opts2[:queue]) == {:normal, %OPQ.Queue{data: {[], []}}, 2}
    end)
  end

  test ".crawl forced", %{site: site, url: url, req_options: req_options} do
    Store.ops_reset()

    url = "#{url}/crawler_forced"
    linked_url1 = "#{url}/link1"
    linked_url2 = "#{url}/link2"

    ReqTestSite.expect(site, "GET", "/crawler_forced", fn conn ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url1}">1</a></html>
        <html><a href="#{linked_url1}">1</a></html>
      """)
    end)

    ReqTestSite.expect(site, "GET", "/crawler_forced/link1", fn conn ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url2}">2</a></html>
      """)
    end)

    ReqTestSite.expect(site, "GET", "/crawler_forced/link2", fn conn ->
      Plug.Conn.resp(conn, 200, """
        <html>ok</html>
      """)
    end)

    {:ok, opts1} =
      Crawler.crawl(url, force: true, workers: 1, interval: 100, req_options: req_options)

    {:ok, opts2} =
      Crawler.crawl(url, force: true, workers: 2, interval: 100, req_options: req_options)

    refute opts1[:scope] == opts2[:scope]

    wait(fn ->
      assert Store.find_processed({url, opts1[:scope]})
      assert Store.find_processed({url, opts2[:scope]})
      assert Store.find_processed({linked_url1, opts1[:scope]})
      assert Store.find_processed({linked_url1, opts2[:scope]})
      assert Store.find_processed({linked_url2, opts1[:scope]})
      assert Store.find_processed({linked_url2, opts2[:scope]})

      assert Store.ops_count() >= 6
      assert Store.ops_count() <= 10

      assert OPQ.info(opts1[:queue]) == {:normal, %OPQ.Queue{data: {[], []}}, 1}
      assert OPQ.info(opts2[:queue]) == {:normal, %OPQ.Queue{data: {[], []}}, 2}
    end)
  end

  test ".crawl stopped", %{site: site, url: url, req_options: req_options} do
    url = "#{url}/stop"
    linked_url = "#{url}/stop1"

    ReqTestSite.expect_once(site, "GET", "/stop", fn conn ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url}">1</a></html>
      """)
    end)

    {:ok, opts} = Crawler.crawl(url, workers: 1, interval: 500, req_options: req_options)

    Process.sleep(200)

    queue = opts[:queue]

    ExUnit.CaptureLog.capture_log(fn ->
      Crawler.stop(opts)

      wait(fn ->
        refute Process.alive?(queue)
      end)

      refute_receive {:opq_shutdown, _}, 50
    end)

    refute Store.find({linked_url, nil})
  end
end
