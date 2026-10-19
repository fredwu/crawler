defmodule Crawler.SitemapTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset
  alias Crawler.Fetcher.HeaderPreparer
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

  test "markup in a title or description does not hide the next address" do
    raw = """
    <rss><channel>
      <item><title>A < B</title><link>https://example.com/title</link></item>
      <item><description>1 < 2</description><link>https://example.com/raw</link></item>
      <item><description><p>Hello</p></description><link>https://example.com/html</link></item>
      <item><description><![CDATA[</description>]]></description><link>https://example.com/cdata</link></item>
      <item><description><!-- </description> --></description><link>https://example.com/comment</link></item>
      <item><description><description>1 < 2</description>tail</description><link>https://example.com/nested</link></item>
      <item><subtitle>A < B</subtitle><link>https://example.com/subtitle</link></item>
      <item><description>See <a href="https://example.com/secret">x</a></description><link>https://example.com/kept</link></item>
      <item><link>https://example.com/first</link><description>A < B</description></item>
      <item><title>a<b</title><link>https://example.com/glued</link></item>
      <item><description>score <baseline</description><link>https://example.com/baseline</link></item>
      <item><summary>a<b</summary><link>https://example.com/summary</link></item>
      <item><description><description>a<b</description>tail</description><link>https://example.com/nested-glued</link></item>
      <item><link>https://example.com/later</link></item>
    </channel></rss>
    """

    assert Sitemap.locations(raw) ==
             {[
                "https://example.com/title",
                "https://example.com/raw",
                "https://example.com/html",
                "https://example.com/cdata",
                "https://example.com/comment",
                "https://example.com/nested",
                "https://example.com/subtitle",
                "https://example.com/kept",
                "https://example.com/first",
                "https://example.com/glued",
                "https://example.com/baseline",
                "https://example.com/summary",
                "https://example.com/nested-glued",
                "https://example.com/later"
              ], []}

    video = """
    <urlset xmlns:video="http://www.google.com/schemas/sitemap-video/1.1"
            xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">
      <url>
        <video:video><video:description>A < B</video:description></video:video>
        <image:image><image:caption>A < B</image:caption></image:image>
        <loc>https://example.com/page</loc>
      </url>
      <url>
        <video:video><video:description>a<b</video:description></video:video>
        <image:image><image:caption>a<b</image:caption></image:image>
        <loc>https://example.com/glued</loc>
      </url>
    </urlset>
    """

    assert Sitemap.locations(video) ==
             {["https://example.com/page", "https://example.com/glued"], []}
  end

  test "a quoted greater-than in prose does not hide the next address" do
    open_quote = """
    <rss><channel>
      <item><description>Hello <img alt="a>b></description><link>https://example.com/first</link></item>
      <item><link>https://example.com/later</link></item>
    </channel></rss>
    """

    quoted = """
    <rss><channel>
      <item><description>Hello <img alt="</description>">x</description><link>https://example.com/kept</link></item>
      <item><description>Hello <img alt="</description >">x</description><link>https://example.com/spaced</link></item>
      <item><description>Hello <img alt="a>b"/></description><link>https://example.com/after</link></item>
      <item><description><description alt="</description>">x</description>tail</description><link>https://example.com/nested</link></item>
    </channel></rss>
    """

    later_quote = """
    <rss><channel>
      <item><description>Hello <img alt="a>b></description><link>https://example.com/first</link></item>
      <item><description>Height 5"></description><link>https://example.com/later</link></item>
    </channel></rss>
    """

    spaced = """
    <rss><channel>
      <item><description>Hello <img alt="a>b></description >
      <link>https://example.com/first</link></item>
      <item><description>Height 5"></description><link>https://example.com/later</link></item>
      <item><description>Hello <img alt='a>b></description >
      <link>https://example.com/single</link></item>
      <item><description>Height 5'></description><link>https://example.com/single-later</link></item>
      <item><description>Hello <img alt="a>b></description<link>https://example.com/cut</link></item>
      <item><description>Height 5"></description><link>https://example.com/cut-later</link></item>
    </channel></rss>
    """

    assert Sitemap.locations(open_quote) ==
             {["https://example.com/first", "https://example.com/later"], []}

    assert Sitemap.locations(later_quote) ==
             {["https://example.com/first", "https://example.com/later"], []}

    assert Sitemap.locations(spaced) ==
             {[
                "https://example.com/first",
                "https://example.com/later",
                "https://example.com/single",
                "https://example.com/single-later",
                "https://example.com/cut",
                "https://example.com/cut-later"
              ], []}

    assert Sitemap.locations(quoted) ==
             {[
                "https://example.com/kept",
                "https://example.com/spaced",
                "https://example.com/after",
                "https://example.com/nested"
              ], []}
  end

  test "an unfinished end tag in prose does not hide the next address" do
    missing = """
    <rss><channel>
      <item><description>See <a href="https://example.com/secret">x</a</description><link>https://example.com/first</link></item>
      <item><title>Hello </b</title><link>https://example.com/title</link></item>
      <item><summary>Hello </em</summary><link>https://example.com/summary</link></item>
      <item><title>Hello </title<link>https://example.com/bad</link></item>
      <item><summary>Hello </summary<link>https://example.com/cut</link></item>
      <item><link>https://example.com/later</link></item>
    </channel></rss>
    """

    caption = """
    <urlset><url>
      <image:image><image:caption>x</caption<image:loc>https://example.com/pic.jpg</image:loc></image:image>
      <loc>https://example.com/page</loc>
    </url><url><loc>https://example.com/later</loc></url></urlset>
    """

    quoted = """
    <rss><channel>
      <item><description>Hello </description <img alt=">">x</description><link>https://example.com/kept</link></item>
      <item><description>See <a href="https://example.com/secret">x</a></description><link>https://example.com/finished</link></item>
      <item><description>before<description />after</description><link>https://example.com/empty</link></item>
    </channel></rss>
    """

    longer = """
    <rss><channel>
      <item><description>Hello </description more <b>x</b></description><link>https://example.com/page</link></item>
      <item><description>outer <description>inner </description<link>https://example.com/inner</link></description><link>https://example.com/outer</link></item>
      <item><link>https://example.com/later</link></item>
    </channel></rss>
    """

    assert Sitemap.locations(missing) ==
             {[
                "https://example.com/first",
                "https://example.com/title",
                "https://example.com/summary",
                "https://example.com/bad",
                "https://example.com/cut",
                "https://example.com/later"
              ], []}

    content = """
    <feed><entry>
      <content src="https://example.com/full">a</content<link rel="alternate" href="https://example.com/after"/>
    </entry></feed>
    """

    assert Sitemap.locations(caption) ==
             {["https://example.com/page", "https://example.com/later"], []}

    assert Sitemap.locations(content) ==
             {["https://example.com/full", "https://example.com/after"], []}

    assert Sitemap.locations(quoted) ==
             {[
                "https://example.com/kept",
                "https://example.com/finished",
                "https://example.com/empty"
              ], []}

    assert Sitemap.locations(longer) ==
             {[
                "https://example.com/page",
                "https://example.com/outer",
                "https://example.com/later"
              ], []}
  end

  test "an unclosed instruction or comment does not hide the next address" do
    php = """
    <rss><channel>
      <item><description>Use <?php echo 1;</description><link>https://example.com/first</link></item>
      <item><title>Compare a <!-- b</title><link>https://example.com/title</link></item>
      <item><description><![CDATA[hello</description><link>https://example.com/cdata</link></item>
      <item><description>a <? b</description><link>https://example.com/plain</link></item>
      <item><link>https://example.com/later</link></item>
    </channel></rss>
    """

    named = """
    <rss><channel>
      <item><description>Use <?php echo "<description>"; ?></description><link>https://example.com/start</link></item>
      <item><description>Use <?php echo "</description>"; ?></description><link>https://example.com/end</link></item>
      <item><description>Use <?php echo "</description >"; ?></description><link>https://example.com/spaced</link></item>
      <item><link>https://example.com/later</link></item>
    </channel></rss>
    """

    open_pi = """
    <rss><channel>
      <item><description>Use <?php echo "</description><link>https://example.com/first</link></item>
      <item><description>x" ?></description><link>https://example.com/later</link></item>
    </channel></rss>
    """

    later = """
    <rss><channel>
      <item><title>Use <?php</title><link>https://example.com/first</link></item>
      <item><title>?></title><link>https://example.com/second</link></item>
    </channel></rss>
    """

    assert Sitemap.locations(php) ==
             {[
                "https://example.com/first",
                "https://example.com/title",
                "https://example.com/cdata",
                "https://example.com/plain",
                "https://example.com/later"
              ], []}

    assert Sitemap.locations(named) ==
             {[
                "https://example.com/start",
                "https://example.com/end",
                "https://example.com/spaced",
                "https://example.com/later"
              ], []}

    assert Sitemap.locations(open_pi) ==
             {["https://example.com/first", "https://example.com/later"], []}

    assert Sitemap.locations(later) ==
             {["https://example.com/first", "https://example.com/second"], []}
  end

  test "a declared encoding still yields the link" do
    latin1 =
      ~s(<?xml version="1.0" encoding="ISO-8859-1"?>) <>
        "<rss><channel><item><title>caf" <>
        <<0xE9>> <> "</title><link>https://example.com/page</link></item></channel></rss>"

    windows =
      ~s(<?xml version="1.0" encoding="Windows-1252"?>) <>
        "<rss><channel><item><title>x" <>
        <<0x99>> <> "</title><link>https://example.com/win</link></item></channel></rss>"

    utf16 =
      :unicode.characters_to_binary(
        ~s(<?xml version="1.0" encoding="UTF-16"?><urlset><url><loc>https://example.com/wide</loc></url></urlset>),
        :utf8,
        {:utf16, :little}
      )

    undeclared =
      "<rss><channel><item><title>caf" <>
        <<0xE9>> <> "</title><link>https://example.com/page</link></item></channel></rss>"

    unknown =
      ~s(<?xml version="1.0" encoding="x-not-a-charset"?>) <>
        "<rss><channel><item><title>" <>
        <<0xE9>> <> "</title><link>https://example.com/page</link></item></channel></rss>"

    assert Sitemap.locations(latin1) == {["https://example.com/page"], []}
    assert Sitemap.locations(windows) == {["https://example.com/win"], []}
    assert Sitemap.locations(utf16) == {["https://example.com/wide"], []}
    assert Sitemap.locations(undeclared) == {[], []}
    assert Sitemap.locations(unknown) == {[], []}
  end

  test "a utf-8 body that still declares utf-16 yields the link" do
    utf16 =
      ~s(<?xml version="1.0" encoding="UTF-16"?>) <>
        "<rss><channel><item><link>https://example.com/page</link></item></channel></rss>"

    little =
      ~s(<?xml version="1.0" encoding="UTF-16LE"?>) <>
        "<urlset><url><loc>https://example.com/little</loc></url></urlset>"

    big =
      ~s(<?xml version="1.0" encoding="UTF-16BE"?>) <>
        "<urlset><url><loc>https://example.com/big</loc></url></urlset>"

    invalid = ~s(<?xml version="1.0" encoding="UTF-16"?>) <> <<0xE9>>

    assert Sitemap.locations(utf16) == {["https://example.com/page"], []}
    assert Sitemap.locations(little) == {["https://example.com/little"], []}
    assert Sitemap.locations(big) == {["https://example.com/big"], []}
    assert Sitemap.locations(invalid) == {[], []}
  end

  test "a utf-8 body that still declares a single-byte encoding keeps the link" do
    latin1 =
      ~s(<?xml version="1.0" encoding="ISO-8859-1"?>) <>
        "<rss><channel><item><link>https://example.com/café</link></item></channel></rss>"

    windows =
      ~s(<?xml version="1.0" encoding="Windows-1252"?>) <>
        "<rss><channel><item><link>https://example.com/café</link></item></channel></rss>"

    wire =
      ~s(<?xml version="1.0" encoding="ISO-8859-1"?>) <>
        "<rss><channel><item><link>https://example.com/caf" <>
        <<0xE9>> <> "</link></item></channel></rss>"

    opts = HeaderPreparer.prepare([{"content-type", "text/xml; charset=iso-8859-1"}], %{})

    assert Sitemap.locations(latin1) == {["https://example.com/café"], []}
    assert Sitemap.locations(windows) == {["https://example.com/café"], []}
    assert Sitemap.locations(wire) == {["https://example.com/café"], []}
    assert Sitemap.locations(Charset.decode(wire, opts)) == {["https://example.com/café"], []}
  end

  test "a text/xml document with no charset is decoded from its bytes" do
    latin1 =
      ~s(<?xml version="1.0" encoding="ISO-8859-1"?>) <>
        "<rss><channel><item><link>https://example.com/caf" <>
        <<0xE9>> <> "</link></item></channel></rss>"

    xml =
      ~s(<?xml version="1.0" encoding="UTF-16"?>) <>
        "<rss><channel><item><link>https://example.com/café</link></item></channel></rss>"

    raw = :unicode.characters_to_binary(xml, :utf8, {:utf16, :little})
    opts = HeaderPreparer.prepare([{"content-type", "text/xml"}], %{})

    assert Sitemap.locations(Charset.decode(latin1, opts)) == {["https://example.com/café"], []}
    assert Sitemap.locations(Charset.decode(raw, opts)) == {["https://example.com/café"], []}

    assert Sitemap.locations(Charset.decode(<<0xFF, 0xFE>> <> raw, opts)) ==
             {["https://example.com/café"], []}
  end

  test "a text/xml charset of utf-16 still yields the link" do
    xml =
      ~s(<?xml version="1.0" encoding="UTF-16"?>) <>
        "<rss><channel><item><link>https://example.com/café</link></item></channel></rss>"

    little = :unicode.characters_to_binary(xml, :utf8, {:utf16, :little})
    big = :unicode.characters_to_binary(xml, :utf8, {:utf16, :big})
    opts = HeaderPreparer.prepare([{"content-type", "text/xml; charset=utf-16"}], %{})
    explicit = HeaderPreparer.prepare([{"content-type", "text/xml; charset=utf-16le"}], %{})

    assert Sitemap.locations(Charset.decode(little, opts)) == {["https://example.com/café"], []}
    assert Sitemap.locations(Charset.decode(big, opts)) == {["https://example.com/café"], []}
    assert Sitemap.locations(Charset.decode(xml, opts)) == {["https://example.com/café"], []}

    assert Sitemap.locations(Charset.decode(little, explicit)) ==
             {["https://example.com/café"], []}
  end

  test "an atom content src and an rss permalink guid are pages" do
    src = """
    <feed>
      <entry>
        <content src="https://example.com/full"><p>A < B</p><a href="https://example.com/inner">x</a></content>
        <link rel="alternate" href="https://example.com/after"/>
      </entry>
      <entry>
        <content src="https://example.com/glued">a<b</content>
        <link rel="alternate" href="https://example.com/glued-after"/>
      </entry>
    </feed>
    """

    guid = """
    <rss><channel>
      <item><guid>https://example.com/only-guid</guid></item>
      <item><guid isPermaLink="false">https://example.com/skip</guid></item>
      <item><guid>urn:example:1</guid><link>https://example.com/post</link></item>
      <item><guid>tag:example.com,2020:1</guid><link>https://example.com/tagged</link></item>
      <item><guid>/relative</guid><link>https://example.com/relative</link></item>
    </channel></rss>
    """

    assert Sitemap.locations(src) ==
             {[
                "https://example.com/full",
                "https://example.com/after",
                "https://example.com/glued",
                "https://example.com/glued-after"
              ], []}

    assert Sitemap.locations(guid) ==
             {[
                "https://example.com/only-guid",
                "https://example.com/post",
                "https://example.com/tagged",
                "https://example.com/relative"
              ], []}
  end

  test "an enclosure or media file is not a page address" do
    rss = """
    <rss><channel><item>
      <link>https://example.com/post</link>
      <enclosure url="https://cdn.example/ep.mp3"></enclosure>
      <media:content url="https://cdn.example/v.mp4">
        <media:thumbnail url="https://cdn.example/t.jpg"/>
      </media:content>
    </item></channel></rss>
    """

    atom = """
    <feed><entry>
      <link rel="alternate" href="https://example.com/article"/>
      <link rel="Enclosure" href="https://cdn.example/a.mp3"/>
    </entry></feed>
    """

    assert Sitemap.locations(rss) == {["https://example.com/post"], []}
    assert Sitemap.locations(atom) == {["https://example.com/article"], []}
  end

  test "locations keeps a relative address unresolved" do
    xml = """
    <feed xml:base="/blog/">
      <entry xml:base="https://example.com/news/"><link href="post"/></entry>
      <entry><link href="other"/></entry>
    </feed>
    """

    assert Sitemap.locations(xml) == {["post", "other"], []}

    index = """
    <sitemapindex xml:base="/maps/"><sitemap><loc>child.xml</loc></sitemap></sitemapindex>
    """

    assert Sitemap.locations(index) == {[], ["child.xml"]}
  end
end
