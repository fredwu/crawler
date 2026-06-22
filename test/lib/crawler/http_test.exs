defmodule Crawler.HTTPTest do
  use Crawler.TestCase, async: true

  alias Crawler.HTTP

  doctest HTTP

  test "default user agent", %{site: site, url: url, req_options: req_options} do
    Agent.start_link(fn -> "" end, name: HTTP.DefaultUA)

    ReqTestSite.expect_once(site, "GET", "/http/default_ua", fn conn ->
      {_, ua} = Enum.find(conn.req_headers, fn {header, _} -> header == "user-agent" end)
      Agent.update(HTTP.DefaultUA, fn _ -> ua end)

      Plug.Conn.resp(conn, 200, "")
    end)

    Crawler.crawl("#{url}/http/default_ua", req_options: req_options)

    wait(fn ->
      assert String.match?(
               Agent.get(HTTP.DefaultUA, & &1),
               ~r{Crawler/\d\.\d\.\d \(https://github\.com/fredwu/crawler\)}
             )
    end)
  end

  test "custom user agent", %{site: site, url: url, req_options: req_options} do
    Agent.start_link(fn -> "" end, name: HTTP.CustomUA)

    ReqTestSite.expect_once(site, "GET", "/http/custom_ua", fn conn ->
      {_, ua} = Enum.find(conn.req_headers, fn {header, _} -> header == "user-agent" end)

      Agent.update(HTTP.CustomUA, fn _ -> ua end)

      Plug.Conn.resp(conn, 200, "")
    end)

    Crawler.crawl("#{url}/http/custom_ua", user_agent: "Hello World", req_options: req_options)

    wait(fn ->
      assert Agent.get(HTTP.CustomUA, & &1) == "Hello World"
    end)
  end
end
