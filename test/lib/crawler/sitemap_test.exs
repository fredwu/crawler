defmodule Crawler.SitemapTest do
  use ExUnit.Case, async: true

  alias Crawler.Sitemap

  test "reads page addresses and child sitemaps, and skips extension locs" do
    xml = """
    <urlset>
      <url>
        <loc>https://example.com/from-sitemap?a=1&amp;b=2</loc>
        <lastmod>2020-01-01</lastmod>
        <image:image><image:loc>https://cdn.example/pic.jpg</image:loc></image:image>
      </url>
      <!-- <loc>https://example.com/secret</loc> -->
    </urlset>
    """

    assert Sitemap.locations(xml) ==
             {["https://example.com/from-sitemap?a=1&b=2"], []}

    index = """
    <sitemapindex>
      <sitemap><loc>https://cdn.example/child.xml</loc></sitemap>
    </sitemapindex>
    """

    assert Sitemap.locations(index) == {[], ["https://cdn.example/child.xml"]}
  end

  test "numeric character references are decoded and a surrogate is left out" do
    xml = "<urlset><url><loc>https://ex.test/a&#x26;b&#xD800;c</loc></url></urlset>"

    assert Sitemap.locations(xml) == {["https://ex.test/a&bc"], []}
  end
end
