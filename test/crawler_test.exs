defmodule CrawlerTest do
  use Crawler.TestCase, async: true

  doctest Crawler

  test "supervisor and worker" do
    {:ok, worker} = Crawler.WorkerSupervisor.start_child(hello: "world", url: "url")

    assert Crawler.Worker.cast(worker) == :ok
  end

  test ".crawl", %{bypass: bypass, url: url} do
    linked_url1 = "#{url}/link1"
    linked_url2 = "#{url}/link2"

    Bypass.expect_once bypass, "GET", "/link2", fn (conn) ->
      Plug.Conn.resp(conn, 200, """
        <html>Link 2</html>
      """)
    end

    Bypass.expect_once bypass, "GET", "/link1", fn (conn) ->
      Plug.Conn.resp(conn, 200, """
        <html><a id="link2" href="#{linked_url2}" target="_blank"></a></html>
      """)
    end

    Bypass.expect_once bypass, "GET", "/", fn (conn) ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url1}"></a></html>
      """)
    end

    assert Crawler.crawl(url) == :ok

    wait fn ->
      assert Crawler.Store.find_processed(url)
      assert Crawler.Store.find_processed(linked_url1)
      assert Crawler.Store.find(linked_url2)
    end
  end
end
