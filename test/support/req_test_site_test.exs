defmodule Crawler.ReqTestSiteTest do
  use ExUnit.Case, async: true

  alias Crawler.ReqTestSite

  test "verify! reports missing expected calls" do
    site = ReqTestSite.open(hosts: 1, verify_on_exit: false)

    ReqTestSite.expect_once(site.site, "GET", "/missing", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert_raise ExUnit.AssertionError, ~r/exactly once, got 0 calls/, fn ->
      ReqTestSite.verify!(site)
    end

    ReqTestSite.close(site)
  end

  test "verify! reports unexpected requests" do
    site = ReqTestSite.open(hosts: 1, verify_on_exit: false)

    assert {:ok, %Req.Response{status: 500}} =
             Req.get(site.url <> "/unexpected", ReqTestSite.req_options(site))

    assert_raise ExUnit.AssertionError, ~r/Unexpected request/, fn ->
      ReqTestSite.verify!(site)
    end

    ReqTestSite.close(site)
  end

  test "verify! waits for delayed unexpected requests" do
    site = ReqTestSite.open(hosts: 1, verify_on_exit: false)
    test_pid = self()

    Task.start(fn ->
      Process.sleep(20)

      result = Req.get(site.url <> "/late", ReqTestSite.req_options(site))
      send(test_pid, {:late_request, result})
    end)

    assert_raise ExUnit.AssertionError, ~r/Unexpected request/, fn ->
      ReqTestSite.verify!(site)
    end

    assert_receive {:late_request, {:ok, %Req.Response{status: 500}}}

    ReqTestSite.close(site)
  end

  test "expect_once rejects extra calls without running the route handler again" do
    site = ReqTestSite.open(hosts: 1, verify_on_exit: false)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    ReqTestSite.expect_once(site.site, "GET", "/once", fn conn ->
      Agent.update(counter, &(&1 + 1))
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert {:ok, %Req.Response{status: 200}} =
             Req.get(site.url <> "/once", ReqTestSite.req_options(site))

    assert {:ok, %Req.Response{status: 500}} =
             Req.get(site.url <> "/once", ReqTestSite.req_options(site))

    assert Agent.get(counter, & &1) == 1

    assert_raise ExUnit.AssertionError, ~r/extra request/, fn ->
      ReqTestSite.verify!(site)
    end

    ReqTestSite.close(site)
  end

  test "verify! reports route handler failures" do
    site = ReqTestSite.open(hosts: 1, verify_on_exit: false)

    ReqTestSite.expect_once(site.site, "GET", "/boom", fn _conn ->
      raise "boom"
    end)

    assert {:ok, %Req.Response{status: 500}} =
             Req.get(site.url <> "/boom", ReqTestSite.req_options(site))

    assert_raise ExUnit.AssertionError, ~r/boom/, fn ->
      ReqTestSite.verify!(site)
    end

    ReqTestSite.close(site)
  end

  test "verify! waits for in-flight route handlers" do
    site = ReqTestSite.open(hosts: 1, verify_on_exit: false)
    test_pid = self()

    ReqTestSite.expect_once(site.site, "GET", "/slow", fn conn ->
      send(test_pid, {:handler_started, self()})

      receive do
        :release -> Plug.Conn.send_resp(conn, 200, "ok")
      end
    end)

    request =
      Task.async(fn ->
        Req.get(site.url <> "/slow", ReqTestSite.req_options(site))
      end)

    assert_receive {:handler_started, handler_pid}

    verifier =
      Task.async(fn ->
        ReqTestSite.verify!(site)
        send(test_pid, :verified)
        :ok
      end)

    refute_receive :verified, 20

    send(handler_pid, :release)

    assert :ok = Task.await(verifier)
    assert {:ok, %Req.Response{status: 200}} = Task.await(request)

    ReqTestSite.close(site)
  end
end
