defmodule Crawler.CrawlRetryTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  test "retries retryable responses and a gated transport timeout", %{url: url} do
    {:ok, attempts} = Agent.start_link(fn -> %{} end)
    parent = self()

    adapter = fn request ->
      path = request.url.path

      count =
        Agent.get_and_update(attempts, fn state ->
          count = Map.get(state, path, 0) + 1
          {count, Map.put(state, path, count)}
        end)

      response =
        cond do
          path == "/retry/status" and count < 3 ->
            Req.Response.new(status: 500, body: "nope")

          path == "/retry/missing" ->
            Req.Response.new(status: 404, body: "missing")

          path == "/retry/slow" and count == 1 ->
            send(parent, {:transport_timeout, self()})

            receive do
              :return_timeout -> :ok
            after
              2_000 -> raise "Transport timeout was not released"
            end

            {request, %Req.TransportError{reason: :timeout}}

          true ->
            Req.Response.new(status: 200, body: "ok")
        end

      case response do
        {%Req.Request{}, _exception} = result -> result
        response -> {request, response}
      end
    end

    req_options = [adapter: adapter, retry: false]
    scope = "retries"

    {:ok, status_opts} =
      start_crawl("#{url}/retry/status",
        scope: scope,
        retries: 2,
        timeout: 1_000,
        workers: 1,
        store: Store,
        respect_robots: false,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(status_opts)
      assert Store.find_processed({"#{url}/retry/status", scope})
      assert Agent.get(attempts, & &1["/retry/status"]) == 3
    end)

    {:ok, missing_opts} =
      Crawler.crawl("#{url}/retry/missing",
        scope: scope,
        retries: 2,
        workers: 1,
        queue: status_opts[:queue],
        respect_robots: false,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(missing_opts)
      assert Agent.get(attempts, & &1["/retry/missing"]) == 1
      refute Store.find_processed({"#{url}/retry/missing", scope})
    end)

    {:ok, slow_opts} =
      Crawler.crawl("#{url}/retry/slow",
        scope: scope,
        retries: 1,
        timeout: 30,
        workers: 1,
        queue: status_opts[:queue],
        store: Store,
        respect_robots: false,
        req_options: req_options
      )

    assert_receive {:transport_timeout, request}, 2_000
    assert Store.inflight_count(scope) == 1
    assert Store.pending_count(scope) == 1
    send(request, :return_timeout)

    wait(fn ->
      refute Crawler.running?(slow_opts)
      assert Agent.get(attempts, & &1["/retry/slow"]) == 2
      assert Store.find_processed({"#{url}/retry/slow", scope})
    end)
  end

  test "a failed redirect does not leave the target url blocked", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    landing = "#{url}/alias/landing/"
    blocked = tmp("behavior-alias-block", "not-a-directory")
    File.write!(blocked, "not-a-directory")

    ReqTestSite.expect(site, "GET", "/alias/from", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", landing)
      |> Plug.Conn.resp(302, "")
    end)

    ReqTestSite.expect(site, "GET", "/alias/landing/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "LANDED")
    end)

    {:ok, failed} =
      start_crawl("#{url}/alias/from",
        scope: "alias-fail",
        workers: 1,
        save_to: blocked,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(failed)
      refute Store.find({"#{url}/alias/from", "alias-fail"})
      refute Store.find({landing, "alias-fail"})
    end)

    {:ok, again} =
      start_crawl(landing,
        scope: "alias-fail",
        workers: 1,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(again)
      assert %Store.Page{body: "LANDED"} = Store.find_processed({landing, "alias-fail"})
    end)
  end

  test "a failed fetch can succeed on a later crawl", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    {:ok, hits} = Agent.start_link(fn -> 0 end)
    page = "#{url}/behavior/retry-later"

    ReqTestSite.stub(site, "GET", "/behavior/retry-later", fn conn ->
      count = Agent.get_and_update(hits, fn count -> {count, count + 1} end)

      if count == 0 do
        Plug.Conn.resp(conn, 404, "missing")
      else
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.resp(200, "found")
      end
    end)

    {:ok, first} =
      start_crawl(page,
        scope: "retry-later",
        workers: 1,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(first)
      refute Store.find_processed({page, "retry-later"})
      refute Store.find({page, "retry-later"})
    end)

    {:ok, second} =
      start_crawl(page,
        scope: "retry-later",
        force: true,
        workers: 1,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(second)
      assert %Store.Page{body: "found"} = Store.find_processed({page, "retry-later"})
    end)
  end
end
