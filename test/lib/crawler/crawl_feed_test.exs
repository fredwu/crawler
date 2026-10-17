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

  defp header_list(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn ->
      put_resp_header(conn, name, value)
    end)
  end
end
