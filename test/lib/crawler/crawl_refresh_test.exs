defmodule Crawler.CrawlRefreshTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "force refreshes a scope", %{site: site, url: url, req_options: req_options} do
    {:ok, hits} = Agent.start_link(fn -> 0 end)
    page = "#{url}/behavior/refresh"

    ReqTestSite.stub(site, "GET", "/behavior/refresh", fn conn ->
      Agent.update(hits, &(&1 + 1))
      Plug.Conn.resp(conn, 200, "fresh")
    end)

    {:ok, first} =
      start_crawl(page, scope: "refresh", workers: 1, store: Store, req_options: req_options)

    wait(fn ->
      refute Crawler.running?(first)
      assert Agent.get(hits, & &1) == 1
    end)

    {:ok, second} =
      start_crawl(page,
        scope: "refresh",
        force: true,
        workers: 1,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(second)
      assert Agent.get(hits, & &1) == 2
      assert %Store.Page{body: "fresh"} = Store.find_processed({page, "refresh"})
    end)
  end

  test "a forced recrawl keeps the new page when the old fetch finishes later", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    page = "#{url}/behavior/refresh-race"

    ReqTestSite.stub(site, "GET", "/behavior/refresh-race", fn conn ->
      pid = self()
      send(parent, {:started, pid})

      body =
        receive do
          {:release, body} -> body
        after
          5_000 -> raise "Refresh request was not released"
        end

      send(parent, {:finished, body})
      Plug.Conn.resp(conn, 200, body)
    end)

    {:ok, first} =
      start_crawl(page,
        scope: "refresh-race",
        workers: 1,
        store: Store,
        save_to: tmp("behavior-refresh-race"),
        retries: 1,
        req_options: req_options
      )

    assert_receive {:started, old}, 1_000

    {:ok, second} =
      start_crawl(page,
        scope: "refresh-race",
        force: true,
        workers: 1,
        store: Store,
        save_to: tmp("behavior-refresh-race"),
        retries: 1,
        req_options: req_options
      )

    assert_receive {:started, new}, 1_000
    send(new, {:release, "NEW"})

    wait(fn ->
      refute Crawler.running?(second)
      assert %Store.Page{body: "NEW"} = Store.find_processed({page, "refresh-race"})
    end)

    send(old, {:release, "OLD"})
    assert_receive {:finished, "OLD"}, 1_000

    wait(fn ->
      assert {:normal, %{data: {[], []}}, 1} = OPQ.info(first[:queue])
      assert %Store.Page{body: "NEW"} = Store.find_processed({page, "refresh-race"})

      assert File.read!(
               tmp("behavior-refresh-race/#{site.path}/behavior/refresh-race", "__index.html")
             ) == @utf8_bom <> "NEW"
    end)
  end
end
