defmodule CrawlerTest do
  use Crawler.TestCase, async: true

  alias Crawler.Store

  doctest Crawler

  test ".crawl", %{bypass: bypass, url: url} do
    linked_url1 = "#{url}/link1"
    linked_url2 = "#{url}/link2"
    linked_url3 = "#{url}/link3"
    linked_url4 = "#{url}/link4"

    Bypass.expect_once bypass, "GET", "/", fn (conn) ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url1}">1</a></html>
        <html><a href="#{linked_url2}">2</a></html>
      """)
    end

    Bypass.expect_once bypass, "GET", "/link1", fn (conn) ->
      Plug.Conn.resp(conn, 200, """
        <html><a id="link2" href="#{linked_url2}" target="_blank">2</a></html>
      """)
    end

    Bypass.expect_once bypass, "GET", "/link2", fn (conn) ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url3}">3</a></html>
      """)
    end

    Bypass.expect_once bypass, "GET", "/link3", fn (conn) ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url4}">4</a></html>
      """)
    end

    {:ok, opts} = Crawler.crawl(url, max_depths: 3, workers: 3, interval: 100)

    assert opts[:workers] == 3
    assert OPQ.info(opts[:queue]) == {{[], []}, 2}

    wait fn ->
      assert Store.find_processed(url)
      assert Store.find_processed(linked_url1)
      assert Store.find_processed(linked_url2)
      assert Store.find_processed(linked_url3)
      assert OPQ.info(opts[:queue]) == {{[], []}, 0}
      refute Store.find(linked_url4)
    end

    wait fn ->
      assert OPQ.info(opts[:queue]) == {{[], []}, 3}
    end
  end
end
