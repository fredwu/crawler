defmodule CrawlerTest do
  use Crawler.TestCase, async: true

  doctest Crawler

  test "dynamic worker", %{url: url} do
    {:ok, worker} = Crawler.Supervisor.start_child(hello: "world", url: url)

    assert Crawler.Worker.cast(worker) == :ok
  end

  test ".crawl", %{url: url} do
    assert Crawler.crawl(url) == :ok
  end
end
