defmodule Crawler.Snapper.LinkReplacerTest do
  use Crawler.TestCase, async: true

  alias Crawler.Snapper.LinkReplacer

  doctest LinkReplacer

  test "rewrites links that contain regex characters" do
    assert {:ok, body} =
             LinkReplacer.replace_links(
               "<a href='http://example.com/search?q=1'></a>",
               %{
                 url: "http://example.com/dir/page",
                 depth: 1,
                 max_depths: 2,
                 html_tag: "a",
                 content_type: "text/html",
                 referrer_url: "http://example.com/dir/page"
               }
             )

    assert body =~ "q=1"
    refute body =~ "href='http://example.com/search?q=1'"
  end

  test "rewrites links against the resolved url" do
    opts = %{
      url: "http://host/old",
      referrer_url: "http://host/dir/page",
      depth: 1,
      max_depths: 2,
      html_tag: "a",
      content_type: "text/html",
      assets: ["js"]
    }

    assert {:ok, body} =
             LinkReplacer.replace_links(
               "<a href='next'></a><a href='//cdn.example/lib.js'></a><a href='http://host/dir/page#a'></a>",
               opts
             )

    assert body =~ "href='../../host/dir/next/__index.html'"
    assert body =~ "href='../../cdn.example/lib.js'"
    assert body =~ "href='../../host/dir/page/__index.html'"
    refute body =~ "href='next'"
    refute body =~ "//cdn.example/lib.js"
    refute body =~ "#a"
  end

  test "rewrites srcset, style urls, and html-escaped queries" do
    opts = %{
      url: "http://host/dir/page",
      referrer_url: "http://host/dir/page",
      depth: 1,
      max_depths: 3,
      html_tag: "a",
      content_type: "text/html",
      assets: ["images", "css"]
    }

    html = """
    <img src="a.jpg" srcset="a.jpg 1x, b.jpg 2x">
    <div style="background: url('bg2.png')"></div>
    <a href="/search?q=1&amp;x=2"></a>
    """

    assert {:ok, body} = LinkReplacer.replace_links(html, opts)

    refute body =~ ~s|srcset="a.jpg 1x, b.jpg 2x"|
    refute body =~ "url('bg2.png')"
    refute body =~ ~s|href="/search?q=1&amp;x=2"|
    assert body =~ "b.jpg"
    assert body =~ "bg2.png"
    assert body =~ "q=1"
    assert body =~ "x=2"
  end

  test "does not rewrite prose and keeps every spelling of one url" do
    opts = %{
      url: "http://host/dir/page",
      referrer_url: "http://host/dir/page",
      depth: 1,
      max_depths: 3,
      html_tag: "a",
      content_type: "text/html",
      assets: ["images", "css"]
    }

    html = """
    <p>See a.jpg today. See "a.jpg" today.</p>
    <img src="./a.jpg" srcset="a.jpg 1x, b.jpg 2x">
    <div style="background: url(&quot;q.png&quot;)"></div>
    <style>body { background: url(&quot;q.png&quot;); } @import &#39;other.css&#39;;</style>
    """

    assert {:ok, body} = LinkReplacer.replace_links(html, opts)

    assert body =~ "See a.jpg today"
    assert body =~ "See \"a.jpg\" today"
    refute body =~ "srcset=\"a.jpg 1x"
    refute body =~ "url(&quot;q.png&quot;)"
    refute body =~ "&quot;q.png&quot;"
    refute body =~ "&#39;other.css&#39;"
    assert body =~ "a.jpg"
    assert body =~ "b.jpg"
    assert body =~ "q.png"
  end
end
