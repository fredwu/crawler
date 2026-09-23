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

    assert body =~ "href='../../host/dir/next/index.html'"
    assert body =~ "href='../../cdn.example/lib.js'"
    assert body =~ "href='../../host/dir/page/index.html'"
    refute body =~ "href='next'"
    refute body =~ "//cdn.example/lib.js"
    refute body =~ "#a"
  end
end
