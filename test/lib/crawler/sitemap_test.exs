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

  test "a prefixed document reads a cdata address and a child sitemap" do
    xml = """
    <ns0:urlset xmlns:ns0="http://www.sitemaps.org/schemas/sitemap/0.9">
      <ns0:url>
        <ns0:loc><![CDATA[https://example.com/a&b]]></ns0:loc>
      </ns0:url>
    </ns0:urlset>
    """

    assert Sitemap.locations(xml) == {["https://example.com/a&b"], []}

    literal = "<urlset><url><loc><![CDATA[https://example.com/a&amp;b]]></loc></url></urlset>"
    decoded = "<urlset><url><loc>https://example.com/a&amp;b</loc></url></urlset>"

    assert Sitemap.locations(literal) == {["https://example.com/a&amp;b"], []}
    assert Sitemap.locations(decoded) == {["https://example.com/a&b"], []}

    index = """
    <ns0:sitemapindex xmlns:ns0="http://www.sitemaps.org/schemas/sitemap/0.9">
      <ns0:sitemap><ns0:loc>https://example.com/child.xml</ns0:loc></ns0:sitemap>
    </ns0:sitemapindex>
    """

    assert Sitemap.locations(index) == {[], ["https://example.com/child.xml"]}
  end

  test "an external dtd entity is not a page address" do
    xml = """
    <!DOCTYPE urlset [<!ENTITY x SYSTEM "http://evil.test/x">]>
    <urlset><url><loc>https://example.com/safe</loc></url></urlset>
    """

    assert Sitemap.locations(xml) == {["https://example.com/safe"], []}
  end

  test "a plain list keeps absolute http addresses only" do
    body = """
    https://example.com/plain
    https://example.com/a&b=1

    not a url
    /relative
    """

    assert Sitemap.locations(body) ==
             {["https://example.com/plain", "https://example.com/a&b=1"], []}

    lines = "https://example.com/a\r\nhttps://example.com/b\rhttps://example.com/c"
    bom = <<0xEF, 0xBB, 0xBF>> <> "https://example.com/plain\n"

    assert Sitemap.locations(lines) ==
             {["https://example.com/a", "https://example.com/b", "https://example.com/c"], []}

    assert Sitemap.locations(bom) == {["https://example.com/plain"], []}
  end

  test "an rss item link is a page and the channel link is not" do
    xml = """
    <rss version="2.0">
      <channel>
        <link>https://example.com/channel</link>
        <item><link>https://example.com/post</link></item>
      </channel>
    </rss>
    """

    assert Sitemap.locations(xml) == {["https://example.com/post"], []}
  end

  test "an atom entry keeps an alternate link and skips self" do
    xml = """
    <atom:feed xmlns:atom="http://www.w3.org/2005/Atom">
      <atom:link rel="self" href="https://example.com/feed.atom"/>
      <atom:entry>
        <atom:link rel="alternate" href="https://example.com/entry"/>
        <atom:link rel="self" href="https://example.com/entry.atom"/>
        <atom:link href="https://example.com/missing"/>
        <atom:link rel="" href="https://example.com/empty"/>
        <atom:link rel="notalternate" href="https://example.com/substring"/>
        <atom:link rel="foo alternate bar" href="https://example.com/token"/>
      </atom:entry>
    </atom:feed>
    """

    assert Sitemap.locations(xml) ==
             {[
                "https://example.com/entry",
                "https://example.com/missing",
                "https://example.com/empty",
                "https://example.com/token"
              ], []}
  end

  test "xhtml alternate links are pages and image locs stay out" do
    xml = """
    <urlset xmlns:xhtml="http://www.w3.org/1999/xhtml"
            xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">
      <url>
        <loc>https://example.com/en</loc>
        <xhtml:link rel="alternate" hreflang="de" href="https://example.com/de"/>
        <xhtml:link rel="next" href="https://example.com/skip"/>
        <xhtml:link rel="notalternate" href="https://example.com/substring"/>
        <image:image><image:loc>https://cdn.example/pic.jpg</image:loc></image:image>
      </url>
      <url><loc>/next</loc></url>
      <!-- <loc>https://example.com/hidden</loc> -->
    </urlset>
    """

    assert Sitemap.locations(xml) ==
             {["https://example.com/en", "https://example.com/de", "/next"], []}
  end

  test "a utf-16 sitemap lists its page" do
    little =
      <<0xFF, 0xFE>> <>
        :unicode.characters_to_binary(
          ~s(<urlset><url><loc>https://example.com/wide</loc></url></urlset>),
          :utf8,
          {:utf16, :little}
        )

    big =
      <<0xFE, 0xFF>> <>
        :unicode.characters_to_binary(
          ~s(<urlset><url><loc>https://example.com/wide-be</loc></url></urlset>),
          :utf8,
          {:utf16, :big}
        )

    assert Sitemap.locations(little) == {["https://example.com/wide"], []}
    assert Sitemap.locations(big) == {["https://example.com/wide-be"], []}
  end
end
