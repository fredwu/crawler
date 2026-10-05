defmodule Crawler.RunningScopeTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  test "status follows the saved queue PID when its registered name is rebound", context do
    observer = self()
    name = :crawler_test_running_status_queue

    for queue <- [:original, :replacement] do
      ReqTestSite.expect_once(context.site, "GET", "/status/#{queue}/held", fn conn ->
        send(observer, {queue, self()})

        receive do
          :release ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/html")
            |> Plug.Conn.resp(200, "HELD")
        end
      end)

      ReqTestSite.expect_once(context.site, "GET", "/status/#{queue}/queued", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.resp(200, "QUEUED")
      end)
    end

    assert {:ok, original} =
             start_crawl(context.url <> "/status/original/held",
               scope: unique_scope("original-status"),
               workers: 1,
               retries: 0,
               req_options: context.req_options
             )

    assert_receive {:original, original_handler}, 2_000
    on_exit(fn -> send(original_handler, :release) end)
    assert Process.register(original.queue, name)

    assert {:ok, saved} =
             start_crawl(
               context.url <> "/status/original/queued",
               Map.put(original, :queue, name)
             )

    assert saved.queue == original.queue
    assert saved.queue_name == name
    assert Crawler.running?(saved)
    Crawler.pause(saved)
    refute Crawler.running?(saved)

    assert {:ok, replacement} =
             start_crawl(context.url <> "/status/replacement/held",
               scope: unique_scope("replacement-status"),
               workers: 1,
               retries: 0,
               req_options: context.req_options
             )

    assert_receive {:replacement, replacement_handler}, 2_000
    on_exit(fn -> send(replacement_handler, :release) end)
    assert Process.unregister(name)
    assert Process.register(replacement.queue, name)

    assert {:ok, current} =
             start_crawl(
               context.url <> "/status/replacement/queued",
               Map.put(replacement, :queue, name)
             )

    assert current.queue == replacement.queue
    assert current.queue_name == name
    Crawler.pause(current)
    Crawler.resume(saved)
    assert Crawler.running?(saved)
    refute Crawler.running?(current)

    Crawler.pause(saved)
    Crawler.resume(current)
    refute Crawler.running?(saved)
    assert Crawler.running?(current)

    Crawler.resume(saved)
    send(original_handler, :release)
    send(replacement_handler, :release)
    await_idle(saved)
    await_idle(current)
  end

  test "a completed scope stays idle while another scope has queued work", context do
    observer = self()
    completed_scope = unique_scope("completed-progress")
    active_scope = unique_scope("active-progress")

    ReqTestSite.expect_once(context.site, "GET", "/progress/completed", fn conn ->
      send(observer, {:completed_request, self()})

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "COMPLETE")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/progress/held", fn conn ->
      send(observer, {:held_request, self()})

      receive do
        :release ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.resp(200, "HELD")
      end
    end)

    ReqTestSite.expect_once(context.site, "GET", "/progress/queued", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "QUEUED")
    end)

    assert {:ok, completed} =
             start_crawl(context.url <> "/progress/completed",
               scope: completed_scope,
               workers: 1,
               retries: 0,
               store: Store,
               req_options: context.req_options
             )

    assert_receive {:completed_request, _handler}, 2_000
    await_idle(completed)
    refute Crawler.running?(completed)

    assert {:ok, active} =
             start_crawl(context.url <> "/progress/held",
               scope: active_scope,
               queue: completed.queue,
               retries: 0,
               req_options: context.req_options
             )

    assert_receive {:held_request, held_worker}, 2_000
    on_exit(fn -> send(held_worker, :release) end)

    assert {:ok, queued} = start_crawl(context.url <> "/progress/queued", active)
    assert {:normal, %{data: data}, _} = OPQ.info(completed.queue)
    refute :queue.is_empty(data)
    assert Crawler.running?(active)
    assert Crawler.running?(queued)
    refute Crawler.running?(completed)

    Crawler.pause(active)
    refute Crawler.running?(active)
    Crawler.resume(active)
    assert Crawler.running?(active)
    send(held_worker, :release)
    await_idle(active)
    refute Crawler.running?(completed)
  end
end
