defmodule CrawlerTest do
  use Crawler.TestCase, async: true

  doctest Crawler

  test "dynamic worker", %{url: url} do
    {:ok, worker} = Crawler.WorkerSupervisor.start_child(hello: "world", url: url)

    assert Crawler.Worker.cast(worker) == :ok
  end

  test ".crawl", %{bypass: bypass, url: url} do
    linked_url = "#{url}/link.html"

    Bypass.expect bypass, fn (conn) ->
      Plug.Conn.resp(conn, 200, """
        <html><a href="#{linked_url}"></a></html>
      """)
    end

    assert Crawler.crawl(url) == :ok

    wait fn ->
      assert CrawlerDB.Page.find(url)
      assert CrawlerDB.Page.find(linked_url)
    end
  end
end
