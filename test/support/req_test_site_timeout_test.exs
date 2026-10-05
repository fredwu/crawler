defmodule Crawler.ReqTestSite.TimeoutTest do
  use ExUnit.Case, async: true

  alias Crawler.ReqTestSite

  test "a handler timeout terminates the callback before verification releases the request" do
    fixture = ReqTestSite.open(handler_timeout: 500, verify_on_exit: false)
    on_exit(fn -> ReqTestSite.close(fixture) end)
    observer = self()

    ReqTestSite.expect_once(fixture.site, "GET", "/timeout", fn conn ->
      Process.flag(:trap_exit, true)
      send(observer, {:handler_started, self()})

      receive do
        :release ->
          send(observer, :late_side_effect)
          Plug.Conn.send_resp(conn, 200, "late")
      end
    end)

    request = Task.async(fn -> Req.get(fixture.url <> "/timeout", fixture.req_options) end)
    assert_receive {:handler_started, handler}, 2_000
    on_exit(fn -> Process.exit(handler, :kill) end)
    handler_monitor = Process.monitor(handler)
    assert {:ok, %Req.Response{status: 500}} = Task.await(request, 2_000)
    assert_receive {:DOWN, ^handler_monitor, :process, ^handler, _reason}, 2_000
    refute Process.alive?(handler)
    assert Agent.get(fixture.site.agent, & &1.requests) == %{}

    assert_raise ExUnit.AssertionError, ~r/Handler .*timed out after 500 ms/s, fn ->
      ReqTestSite.verify!(fixture)
    end

    assert :ok = ReqTestSite.close(fixture)
    send(handler, :release)
    refute_receive :late_side_effect
  end
end
