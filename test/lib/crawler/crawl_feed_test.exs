defmodule Crawler.CrawlFeedTest do
  use Crawler.TestCase, async: false

  import Plug.Conn
  import Crawler.SnapshotHelpers

  alias Crawler.Store

  test "a feed or sitemap linked from the page lists pages", context do
    page = context.url <> "/start"
    post = context.url <> "/post"
    entry = context.url <> "/entry"
    from_map = context.url <> "/from-map"

    html = """
    <link rel="alternate" type="application/rss+xml; charset=utf-8" href="/feed.xml">
    <link rel="alternate" type="application/atom+xml" href="/atom.xml">
    <a href="/map.xml">Map</a>
    <link rel="canonical" href="/canon">
    <link rel="alternate" hreflang="de" href="/de">
    <link rel="dns-prefetch" href="https://cdn.test/dns">
    <link rel="preconnect" href="https://cdn.test/connect">
    <a href="/post">Post</a>
    <link rel="alternate" type="application/rss+xml" href="#{context.url2}/away.xml">
    """

    feed = """
    <rss version="2.0">
      <channel>
        <link>#{context.url}/home</link>
        <item><link>#{post}</link></item>
        <item><link>#{post}</link></item>
        <item><link>#{context.url}/secret</link></item>
        <item><link>https://other.test/out</link></item>
      </channel>
    </rss>
    """

    atom = """
    <feed>
      <entry>
        <link rel="self" href="#{context.url}/entry.atom"/>
        <link rel="alternate" href="#{entry}"/>
      </entry>
    </feed>
    """

    index = """
    <sitemapindex>
      <sitemap><loc>#{context.url}/child.xml</loc></sitemap>
    </sitemapindex>
    """

    child = """
    <urlset>
      <url><loc>#{from_map}</loc></url>
      <url><loc>https://other.test/map</loc></url>
    </urlset>
    """

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, "User-agent: *\nDisallow: /secret\n")
    end)

    expect_html(context, "/start", html)
    expect_bytes(context, "/feed.xml", "application/rss+xml", feed)
    expect_bytes(context, "/atom.xml", "application/atom+xml", atom)
    expect_bytes(context, "/map.xml", "application/xml", index)
    expect_bytes(context, "/child.xml", "text/xml", child)
    expect_html(context, "/post", "post")
    expect_html(context, "/entry", "entry")
    expect_html(context, "/from-map", "from-map")

    {opts, _root} = run(page, context, max_pages: 4)

    assert Store.find_processed({page, opts.scope})
    assert Store.find_processed({post, opts.scope}).body == "post"
    assert Store.find_processed({entry, opts.scope}).body == "entry"
    assert Store.find_processed({from_map, opts.scope}).body == "from-map"
    assert Store.ops_count(opts.scope) == 4

    for url <- [
          context.url <> "/home",
          context.url <> "/secret",
          context.url <> "/entry.atom",
          context.url <> "/canon",
          context.url <> "/de",
          context.url2 <> "/away.xml",
          "https://cdn.test/dns",
          "https://cdn.test/connect",
          "https://other.test/out",
          "https://other.test/map"
        ] do
      refute Store.find({url, opts.scope})
    end
  end

  test "xml that is not a feed or sitemap contributes no addresses", context do
    page = context.url <> "/start"
    note = context.url <> "/note.xml"
    body = ~s|<note>See <a href="/secret"></a><loc>#{context.url}/also</loc></note>|

    expect_html(context, "/start", ~s|<a href="/note.xml">Note</a>|)
    expect_bytes(context, "/note.xml", "text/xml", body)

    {opts, root} = run(page, context, [])

    assert File.read!(saved(root, note)) == body
    refute Store.find({context.url <> "/secret", opts.scope})
    refute Store.find({context.url <> "/also", opts.scope})
  end

  test "nofollow skips a feed and an alternate stylesheet is still fetched", context do
    page = context.url <> "/quiet"

    expect_html(
      context,
      "/quiet",
      """
      <link rel="alternate" type="application/rss+xml" href="/feed.xml">
      <link rel="alternate stylesheet" href="/alt.css" title="Alt">
      <link rel="alternate" hreflang="de" href="/de">
      """,
      [{"x-robots-tag", "nofollow"}]
    )

    expect_bytes(context, "/alt.css", "text/css", "body{}")

    {opts, _root} = run(page, context, assets: ["css"])

    assert Store.find_processed({context.url <> "/alt.css", opts.scope})
    refute Store.find({context.url <> "/feed.xml", opts.scope})
    refute Store.find({context.url <> "/de", opts.scope})
  end

  test "markup in a title or description does not hide the next page", context do
    page = context.url <> "/start"
    title = context.url <> "/title"
    raw = context.url <> "/raw"
    glued = context.url <> "/glued"
    later = context.url <> "/later"

    feed = """
    <rss><channel>
      <item><title>A < B</title><link>#{title}</link></item>
      <item><description>1 < 2</description><link>#{raw}</link></item>
      <item><description>See <a href="#{context.url}/secret">x</a></description><link>#{context.url}/kept</link></item>
      <item><title>a<b</title><link>#{glued}</link></item>
      <item><link>#{later}</link></item>
    </channel></rss>
    """

    expect_html(
      context,
      "/start",
      ~s|<link rel="alternate" type="application/rss+xml" href="/feed.xml">|
    )

    expect_bytes(context, "/feed.xml", "application/rss+xml", feed)
    expect_html(context, "/title", "title")
    expect_html(context, "/raw", "raw")
    expect_html(context, "/kept", "kept")
    expect_html(context, "/glued", "glued")
    expect_html(context, "/later", "later")

    {opts, _root} = run(page, context, [])

    assert Store.find_processed({title, opts.scope}).body == "title"
    assert Store.find_processed({raw, opts.scope}).body == "raw"
    assert Store.find_processed({context.url <> "/kept", opts.scope}).body == "kept"
    assert Store.find_processed({glued, opts.scope}).body == "glued"
    assert Store.find_processed({later, opts.scope}).body == "later"
    refute Store.find({context.url <> "/secret", opts.scope})
    assert Store.ops_count(opts.scope) == 6
  end

  test "a relative address uses the feed xml:base", context do
    page = context.url <> "/start"
    other = context.url <> "/blog/other"
    post = context.url <> "/news/post"
    later = context.url <> "/blog/news/later"

    feed = """
    <feed xml:base="/blog/">
      <link href="/home"/>
      <title xml:base="https://other.test/nope/">1 < 2</title>
      <entry><link href="other"/></entry>
      <entry xml:base="#{context.url}/news/"><link href="post"/></entry>
      <entry xml:base="news/"><link href="later"/></entry>
      <entry><link xml:base="https://other.test/away/" href="nope"/></entry>
    </feed>
    """

    expect_html(
      context,
      "/start",
      ~s|<link rel="alternate" type="application/atom+xml" href="/feeds/index.atom">|
    )

    expect_bytes(context, "/feeds/index.atom", "application/atom+xml", feed)
    expect_html(context, "/blog/other", "other")
    expect_html(context, "/news/post", "post")
    expect_html(context, "/blog/news/later", "later")

    {opts, _root} = run(page, context, [])

    assert Store.find_processed({other, opts.scope}).body == "other"
    assert Store.find_processed({post, opts.scope}).body == "post"
    assert Store.find_processed({later, opts.scope}).body == "later"
    refute Store.find({context.url <> "/feeds/other", opts.scope})
    refute Store.find({context.url <> "/feeds/post", opts.scope})
    refute Store.find({context.url <> "/home", opts.scope})
    refute Store.find({context.url <> "/blog/home", opts.scope})
    refute Store.find({"https://other.test/away/nope", opts.scope})
    refute Store.find({"https://other.test/nope/other", opts.scope})
    assert Store.ops_count(opts.scope) == 4
  end

  test "a child sitemap loc uses xml:base", context do
    page = context.url <> "/start"
    landed = context.url <> "/from-base"

    index = """
    <sitemapindex xml:base="/maps/">
      <sitemap><loc>child.xml</loc></sitemap>
    </sitemapindex>
    """

    child = "<urlset><url><loc>#{landed}</loc></url></urlset>"

    expect_html(context, "/start", ~s|<a href="/feeds/index.xml">Map</a>|)
    expect_bytes(context, "/feeds/index.xml", "application/xml", index)
    expect_bytes(context, "/maps/child.xml", "text/xml", child)
    expect_html(context, "/from-base", "from-base")

    {opts, _root} = run(page, context, [])

    assert Store.find_processed({landed, opts.scope}).body == "from-base"
    refute Store.find({context.url <> "/feeds/child.xml", opts.scope})
    assert Store.ops_count(opts.scope) == 2
  end

  test "a declared encoding still contributes its page", context do
    page = context.url <> "/start"
    latin_page = context.url <> "/page"
    wide = context.url <> "/wide"

    latin1 =
      ~s(<?xml version="1.0" encoding="ISO-8859-1"?>) <>
        "<rss><channel><item><title>caf" <>
        <<0xE9>> <> "</title><link>#{latin_page}</link></item></channel></rss>"

    utf16 =
      :unicode.characters_to_binary(
        ~s(<?xml version="1.0" encoding="UTF-16"?><urlset><url><loc>#{wide}</loc></url></urlset>),
        :utf8,
        {:utf16, :little}
      )

    expect_html(
      context,
      "/start",
      ~s|<link rel="alternate" type="application/rss+xml" href="/latin.xml"><a href="/wide.xml">Wide</a>|
    )

    expect_bytes(context, "/latin.xml", "application/rss+xml", latin1)
    expect_bytes(context, "/wide.xml", "application/xml", utf16)
    expect_html(context, "/page", "page")
    expect_html(context, "/wide", "wide")

    {opts, _root} = run(page, context, [])

    assert Store.find_processed({latin_page, opts.scope}).body == "page"
    assert Store.find_processed({wide, opts.scope}).body == "wide"
    assert Store.ops_count(opts.scope) == 3
  end

  test "a text/xml utf-16 feed still contributes its page", context do
    page = context.url <> "/start"
    post = context.url <> "/post"

    xml =
      ~s(<?xml version="1.0" encoding="UTF-16"?>) <>
        "<rss><channel><item><link>#{post}</link></item></channel></rss>"

    body = <<0xFF, 0xFE>> <> :unicode.characters_to_binary(xml, :utf8, {:utf16, :little})

    expect_html(context, "/start", ~s|<a href="/feed.xml">Feed</a>|)
    expect_bytes(context, "/feed.xml", "text/xml", body)
    expect_html(context, "/post", "post")

    {opts, _root} = run(page, context, [])

    assert Store.find_processed({post, opts.scope}).body == "post"
    assert Store.ops_count(opts.scope) == 2
  end

  test "a text/xml charset of utf-16 still contributes its page", context do
    page = context.url <> "/start"
    post = context.url <> "/post"

    xml =
      ~s(<?xml version="1.0" encoding="UTF-16"?>) <>
        "<rss><channel><item><link>#{post}</link></item></channel></rss>"

    body = :unicode.characters_to_binary(xml, :utf8, {:utf16, :little})

    expect_html(context, "/start", ~s|<a href="/feed.xml">Feed</a>|)
    expect_bytes(context, "/feed.xml", "text/xml; charset=utf-16", body)
    expect_html(context, "/post", "post")

    {opts, _root} = run(page, context, [])

    assert Store.find_processed({post, opts.scope}).body == "post"
    assert Store.ops_count(opts.scope) == 2
  end

  test "a content src and a permalink guid are pages when images are off", context do
    page = context.url <> "/start"
    full = context.url <> "/full"
    after_page = context.url <> "/after"
    guid = context.url <> "/only-guid"
    linked = context.url <> "/linked"

    atom = """
    <feed><entry>
      <content src="#{full}"><p>A < B</p><a href="#{context.url}/inner">x</a></content>
      <link rel="alternate" href="#{after_page}"/>
    </entry></feed>
    """

    rss = """
    <rss><channel>
      <item><guid>#{guid}</guid></item>
      <item>
        <guid isPermaLink="false">#{context.url}/skip</guid>
        <guid>urn:example:1</guid>
        <link>#{linked}</link>
        <enclosure url="#{context.url2}/ep.mp3"></enclosure>
      </item>
    </channel></rss>
    """

    expect_html(
      context,
      "/start",
      ~s|<link rel="alternate" type="application/atom+xml" href="/atom.xml"><link rel="alternate" type="application/rss+xml" href="/feed.xml">|
    )

    expect_bytes(context, "/atom.xml", "application/atom+xml", atom)
    expect_bytes(context, "/feed.xml", "application/rss+xml", rss)
    expect_html(context, "/full", "full")
    expect_html(context, "/after", "after")
    expect_html(context, "/only-guid", "guid")
    expect_html(context, "/linked", "linked")

    {opts, _root} = run(page, context, [])

    assert Store.find_processed({full, opts.scope}).body == "full"
    assert Store.find_processed({after_page, opts.scope}).body == "after"
    assert Store.find_processed({guid, opts.scope}).body == "guid"
    assert Store.find_processed({linked, opts.scope}).body == "linked"
    refute Store.find({context.url <> "/inner", opts.scope})
    refute Store.find({context.url <> "/skip", opts.scope})
    refute Store.find({context.url2 <> "/ep.mp3", opts.scope})
    assert Store.ops_count(opts.scope) == 5
  end

  test "enclosures and media files are fetched when image assets are collected", context do
    page = context.url <> "/start"
    post = context.url <> "/post"
    article = context.url <> "/article"
    cdn = context.url2

    rss = """
    <rss><channel><item>
      <link>#{post}</link>
      <enclosure url="#{cdn}/ep.mp3"></enclosure>
      <media:content url="#{cdn}/v.mp4"><media:thumbnail url="#{cdn}/t.jpg"/></media:content>
      <video:player_loc>#{cdn}/player</video:player_loc>
    </item></channel></rss>
    """

    atom = """
    <feed><entry>
      <link rel="alternate" href="#{article}"/>
      <link rel="enclosure" href="#{cdn}/audio.mp3"/>
    </entry></feed>
    """

    expect_html(
      context,
      "/start",
      ~s|<link rel="alternate" type="application/rss+xml" href="/feed.xml"><link rel="alternate" type="application/atom+xml" href="/atom.xml">|
    )

    expect_bytes(context, "/feed.xml", "application/rss+xml", rss)
    expect_bytes(context, "/atom.xml", "application/atom+xml", atom)
    expect_html(context, "/post", "post")
    expect_html(context, "/article", "article")
    expect_asset(context.site2, "/ep.mp3", "audio/mpeg")
    expect_asset(context.site2, "/v.mp4", "video/mp4")
    expect_asset(context.site2, "/t.jpg", "image/jpeg")
    expect_asset(context.site2, "/audio.mp3", "audio/mpeg")

    {opts, _root} = run(page, context, assets: ["images"])

    assert Store.find_processed({post, opts.scope}).body == "post"
    assert Store.find_processed({article, opts.scope}).body == "article"
    assert Store.find_processed({cdn <> "/ep.mp3", opts.scope})
    assert Store.find_processed({cdn <> "/v.mp4", opts.scope})
    assert Store.find_processed({cdn <> "/t.jpg", opts.scope})
    assert Store.find_processed({cdn <> "/audio.mp3", opts.scope})
    refute Store.find({cdn <> "/player", opts.scope})
  end

  test "enclosures and media files stay unfetched when images are off", context do
    page = context.url <> "/start"
    post = context.url <> "/post"
    article = context.url <> "/article"
    cdn = context.url2

    rss = """
    <rss><channel><item>
      <link>#{post}</link>
      <enclosure url="#{cdn}/ep.mp3"/>
      <media:content url="#{cdn}/v.mp4"/>
      <media:thumbnail url="#{cdn}/t.jpg"/>
    </item></channel></rss>
    """

    atom = """
    <feed><entry>
      <link rel="alternate" href="#{article}"/>
      <link rel="enclosure" href="#{cdn}/audio.mp3"/>
    </entry></feed>
    """

    expect_html(
      context,
      "/start",
      ~s|<link rel="alternate" type="application/rss+xml" href="/feed.xml"><link rel="alternate" type="application/atom+xml" href="/atom.xml">|
    )

    expect_bytes(context, "/feed.xml", "application/rss+xml", rss)
    expect_bytes(context, "/atom.xml", "application/atom+xml", atom)
    expect_html(context, "/post", "post")
    expect_html(context, "/article", "article")

    {opts, _root} = run(page, context, [])

    assert Store.find_processed({post, opts.scope}).body == "post"
    assert Store.find_processed({article, opts.scope}).body == "article"
    refute Store.find({cdn <> "/ep.mp3", opts.scope})
    refute Store.find({cdn <> "/v.mp4", opts.scope})
    refute Store.find({cdn <> "/t.jpg", opts.scope})
    refute Store.find({cdn <> "/audio.mp3", opts.scope})
    assert Store.ops_count(opts.scope) == 3
  end

  test "an rss 1.0 document linked from the page contributes its items", context do
    page = context.url <> "/start"
    post = context.url <> "/post"
    from_rss = context.url <> "/from-rss"
    from_xml = context.url <> "/from-xml"

    rdf = """
    <rdf:RDF>
      <channel><link>#{context.url}/home</link></channel>
      <item><link>#{post}</link></item>
    </rdf:RDF>
    """

    rss = """
    <rdf:RDF>
      <item><link>#{from_rss}</link></item>
    </rdf:RDF>
    """

    xml = """
    <rdf:RDF>
      <item rdf:about="#{context.url}/about"><link>#{from_xml}</link></item>
    </rdf:RDF>
    """

    expect_html(
      context,
      "/start",
      """
      <link rel="alternate" type="application/rdf+xml" href="/index.rdf">
      <link rel="alternate" type="application/rss+xml" href="/rss.rdf">
      <a href="/plain.rdf">Plain</a>
      """
    )

    expect_bytes(context, "/index.rdf", "application/rdf+xml", rdf)
    expect_bytes(context, "/rss.rdf", "application/rss+xml", rss)
    expect_bytes(context, "/plain.rdf", "text/xml", xml)
    expect_html(context, "/post", "post")
    expect_html(context, "/from-rss", "from-rss")
    expect_html(context, "/from-xml", "from-xml")

    {opts, _root} = run(page, context, [])

    assert Store.find_processed({post, opts.scope}).body == "post"
    assert Store.find_processed({from_rss, opts.scope}).body == "from-rss"
    assert Store.find_processed({from_xml, opts.scope}).body == "from-xml"
    refute Store.find({context.url <> "/home", opts.scope})
    refute Store.find({context.url <> "/about", opts.scope})
    assert Store.ops_count(opts.scope) == 4
  end

  defp run(page, context, extra) do
    scope = unique_scope("feed")
    root = tmp(scope)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, opts} =
      start_crawl(
        page,
        Keyword.merge(
          [
            scope: scope,
            workers: 1,
            retries: 0,
            max_depths: 3,
            store: Store,
            save_to: root,
            user_agent: "Crawler/1.5.0 (test)",
            req_options: context.req_options
          ],
          extra
        )
      )

    on_exit(fn -> Crawler.stop(opts) end)
    wait(5_000, fn -> refute Crawler.running?(opts) end)
    {opts, root}
  end

  defp expect_html(context, path, body, headers \\ []) do
    ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
      conn
      |> header_list([{"content-type", "text/html"} | headers])
      |> resp(200, body)
    end)
  end

  defp expect_bytes(context, path, type, body) do
    ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
      conn
      |> put_resp_header("content-type", type)
      |> resp(200, body)
    end)
  end

  defp expect_asset(site, path, type) do
    ReqTestSite.expect_once(site, "GET", path, fn conn ->
      conn
      |> put_resp_header("content-type", type)
      |> resp(200, "asset")
    end)
  end

  defp header_list(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn ->
      put_resp_header(conn, name, value)
    end)
  end
end
