defmodule Crawler.CrawlFailureRecoveryTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  defmodule BoomParser do
    @moduledoc false
    @behaviour Crawler.Parser.Spec

    def parse(%{body: body} = page) when is_binary(body) do
      if String.contains?(body, "boom"), do: raise("boom")

      Crawler.Parser.parse(page)
    end

    def parse(other), do: Crawler.Parser.parse(other)
  end

  defmodule Probe do
    @moduledoc false
    @behaviour Crawler.Fetcher.Modifier.Spec

    def headers(opts) do
      if is_pid(opts[:probe]) do
        send(opts[:probe], {:fetch, opts[:url], opts[:alias_url], opts[:headers]})
      end

      []
    end

    def opts(_opts), do: []
  end

  defmodule Watch do
    @moduledoc false
    @behaviour Crawler.Scraper.Spec

    def scrape(%{opts: opts, url: url} = page) do
      if is_pid(opts[:probe]),
        do: send(opts[:probe], {:parsed, url, opts[:alias_url], opts[:headers]})

      {:ok, page}
    end
  end

  test "linked pages fetch a missing url once and a later crawl can retry it", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("lifecycle-missing")
    entry = "#{url}/lifecycle/missing"
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/missing", fn conn ->
      Plug.Conn.resp(conn, 200, """
      <a href="#{entry}/a">a</a>
      <a href="#{entry}/b">b</a>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/missing/a", fn conn ->
      Plug.Conn.resp(conn, 200, ~s(<a href="#{entry}/gone">gone</a>))
    end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/missing/b", fn conn ->
      Plug.Conn.resp(conn, 200, ~s(<a href="#{entry}/gone">gone</a>))
    end)

    ReqTestSite.stub(site, "GET", "/lifecycle/missing/gone", fn conn ->
      Agent.update(hits, &(&1 + 1))
      Plug.Conn.resp(conn, 404, "missing")
    end)

    {:ok, opts} =
      start_crawl(entry,
        scope: scope,
        workers: 2,
        max_depths: 3,
        retries: 2,
        req_options: req_options
      )

    wait(2_000, fn ->
      refute Crawler.running?(opts)
      assert Agent.get(hits, & &1) == 1
      refute Store.find({"#{entry}/gone", scope})
      assert Store.find_processed({entry, scope})
    end)

    {:ok, again} =
      start_crawl("#{entry}/gone",
        scope: scope,
        workers: 1,
        retries: 0,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(again)
      assert Agent.get(hits, & &1) == 2
    end)
  end

  test "linked pages retry a failing url once per crawl", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("lifecycle-retry-once")
    entry = "#{url}/lifecycle/retry-once"
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/retry-once", fn conn ->
      Plug.Conn.resp(conn, 200, """
      <a href="#{entry}/a">a</a>
      <a href="#{entry}/b">b</a>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/retry-once/a", fn conn ->
      Plug.Conn.resp(conn, 200, ~s(<a href="#{entry}/down">down</a>))
    end)

    ReqTestSite.expect_once(site, "GET", "/lifecycle/retry-once/b", fn conn ->
      Plug.Conn.resp(conn, 200, ~s(<a href="#{entry}/down">down</a>))
    end)

    ReqTestSite.stub(site, "GET", "/lifecycle/retry-once/down", fn conn ->
      Agent.update(hits, &(&1 + 1))
      Plug.Conn.resp(conn, 500, "down")
    end)

    {:ok, opts} =
      start_crawl(entry,
        scope: scope,
        workers: 2,
        max_depths: 3,
        retries: 2,
        req_options: req_options
      )

    wait(2_000, fn ->
      refute Crawler.running?(opts)
      assert Agent.get(hits, & &1) == 3
      refute Store.find({"#{entry}/down", scope})
    end)

    {:ok, again} =
      start_crawl("#{entry}/down",
        scope: scope,
        workers: 1,
        retries: 2,
        req_options: req_options
      )

    wait(2_000, fn ->
      refute Crawler.running?(again)
      assert Agent.get(hits, & &1) == 6
    end)
  end

  test "a crashed page can be fetched again without force", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("lifecycle-crash")
    page = "#{url}/lifecycle/crash"
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    ReqTestSite.stub(site, "GET", "/lifecycle/crash", fn conn ->
      Agent.update(hits, &(&1 + 1))
      Plug.Conn.resp(conn, 200, "boom")
    end)

    ExUnit.CaptureLog.capture_log(fn ->
      {:ok, failed} =
        start_crawl(page,
          scope: scope,
          workers: 1,
          retries: 0,
          parser: __MODULE__.BoomParser,
          store: Store,
          req_options: req_options
        )

      wait(fn ->
        refute Crawler.running?(failed)
        refute Store.find({page, scope})
        assert Agent.get(hits, & &1) == 1
      end)
    end)

    {:ok, again} =
      start_crawl(page,
        scope: scope,
        workers: 1,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(again)
      assert Agent.get(hits, & &1) == 2
      assert %Store.Page{body: "boom"} = Store.find_processed({page, scope})
    end)
  end

  test "a linked page does not inherit the parent's redirect or headers", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    from = "#{url}/lifecycle/inherit/from"
    landing = "#{url}/lifecycle/inherit/landing"
    child = "#{url}/lifecycle/inherit/child"

    ReqTestSite.expect(site, "GET", "/lifecycle/inherit/from", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", landing)
      |> Plug.Conn.resp(302, "")
    end)

    ReqTestSite.expect(site, "GET", "/lifecycle/inherit/landing", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, ~s(<a href="#{child}">child</a>))
    end)

    ReqTestSite.expect(site, "GET", "/lifecycle/inherit/child", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "child")
    end)

    {:ok, opts} =
      start_crawl(from,
        scope: unique_scope("lifecycle-inherit"),
        workers: 2,
        retries: 0,
        modifier: __MODULE__.Probe,
        scraper: __MODULE__.Watch,
        probe: parent,
        store: Store,
        req_options: req_options
      )

    assert_receive {:parsed, ^from, ^landing, headers}, 2_000
    assert is_list(headers)
    assert_receive {:fetch, ^child, nil, nil}, 2_000

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({child, opts[:scope]})
    end)
  end
end
