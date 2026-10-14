defmodule Crawler.SitemapCrawlTest do
  use Crawler.TestCase, async: false

  import Plug.Conn

  alias Crawler.Store

  test "prefixed xml queues a cdata address and a child sitemap", context do
    index = """
    <ns0:sitemapindex xmlns:ns0="http://www.sitemaps.org/schemas/sitemap/0.9">
      <ns0:sitemap><ns0:loc>#{context.url}/child.xml</ns0:loc></ns0:sitemap>
    </ns0:sitemapindex>
    """

    child = """
    <ns0:urlset xmlns:ns0="http://www.sitemaps.org/schemas/sitemap/0.9">
      <ns0:url>
        <ns0:loc><![CDATA[#{context.url}/a&b]]></ns0:loc>
      </ns0:url>
    </ns0:urlset>
    """

    robots(context.site, "#{context.url}/index.xml")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))
    ReqTestSite.expect_once(context.site, "GET", "/index.xml", &resp(&1, 200, index))
    ReqTestSite.expect_once(context.site, "GET", "/child.xml", &resp(&1, 200, child))
    ReqTestSite.expect_once(context.site, "GET", "/a&b", &html(&1, "ab"))

    opts = crawl("#{context.url}/start", context)

    assert Store.find_processed({"#{context.url}/a&b", opts.scope}).body == "ab"
    refute Store.find({"#{context.url}/index.xml", opts.scope})
    refute Store.find({"#{context.url}/child.xml", opts.scope})
  end

  test "an external dtd entity is not fetched", context do
    body = """
    <!DOCTYPE urlset [<!ENTITY x SYSTEM "http://evil.test/x">]>
    <urlset><url><loc>#{context.url}/safe</loc></url></urlset>
    """

    robots(context.site, "#{context.url}/sitemap.xml")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))
    ReqTestSite.expect_once(context.site, "GET", "/sitemap.xml", &resp(&1, 200, body))
    ReqTestSite.expect_once(context.site, "GET", "/safe", &html(&1, "safe"))

    opts = crawl("#{context.url}/start", context)

    assert Store.find_processed({"#{context.url}/safe", opts.scope}).body == "safe"
  end

  test "a text sitemap queues absolute urls only", context do
    body = """
    #{context.url}/plain
    #{context.url}/a&b=1

    not a url
    /relative
    """

    robots(context.site, "#{context.url}/sitemap.txt")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))
    ReqTestSite.expect_once(context.site, "GET", "/sitemap.txt", &resp(&1, 200, body))
    ReqTestSite.expect_once(context.site, "GET", "/plain", &html(&1, "plain"))
    ReqTestSite.expect_once(context.site, "GET", "/a&b=1", &html(&1, "query"))

    opts = crawl("#{context.url}/start", context)

    assert Store.find_processed({"#{context.url}/plain", opts.scope}).body == "plain"
    assert Store.find_processed({"#{context.url}/a&b=1", opts.scope}).body == "query"
  end

  test "a gzip text sitemap queues the same absolute urls", context do
    body =
      """
      #{context.url}/plain
      #{context.url}/a&b=1

      not a url
      /relative
      """

    robots(context.site, "#{context.url}/sitemap.txt")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))

    ReqTestSite.expect_once(context.site, "GET", "/sitemap.txt", fn conn ->
      resp(conn, 200, :zlib.gzip(body))
    end)

    ReqTestSite.expect_once(context.site, "GET", "/plain", &html(&1, "plain"))
    ReqTestSite.expect_once(context.site, "GET", "/a&b=1", &html(&1, "query"))

    opts = crawl("#{context.url}/start", context)

    assert Store.find_processed({"#{context.url}/plain", opts.scope}).body == "plain"
    assert Store.find_processed({"#{context.url}/a&b=1", opts.scope}).body == "query"
  end

  test "an rss item link is crawled and the channel link is not", context do
    body = """
    <rss version="2.0">
      <channel>
        <link>#{context.url}/channel</link>
        <item><link>#{context.url}/post</link></item>
      </channel>
    </rss>
    """

    robots(context.site, "#{context.url}/feed.xml")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))
    ReqTestSite.expect_once(context.site, "GET", "/feed.xml", &resp(&1, 200, body))
    ReqTestSite.expect_once(context.site, "GET", "/post", &html(&1, "post"))

    opts = crawl("#{context.url}/start", context)

    assert Store.find_processed({"#{context.url}/post", opts.scope}).body == "post"
    refute Store.find({"#{context.url}/channel", opts.scope})
  end

  test "an atom alternate link is crawled and a self link is not", context do
    body = """
    <atom:feed xmlns:atom="http://www.w3.org/2005/Atom">
      <atom:link rel="self" href="#{context.url}/feed.atom"/>
      <atom:entry>
        <atom:link rel="alternate" href="#{context.url}/entry"/>
        <atom:link rel="self" href="#{context.url}/entry.atom"/>
      </atom:entry>
    </atom:feed>
    """

    robots(context.site, "#{context.url}/feed.atom")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))
    ReqTestSite.expect_once(context.site, "GET", "/feed.atom", &resp(&1, 200, body))
    ReqTestSite.expect_once(context.site, "GET", "/entry", &html(&1, "entry"))

    opts = crawl("#{context.url}/start", context)

    assert Store.find_processed({"#{context.url}/entry", opts.scope}).body == "entry"
    refute Store.find({"#{context.url}/entry.atom", opts.scope})
  end

  test "language versions stay on the seed site" do
    hosts = ReqTestSite.open(hosts: 3)
    [cdn, other] = Enum.take(hosts.sites, -2)

    body = """
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
            xmlns:xhtml="http://www.w3.org/1999/xhtml">
      <url>
        <loc>#{hosts.url}/en</loc>
        <xhtml:link rel="alternate" hreflang="de" href="#{hosts.url}/de"/>
        <xhtml:link rel="alternate" hreflang="fr" href="#{other.url}/fr"/>
      </url>
      <url><loc>/next</loc></url>
      <url><loc>#{hosts.url}/secret</loc></url>
      <!-- <loc>#{hosts.url}/hidden</loc> -->
    </urlset>
    """

    ReqTestSite.expect_once(hosts.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, """
      User-agent: *
      Disallow: /secret
      Sitemap: #{cdn.url}/sitemap.xml
      """)
    end)

    ReqTestSite.expect(hosts.site, "GET", "/start", &html(&1, "start"))
    ReqTestSite.expect_once(cdn, "GET", "/sitemap.xml", &resp(&1, 200, body))
    ReqTestSite.expect_once(hosts.site, "GET", "/en", &html(&1, "en"))
    ReqTestSite.expect_once(hosts.site, "GET", "/de", &html(&1, "de"))

    opts = crawl("#{hosts.url}/start", hosts)

    assert Store.find_processed({"#{hosts.url}/en", opts.scope}).body == "en"
    assert Store.find_processed({"#{hosts.url}/de", opts.scope}).body == "de"
    refute Store.find({"#{hosts.url}/secret", opts.scope})
    refute Store.find({"#{hosts.url}/hidden", opts.scope})
    refute Store.find({"#{other.url}/fr", opts.scope})
    refute Store.find({"#{cdn.url}/next", opts.scope})
    refute Store.find({"#{cdn.url}/sitemap.xml", opts.scope})
    assert Store.ops_count(opts.scope) == 3

    quiet = crawl("#{hosts.url}/start", hosts, respect_robots: false)
    assert Store.find_processed({"#{hosts.url}/start", quiet.scope}).body == "start"
    refute Store.find({"#{hosts.url}/en", quiet.scope})
  end

  test "sitemap images and videos are fetched when image assets are collected", context do
    cdn = context.site2

    body = """
    <urlset xmlns:image="http://www.google.com/schemas/sitemap-image/1.1"
            xmlns:video="http://www.google.com/schemas/sitemap-video/1.1">
      <url>
        <loc>#{context.url}/gallery</loc>
        <image:image><image:loc>#{cdn.url}/pic.jpg</image:loc></image:image>
        <image:image><image:loc>/cover.jpg</image:loc></image:image>
        <video:video>
          <video:thumbnail_loc>#{cdn.url}/thumb.jpg</video:thumbnail_loc>
          <video:content_loc>#{cdn.url}/movie.mp4</video:content_loc>
          <video:player_loc>#{cdn.url}/player</video:player_loc>
          <video:title>Intro</video:title>
          <image:caption>#{cdn.url}/caption.txt</image:caption>
        </video:video>
      </url>
    </urlset>
    """

    robots(context.site, "#{context.url}/sitemap.xml")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))
    ReqTestSite.expect_once(context.site, "GET", "/sitemap.xml", &resp(&1, 200, body))
    ReqTestSite.expect_once(context.site, "GET", "/gallery", &html(&1, "gallery"))
    ReqTestSite.expect_once(cdn, "GET", "/robots.txt", &resp(&1, 404, ""))
    ReqTestSite.expect_once(cdn, "GET", "/pic.jpg", &asset(&1, "image/jpeg"))
    ReqTestSite.expect_once(context.site, "GET", "/cover.jpg", &asset(&1, "image/jpeg"))
    ReqTestSite.expect_once(cdn, "GET", "/thumb.jpg", &asset(&1, "image/jpeg"))
    ReqTestSite.expect_once(cdn, "GET", "/movie.mp4", &asset(&1, "video/mp4"))

    opts = crawl("#{context.url}/start", context, assets: ["images"])

    assert Store.find_processed({"#{context.url}/gallery", opts.scope}).body == "gallery"
    assert Store.find_processed({"#{cdn.url}/pic.jpg", opts.scope})
    assert Store.find_processed({"#{context.url}/cover.jpg", opts.scope})
    assert Store.find_processed({"#{cdn.url}/thumb.jpg", opts.scope})
    assert Store.find_processed({"#{cdn.url}/movie.mp4", opts.scope})
    refute Store.find({"#{cdn.url}/player", opts.scope})
    refute Store.find({"#{cdn.url}/caption.txt", opts.scope})
  end

  test "sitemap images are left alone when image assets are off", context do
    body = """
    <urlset xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">
      <url>
        <loc>#{context.url}/gallery</loc>
        <image:image><image:loc>#{context.url2}/pic.jpg</image:loc></image:image>
        <image:image><image:loc>/cover.jpg</image:loc></image:image>
      </url>
    </urlset>
    """

    robots(context.site, "#{context.url}/sitemap.xml")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))
    ReqTestSite.expect_once(context.site, "GET", "/sitemap.xml", &resp(&1, 200, body))
    ReqTestSite.expect_once(context.site, "GET", "/gallery", &html(&1, "gallery"))

    opts = crawl("#{context.url}/start", context)

    assert Store.find_processed({"#{context.url}/gallery", opts.scope}).body == "gallery"
    refute Store.find({"#{context.url2}/pic.jpg", opts.scope})
    refute Store.find({"#{context.url}/cover.jpg", opts.scope})
    assert Store.ops_count(opts.scope) == 2
  end

  test "a long sitemap index reaches the last child and a loop is fetched once", context do
    index =
      Enum.map_join(1..40, fn index ->
        "<sitemap><loc>#{context.url}/child-#{index}.xml</loc></sitemap>"
      end)

    child_one = """
    <urlset>
      <url><loc>#{context.url}/once</loc></url>
      <sitemap><loc>#{context.url}/index.xml</loc></sitemap>
    </urlset>
    """

    child_last = ~s(<urlset><url><loc>#{context.url}/page-40</loc></url></urlset>)

    robots(context.site, "#{context.url}/index.xml")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))

    ReqTestSite.expect_once(context.site, "GET", "/index.xml", fn conn ->
      resp(conn, 200, "<sitemapindex>#{index}</sitemapindex>")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/child-1.xml", &resp(&1, 200, child_one))
    ReqTestSite.expect_once(context.site, "GET", "/child-40.xml", &resp(&1, 200, child_last))

    for index <- 2..39 do
      ReqTestSite.expect_once(context.site, "GET", "/child-#{index}.xml", fn conn ->
        resp(conn, 200, "<urlset></urlset>")
      end)
    end

    ReqTestSite.expect_once(context.site, "GET", "/once", &html(&1, "once"))
    ReqTestSite.expect_once(context.site, "GET", "/page-40", &html(&1, "page-40"))

    opts = crawl("#{context.url}/start", context)

    assert Store.find_processed({"#{context.url}/once", opts.scope}).body == "once"
    assert Store.find_processed({"#{context.url}/page-40", opts.scope}).body == "page-40"
    refute Store.find({"#{context.url}/index.xml", opts.scope})
    refute Store.find({"#{context.url}/child-1.xml", opts.scope})
    assert Store.ops_count(opts.scope) == 3
  end

  test "finished sitemap pages are not counted twice against the budget", context do
    scope = unique_scope("sitemap-overlap")
    max_pages = 6

    index =
      Enum.map_join(1..5, fn index ->
        "<sitemap><loc>#{context.url}/overlap-#{index}.xml</loc></sitemap>"
      end)

    robots(context.site, "#{context.url}/overlap-index.xml")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))

    ReqTestSite.expect_once(context.site, "GET", "/overlap-index.xml", fn conn ->
      resp(conn, 200, "<sitemapindex>#{index}</sitemapindex>")
    end)

    for index <- 1..5 do
      page = "#{context.url}/overlap-#{index}"

      ReqTestSite.expect_once(context.site, "GET", "/overlap-#{index}.xml", fn conn ->
        if index > 1 do
          wait(4_000, fn ->
            assert Store.find_processed({"#{context.url}/overlap-#{index - 1}", scope})
          end)
        end

        resp(conn, 200, ~s(<urlset><url><loc>#{page}</loc></url></urlset>))
      end)

      ReqTestSite.expect_once(context.site, "GET", "/overlap-#{index}", &html(&1, "page"))
    end

    opts =
      crawl("#{context.url}/start", context,
        scope: scope,
        workers: 2,
        max_pages: max_pages
      )

    assert Store.find_processed({"#{context.url}/overlap-5", opts.scope})
    assert Store.ops_count(opts.scope) <= max_pages
  end

  test "disallowed sitemap urls do not use up the page budget", context do
    index = """
    <sitemapindex>
      <sitemap><loc>#{context.url}/blocked.xml</loc></sitemap>
      <sitemap><loc>#{context.url}/kept.xml</loc></sitemap>
    </sitemapindex>
    """

    blocked =
      Enum.map_join(~w(a b c), fn name ->
        "<url><loc>#{context.url}/secret-#{name}</loc></url>"
      end)

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, """
      User-agent: *
      Disallow: /secret
      Sitemap: #{context.url}/budget-index.xml
      """)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))
    ReqTestSite.expect_once(context.site, "GET", "/budget-index.xml", &resp(&1, 200, index))

    ReqTestSite.expect_once(
      context.site,
      "GET",
      "/blocked.xml",
      &resp(&1, 200, "<urlset>#{blocked}</urlset>")
    )

    ReqTestSite.expect_once(context.site, "GET", "/kept.xml", fn conn ->
      resp(conn, 200, ~s(<urlset><url><loc>#{context.url}/kept</loc></url></urlset>))
    end)

    ReqTestSite.expect_once(context.site, "GET", "/kept", &html(&1, "kept"))

    opts = crawl("#{context.url}/start", context, max_pages: 3)

    assert Store.find_processed({"#{context.url}/kept", opts.scope}).body == "kept"
    refute Store.find({"#{context.url}/secret-a", opts.scope})
    assert Store.ops_count(opts.scope) == 2
  end

  test "duplicate sitemap urls do not use up the page budget", context do
    index = """
    <sitemapindex>
      <sitemap><loc>#{context.url}/repeat.xml</loc></sitemap>
      <sitemap><loc>#{context.url}/after.xml</loc></sitemap>
    </sitemapindex>
    """

    repeated =
      Enum.map_join(1..5, fn _index ->
        "<url><loc>#{context.url}/repeat</loc></url>"
      end)

    robots(context.site, "#{context.url}/repeat-index.xml")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))
    ReqTestSite.expect_once(context.site, "GET", "/repeat-index.xml", &resp(&1, 200, index))

    ReqTestSite.expect_once(
      context.site,
      "GET",
      "/repeat.xml",
      &resp(&1, 200, "<urlset>#{repeated}</urlset>")
    )

    ReqTestSite.expect_once(context.site, "GET", "/after.xml", fn conn ->
      resp(conn, 200, ~s(<urlset><url><loc>#{context.url}/after</loc></url></urlset>))
    end)

    ReqTestSite.expect_once(context.site, "GET", "/repeat", &html(&1, "repeat"))
    ReqTestSite.expect_once(context.site, "GET", "/after", &html(&1, "after"))

    opts = crawl("#{context.url}/start", context, max_pages: 3)

    assert Store.find_processed({"#{context.url}/repeat", opts.scope}).body == "repeat"
    assert Store.find_processed({"#{context.url}/after", opts.scope}).body == "after"
    assert Store.ops_count(opts.scope) == 3
  end

  test "a small page budget does not fetch a later sitemap file", context do
    max_pages = 4

    index =
      Enum.map_join(1..6, fn index ->
        "<sitemap><loc>#{context.url}/child-#{index}.xml</loc></sitemap>"
      end)

    robots(context.site, "#{context.url}/index.xml")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))

    ReqTestSite.expect_once(context.site, "GET", "/index.xml", fn conn ->
      resp(conn, 200, "<sitemapindex>#{index}</sitemapindex>")
    end)

    for index <- 1..4 do
      ReqTestSite.expect_once(context.site, "GET", "/child-#{index}.xml", fn conn ->
        resp(conn, 200, ~s(<urlset><url><loc>#{context.url}/page-#{index}</loc></url></urlset>))
      end)
    end

    for index <- 1..3 do
      ReqTestSite.expect_once(context.site, "GET", "/page-#{index}", &html(&1, "page"))
    end

    opts = crawl("#{context.url}/start", context, max_pages: max_pages)

    assert Store.ops_count(opts.scope) <= max_pages
    assert Store.find_processed({"#{context.url}/start", opts.scope})
    assert Store.find_processed({"#{context.url}/page-1", opts.scope})
  end

  test "a sitemap server error is retried and its page is crawled", context do
    calls = :counters.new(1, [:atomics])

    robots(context.site, "#{context.url}/flaky.xml")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))

    ReqTestSite.stub(context.site, "GET", "/flaky.xml", fn conn ->
      :counters.add(calls, 1, 1)

      if :counters.get(calls, 1) == 1 do
        resp(conn, 500, "")
      else
        resp(conn, 200, ~s(<urlset><url><loc>#{context.url}/later</loc></url></urlset>))
      end
    end)

    ReqTestSite.expect_once(context.site, "GET", "/later", &html(&1, "later"))

    opts = crawl("#{context.url}/start", context, retries: 1)

    assert Store.find_processed({"#{context.url}/later", opts.scope}).body == "later"
    assert :counters.get(calls, 1) == 2
  end

  test "a utf-16 sitemap lists its page", context do
    body =
      <<0xFF, 0xFE>> <>
        :unicode.characters_to_binary(
          ~s(<urlset><url><loc>#{context.url}/wide</loc></url></urlset>),
          :utf8,
          {:utf16, :little}
        )

    robots(context.site, "#{context.url}/wide.xml")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))
    ReqTestSite.expect_once(context.site, "GET", "/wide.xml", &resp(&1, 200, body))
    ReqTestSite.expect_once(context.site, "GET", "/wide", &html(&1, "wide"))

    opts = crawl("#{context.url}/start", context)

    assert Store.find_processed({"#{context.url}/wide", opts.scope}).body == "wide"
  end

  defp robots(site, sitemap) do
    ReqTestSite.expect_once(site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, "User-agent: *\nSitemap: #{sitemap}\n")
    end)
  end

  defp crawl(url, context, extra \\ []) do
    scope = extra[:scope] || unique_scope("sitemap-crawl")

    opts =
      Keyword.merge(
        [
          store: Store,
          workers: 1,
          scope: scope,
          retries: 0,
          max_depths: 3,
          user_agent: "Crawler/1.5.0 (test)",
          req_options: context.req_options
        ],
        extra
      )

    {:ok, opts} = start_crawl(url, opts)
    await_idle(opts)
    opts
  end

  defp html(conn, body) do
    conn
    |> put_resp_header("content-type", "text/html")
    |> resp(200, body)
  end

  defp asset(conn, type) do
    conn
    |> put_resp_header("content-type", type)
    |> resp(200, "asset")
  end
end
