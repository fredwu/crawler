defmodule CrawlerTest do
  use ExUnit.Case, async: true

  doctest Crawler

  test "dynamic worker" do
    {:ok, worker} = Crawler.Supervisor.start_child(hello: "world", foo: "bar")

    assert Crawler.Worker.cast(worker) == :ok
  end

  test ".crawl" do
    assert Crawler.crawl("http://example.com/") == :ok
  end
end
