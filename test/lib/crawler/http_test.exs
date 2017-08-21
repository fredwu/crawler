defmodule Crawler.HTTPTest do
  use Crawler.TestCase, async: true

  alias Crawler.{HTTP, Fetcher}

  doctest HTTP

  test "default user agent", %{bypass: bypass, url: url} do
    Bypass.expect_once bypass, "GET", "/http/default_ua", fn (conn) ->
      {_, ua} = Enum.find(conn.req_headers, fn({"user-agent", _}) -> true end)

      assert ua == "Crawler/0.1.0 (https://github.com/fredwu/crawler)"

      Plug.Conn.resp(conn, 200, "")
    end

    Fetcher.fetch(url: "#{url}/http/default_ua", depth: 0)
  end
end
