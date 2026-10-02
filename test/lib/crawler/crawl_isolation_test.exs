defmodule Crawler.CrawlIsolationTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  test "overlapping crawls keep separate queues, budgets, and urls", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()

    ReqTestSite.stub(site, "GET", "/behavior/iso/a", fn conn ->
      send(parent, {:started, :a, self()})

      receive do
        :release ->
          Plug.Conn.resp(conn, 200, ~s(<a href="#{url}/behavior/iso/a1">1</a>))
      after
        5_000 -> Plug.Conn.resp(conn, 500, "late")
      end
    end)

    ReqTestSite.expect_once(site, "GET", "/behavior/iso/a1", fn conn ->
      Plug.Conn.resp(conn, 200, ~s(<a href="#{url}/behavior/iso/a2">2</a>))
    end)

    ReqTestSite.stub(site, "GET", "/behavior/iso/b", fn conn ->
      send(parent, {:started, :b, self()})

      receive do
        :release -> Plug.Conn.resp(conn, 200, "b")
      after
        5_000 -> Plug.Conn.resp(conn, 500, "late")
      end
    end)

    {:ok, held} =
      start_crawl("#{url}/behavior/iso/b",
        max_pages: 2,
        workers: 1,
        store: Store,
        req_options: req_options
      )

    assert_receive {:started, :b, held_pid}, 1_000

    {:ok, other} =
      start_crawl("#{url}/behavior/iso/a",
        max_pages: 2,
        workers: 1,
        store: Store,
        req_options: req_options
      )

    assert_receive {:started, :a, other_pid}, 1_000
    assert other[:queue] != held[:queue]

    Crawler.pause(held)
    assert Process.alive?(held_pid)
    assert Process.alive?(other_pid)
    assert Crawler.running?(other)
    assert elem(OPQ.info(held[:queue]), 0) == :paused
    assert elem(OPQ.info(other[:queue]), 0) == :normal

    send(other_pid, :release)

    wait(fn ->
      assert Store.ops_count(other[:scope]) == 2
      assert Store.find_processed({"#{url}/behavior/iso/a", other[:scope]})
      assert Store.find_processed({"#{url}/behavior/iso/a1", other[:scope]})
      refute Store.find({"#{url}/behavior/iso/a2", other[:scope]})
      refute Store.find({"#{url}/behavior/iso/a", held[:scope]})
    end)

    send(held_pid, :release)
    Crawler.resume(held)

    wait(fn ->
      refute Crawler.running?(held)
      assert Store.ops_count(held[:scope]) == 1
    end)

    {:ok, capped} =
      start_crawl("#{url}/behavior/iso/a2",
        scope: other[:scope],
        queue: other[:queue],
        max_pages: 2,
        req_options: req_options
      )

    assert capped[:queue] == other[:queue]

    wait(fn ->
      refute Crawler.running?(capped)
      refute Store.find({"#{url}/behavior/iso/a2", other[:scope]})
    end)
  end

  test "the same url can be fetched by two crawls", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    {:ok, hits} = Agent.start_link(fn -> 0 end)
    page = "#{url}/behavior/shared-url"

    ReqTestSite.stub(site, "GET", "/behavior/shared-url", fn conn ->
      Agent.update(hits, &(&1 + 1))
      Plug.Conn.resp(conn, 200, "shared")
    end)

    {:ok, first} = start_crawl(page, scope: "crawl-a", workers: 1, req_options: req_options)
    {:ok, second} = start_crawl(page, scope: "crawl-b", workers: 1, req_options: req_options)

    wait(fn ->
      refute Crawler.running?(first)
      refute Crawler.running?(second)
      assert Agent.get(hits, & &1) == 2
      assert Store.find_processed({page, "crawl-a"})
      assert Store.find_processed({page, "crawl-b"})
    end)
  end
end
