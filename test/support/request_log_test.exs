defmodule Crawler.RequestLogTest do
  use ExUnit.Case, async: true

  alias Crawler.RequestLog

  test "counts identical requests separately" do
    table = RequestLog.new()
    request = "http://example.com/page"
    parent = self()

    spawn(fn ->
      RequestLog.record(table, request)
      RequestLog.record(table, request)
      send(parent, :recorded)
    end)

    assert_receive :recorded
    assert RequestLog.entries(table) == [request, request]
    assert RequestLog.frequencies(table) == %{request => 2}
  end
end
