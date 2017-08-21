defmodule Crawler.HTTPTest do
  use Crawler.TestCase, async: true

  alias Crawler.HTTP

  doctest HTTP

  test "default user agent", %{bypass: bypass, url: url} do
    Agent.start_link(fn -> "" end, name: HTTP.DefaultUA)

    Bypass.expect_once bypass, "GET", "/http/default_ua", fn (conn) ->
      {_, ua} = Enum.find(conn.req_headers, fn({"user-agent", _}) -> true end)

      Agent.update(HTTP.DefaultUA, fn(_) -> ua end)

      Plug.Conn.resp(conn, 200, "")
    end

    Crawler.crawl("#{url}/http/default_ua")

    wait fn ->
      assert String.match?(
        Agent.get(HTTP.DefaultUA, & &1),
        ~r{Crawler/\d\.\d\.\d \(https://github\.com/fredwu/crawler\)}
      )
    end
  end

  test "custom user agent", %{bypass: bypass, url: url} do
    Agent.start_link(fn -> "" end, name: HTTP.CustomUA)

    Bypass.expect_once bypass, "GET", "/http/custom_ua", fn (conn) ->
      {_, ua} = Enum.find(conn.req_headers, fn({"user-agent", _}) -> true end)

      Agent.update(HTTP.CustomUA, fn(_) -> ua end)

      Plug.Conn.resp(conn, 200, "")
    end

    Crawler.crawl("#{url}/http/custom_ua", user_agent: "Hello World")

    wait fn ->
      assert Agent.get(HTTP.CustomUA, & &1) == "Hello World"
    end
  end
end
