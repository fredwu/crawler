defmodule IntegrationTest do
  use Crawler.TestCase, async: false

  import Plug.Conn

  test "integration", %{
    site: site,
    url: url,
    path: path,
    site2: site2,
    url2: url2,
    path2: path2,
    req_options: req_options
  } do
    linked_url1 = "#{url}/page1.html"
    linked_url2 = "#{url}/dir/page2.html"
    linked_url3 = "#{url2}/page3.html"

    page1_raw = "<html><a href='#{linked_url2}'>2</a> <a href='#{linked_url3}'>3</a></html>"
    page2_raw = "<html><a href='#{linked_url3}'>3</a></html>"
    page3_raw = "<html><a href='dir/page4'>4</a> <a href='/dir/page4'>4</a></html>"

    page4_raw =
      "<html><head><script type='text/javascript' src='/javascript.js' /><link rel='stylesheet' href='../styles.css' /></head><a href='../page5.html'>5</a> <img src='../image1.png' /></html>"

    page5_raw = "<html><a href='/page6'>6</a> <img src='/image2.png' /></html>"
    css_raw = "img { url(image3.png); }"

    ReqTestSite.expect_once(
      site,
      "GET",
      "/page1.html",
      &(&1 |> put_resp_header("content-type", "text/html") |> resp(200, page1_raw))
    )

    ReqTestSite.expect_once(
      site,
      "GET",
      "/dir/page2.html",
      &(&1 |> put_resp_header("content-type", "text/html") |> resp(200, page2_raw))
    )

    ReqTestSite.expect_once(
      site2,
      "GET",
      "/page3.html",
      &(&1 |> put_resp_header("content-type", "text/html") |> resp(200, page3_raw))
    )

    ReqTestSite.expect_once(
      site2,
      "GET",
      "/dir/page4",
      &(&1 |> put_resp_header("content-type", "text/html") |> resp(200, page4_raw))
    )

    ReqTestSite.expect_once(
      site2,
      "GET",
      "/page5.html",
      &(&1 |> put_resp_header("content-type", "text/html") |> resp(200, page5_raw))
    )

    ReqTestSite.expect_once(
      site2,
      "GET",
      "/image1.png",
      &(&1 |> put_resp_header("content-type", "image/png") |> resp(200, "png"))
    )

    ReqTestSite.expect_once(
      site2,
      "GET",
      "/image2.png",
      &(&1 |> put_resp_header("content-type", "image/png") |> resp(200, "png"))
    )

    ReqTestSite.expect_once(
      site2,
      "GET",
      "/image3.png",
      &(&1 |> put_resp_header("content-type", "image/png") |> resp(200, "png"))
    )

    ReqTestSite.expect_once(
      site2,
      "GET",
      "/styles.css",
      &(&1 |> put_resp_header("content-type", "text/css") |> resp(200, css_raw))
    )

    ReqTestSite.expect_once(
      site2,
      "GET",
      "/javascript.js",
      &(&1 |> put_resp_header("content-type", "application/javascript") |> resp(200, "js"))
    )

    Crawler.crawl(linked_url1,
      save_to: tmp("integration"),
      max_depths: 4,
      assets: ["js", "css", "images"],
      req_options: req_options
    )

    page1 =
      "<html><a href='../#{path}/dir/page2.html'>2</a> <a href='../#{path2}/page3.html'>3</a></html>"

    page2 = "<html><a href='../../#{path2}/page3.html'>3</a></html>"

    page3 =
      "<html><a href='../#{path2}/dir/page4/index.html'>4</a> <a href='../#{path2}/dir/page4/index.html'>4</a></html>"

    page4 =
      "<html><head><script type='text/javascript' src='../../../#{path2}/javascript.js' /><link rel='stylesheet' href='../../../#{path2}/styles.css' /></head><a href='../../../#{path2}/page5.html'>5</a> <img src='../../../#{path2}/image1.png' /></html>"

    page5 =
      "<html><a href='../#{path2}/page6/index.html'>6</a> <img src='../#{path2}/image2.png' /></html>"

    css = "img { url(../#{path2}/image3.png); }"

    wait(fn ->
      assert {:ok, page1} == File.read(tmp("integration/#{path}", "page1.html"))
      assert {:ok, page2} == File.read(tmp("integration/#{path}/dir", "page2.html"))
      assert {:ok, page3} == File.read(tmp("integration/#{path2}", "page3.html"))
      assert {:ok, page4} == File.read(tmp("integration/#{path2}/dir/page4", "index.html"))
      assert {:ok, page5} == File.read(tmp("integration/#{path2}", "page5.html"))
      assert {:ok, "png"} == File.read(tmp("integration/#{path2}", "image1.png"))
      assert {:ok, "png"} == File.read(tmp("integration/#{path2}", "image2.png"))
      assert {:ok, "png"} == File.read(tmp("integration/#{path2}", "image3.png"))
      assert {:ok, css} == File.read(tmp("integration/#{path2}", "styles.css"))
      assert {:ok, "js"} == File.read(tmp("integration/#{path2}", "javascript.js"))
    end)
  end
end
