defmodule IntegrationTest do
  use Crawler.TestCase, async: true

  test "integration", %{bypass: bypass, url: url, path: path, bypass2: bypass2, url2: url2, path2: path2} do
    linked_url1 = "#{url}/page1"
    linked_url2 = "#{url}/dir/page2"
    linked_url3 = "#{url2}/page3"

    Bypass.expect_once bypass, "GET", "/page1", fn (conn) ->
      Plug.Conn.resp(conn, 200, "<html><a href='#{linked_url2}'>2</a> <a href='#{linked_url3}'>3</a></html>")
    end

    Bypass.expect_once bypass, "GET", "/dir/page2", fn (conn) ->
      Plug.Conn.resp(conn, 200, "<html><a href='#{linked_url3}'>3</a></html>")
    end

    Bypass.expect_once bypass2, "GET", "/page3", fn (conn) ->
      Plug.Conn.resp(conn, 200, "<html><a href='dir/page4'>4</a> <a href='/dir/page4'>4</a></html>")
    end

    Bypass.expect_once bypass2, "GET", "/dir/page4", fn (conn) ->
      Plug.Conn.resp(conn, 200, "<html><a href='../page5'>5</a></html>")
    end

    Bypass.expect_once bypass2, "GET", "/page5", fn (conn) ->
      Plug.Conn.resp(conn, 200, "<html><a href='/page6'>6</a></html>")
    end

    Crawler.crawl(linked_url1, save_to: tmp("integration"), max_depths: 4)

    page1 = "<html><a href='../#{path}/dir/page2'>2</a> <a href='../#{path2}/page3'>3</a></html>"
    page2 = "<html><a href='../../#{path2}/page3'>3</a></html>"
    page3 = "<html><a href='../#{path2}/dir/page4'>4</a> <a href='../#{path2}/dir/page4'>4</a></html>"
    page4 = "<html><a href='../../#{path2}/page5'>5</a></html>"
    page5 = "<html><a href='/page6'>6</a></html>"

    wait fn ->
      assert {:ok, page1} == File.read(tmp("integration/#{path}", "page1"))
      assert {:ok, page2} == File.read(tmp("integration/#{path}/dir", "page2"))
      assert {:ok, page3} == File.read(tmp("integration/#{path2}", "page3"))
      assert {:ok, page4} == File.read(tmp("integration/#{path2}/dir", "page4"))
      assert {:ok, page5} == File.read(tmp("integration/#{path2}", "page5"))
    end
  end
end
