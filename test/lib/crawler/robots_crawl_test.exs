defmodule Crawler.RobotsCrawlTest do
  use Crawler.TestCase, async: false

  import Plug.Conn

  alias Crawler.Robots
  alias Crawler.Store

  test "query rules and end anchors follow the real URL", context do
    page = "#{context.url}/home"
    php = "#{context.url}/file.php"
    php_query = "#{context.url}/file.php?x=1"
    search = "#{context.url}/search"
    search_query = "#{context.url}/search?q=1"
    search_empty = "#{context.url}/search?"

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, """
      User-agent: *
      Disallow: /*.php$
      Disallow: /search?
      """)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/home", fn conn ->
      html(
        conn,
        ~s|<a href="/file.php">p</a><a href="/file.php?x=1">q</a><a href="/search">s</a><a href="/search?q=1">1</a><a href="/search?">e</a>|
      )
    end)

    ReqTestSite.expect_once(context.site, "GET", "/file.php", &html(&1, "php"))
    ReqTestSite.expect_once(context.site, "GET", "/search", &html(&1, "search"))

    opts = crawl(page, context)

    assert Store.find_processed({page, opts.scope})
    assert Store.find_processed({php_query, opts.scope}).body == "php"
    assert Store.find_processed({search, opts.scope}).body == "search"
    refute Store.find({php, opts.scope})
    refute Store.find({search_query, opts.scope})
    refute Store.find({search_empty, opts.scope})
    refute Store.find({"#{context.url}/robots.txt", opts.scope})
  end

  test "a query wildcard blocks only URLs that have a query", context do
    page = "#{context.url}/docs"
    queried = "#{context.url}/docs?x=1"

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, "User-agent: *\nDisallow: /*?\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/docs", fn conn ->
      html(conn, ~s|<a href="/docs?x=1">q</a><a href="/plain">p</a>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/plain", &html(&1, "plain"))

    opts = crawl(page, context)

    assert Store.find_processed({page, opts.scope})
    assert Store.find_processed({"#{context.url}/plain", opts.scope})
    refute Store.find({queried, opts.scope})
  end

  test "encoded robots paths block every spelling of that path", context do
    page = "#{context.url}/home"

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, """
      User-agent: *
      Disallow: /foo/%62%61%7A
      Disallow: /bar/%E3%83%84
      Disallow: /a%2Fb
      Disallow: /star/%2A
      Disallow: /price/%24
      """)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/home", fn conn ->
      html(
        conn,
        ~s|<a href="/foo/baz">b</a><a href="/bar/ツ">t</a><a href="/a/b">a</a><a href="/a%2fb">s</a><a href="/star/other">o</a><a href="/star/*">*</a><a href="/price/end">e</a><a href="/price/$">$</a><a href="/price/%24">d</a>|
      )
    end)

    ReqTestSite.expect_once(context.site, "GET", "/a/b", &html(&1, "ab"))
    ReqTestSite.expect_once(context.site, "GET", "/star/other", &html(&1, "other"))
    ReqTestSite.expect_once(context.site, "GET", "/price/end", &html(&1, "end"))

    opts = crawl(page, context)

    assert Store.find_processed({"#{context.url}/a/b", opts.scope}).body == "ab"
    assert Store.find_processed({"#{context.url}/star/other", opts.scope})
    assert Store.find_processed({"#{context.url}/price/end", opts.scope})
    refute Store.find({"#{context.url}/foo/baz", opts.scope})
    refute Store.find({"#{context.url}/bar/ツ", opts.scope})
    refute Store.find({"#{context.url}/a%2fb", opts.scope})
    refute Store.find({"#{context.url}/star/*", opts.scope})
    refute Store.find({"#{context.url}/price/$", opts.scope})
    refute Store.find({"#{context.url}/price/%24", opts.scope})
  end

  test "a robots redirect on another host applies to the original site", context do
    page = "#{context.url}/docs"
    public = "#{context.url}/public"
    private = "#{context.url}/private"

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      conn
      |> put_resp_header("location", "#{context.url2}/rules.txt")
      |> resp(302, "")
    end)

    ReqTestSite.expect_once(context.site2, "GET", "/rules.txt", fn conn ->
      resp(conn, 200, "User-agent: *\nDisallow: /private\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/docs", fn conn ->
      html(conn, ~s|<a href="/private">p</a><a href="/public">u</a>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/public", &html(&1, "public"))

    opts = crawl(page, context)

    assert Store.find_processed({page, opts.scope})
    assert Store.find_processed({public, opts.scope}).body == "public"
    refute Store.find({private, opts.scope})
    refute Store.find({"#{context.url}/robots.txt", opts.scope})
    refute Store.find({"#{context.url2}/rules.txt", opts.scope})
    assert Store.ops_count(opts.scope) == 2
  end

  test "a script asks for robots first and the redirect still limits the original site",
       context do
    scope = unique_scope("script-robots")
    script = "#{context.url}/app.js"
    page = "#{context.url}/docs"
    private = "#{context.url}/private"

    ReqTestSite.expect_once(context.site2, "GET", "/holder", fn conn ->
      html(conn, ~s|<script src="#{script}"></script>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      conn
      |> put_resp_header("location", "#{context.url2}/script-rules.txt")
      |> resp(302, "")
    end)

    ReqTestSite.expect_once(context.site2, "GET", "/script-rules.txt", fn conn ->
      resp(conn, 200, "User-agent: *\nDisallow: /private\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/app.js", fn conn ->
      conn |> put_resp_header("content-type", "text/javascript") |> resp(200, "js")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/docs", fn conn ->
      html(conn, ~s|<a href="/private">p</a>|)
    end)

    first = crawl("#{context.url2}/holder", context, assets: ["js"], scope: scope)
    assert Store.find_processed({script, first.scope}).body == "js"

    opts = crawl(page, context, scope: scope)
    assert Store.find_processed({page, opts.scope})
    refute Store.find({private, opts.scope})
    refute Store.find({"#{context.url2}/script-rules.txt", opts.scope})
  end

  test "an unreadable robots file blocks this fetch and is requested again", context do
    calls = :counters.new(1, [:atomics])

    ReqTestSite.stub(context.site, "GET", "/robots.txt", fn conn ->
      :counters.add(calls, 1, 1)
      resp(conn, 200, <<0xFF>>)
    end)

    page = "#{context.url}/blocked"
    opts = crawl(page, context)
    refute Store.find({page, opts.scope})
    assert :counters.get(calls, 1) == 1

    crawl(page, context, scope: opts.scope)
    refute Store.find({page, opts.scope})
    assert :counters.get(calls, 1) == 2
  end

  test "a gzip sitemap above the body cap is not a page", context do
    page = "#{context.url}/start"
    listed = "#{context.url}/from-sitemap"
    xml = "<urlset><url><loc>#{listed}</loc></url></urlset>" <> String.duplicate(" ", 5_000)
    gzip = :zlib.gzip(xml)
    max_body = 1_000

    assert byte_size(gzip) < max_body
    assert byte_size(xml) > max_body

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, "User-agent: *\nSitemap: #{context.url}/big.xml\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))
    ReqTestSite.expect_once(context.site, "GET", "/big.xml", &resp(&1, 200, gzip))

    opts = crawl(page, context, max_body: max_body)

    assert Store.find_processed({page, opts.scope}).body == "start"
    refute Store.find({listed, opts.scope})
    refute Store.find({"#{context.url}/big.xml", opts.scope})
  end

  test "a missing robots file still allows a private path", context do
    page = "#{context.url}/open"
    private = "#{context.url}/private"

    ReqTestSite.expect_once(context.site, "GET", "/open", fn conn ->
      html(conn, ~s|<a href="/private">p</a>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/private", &html(&1, "private"))

    opts = crawl(page, context)
    assert Store.find_processed({private, opts.scope}).body == "private"
  end

  test "a dead robots owner does not allow a page that was waiting" do
    scope = unique_scope("robots-owner")
    origin = "http://robots-owner.test"
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:claimed, Store.claim_robots(scope, origin)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:claimed, :owner}, 1_000

    waiter = Task.async(fn -> Store.claim_robots(scope, origin) end)
    wait(2_000, fn -> assert waiting_robots?(scope, origin) end)
    Process.exit(owner, :kill)

    assert {:ready, rules} = Task.await(waiter, 2_000)
    refute Robots.allowed?(rules, origin <> "/private", "Crawler/1")
    assert Store.claim_robots(scope, origin) == :owner
    assert Store.finish_robots(scope, origin, Robots.allow_all()) == :ok
  end

  test "a sitemap on another host lists only same-site pages" do
    hosts = ReqTestSite.open(hosts: 3)
    [cdn, other] = Enum.take(hosts.sites, -2)
    page = "#{hosts.url}/start"
    listed = "#{hosts.url}/from-sitemap?a=1&b=2"
    secret = "#{hosts.url}/secret"

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
      <url>
        <loc>#{String.replace(listed, "&", "&amp;")}</loc>
        <lastmod>2020-01-01</lastmod>
        <priority>0.8</priority>
        <image:image><image:loc>#{cdn.url}/pic.jpg</image:loc></image:image>
      </url>
      <url><loc>#{secret}</loc></url>
      <url><loc>#{other.url}/out</loc></url>
    </urlset>
    """

    index = """
    <sitemapindex>
      <sitemap><loc>#{cdn.url}/child.xml</loc></sitemap>
    </sitemapindex>
    """

    ReqTestSite.expect_once(hosts.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, """
      User-agent: *
      Disallow: /secret
      Sitemap: #{cdn.url}/index.xml
      """)
    end)

    ReqTestSite.expect_once(hosts.site, "GET", "/start", &html(&1, "start"))
    ReqTestSite.expect_once(cdn, "GET", "/index.xml", &resp(&1, 200, index))

    ReqTestSite.expect_once(cdn, "GET", "/child.xml", fn conn ->
      resp(conn, 200, :zlib.gzip(xml))
    end)

    ReqTestSite.expect_once(hosts.site, "GET", "/from-sitemap", &html(&1, "listed"))

    opts = crawl(page, hosts)

    assert Store.find_processed({page, opts.scope}).body == "start"
    assert Store.find_processed({listed, opts.scope}).body == "listed"
    refute Store.find({secret, opts.scope})
    refute Store.find({"#{other.url}/out", opts.scope})
    refute Store.find({"#{cdn.url}/index.xml", opts.scope})
    refute Store.find({"#{cdn.url}/child.xml", opts.scope})
    refute Store.find({"#{cdn.url}/pic.jpg", opts.scope})
    assert Store.ops_count(opts.scope) == 2
  end

  test "respect_robots false does not fetch a sitemap", context do
    calls = :counters.new(1, [:atomics])

    ReqTestSite.stub(context.site, "GET", "/robots.txt", fn conn ->
      :counters.add(calls, 1, 1)
      resp(conn, 200, "User-agent: *\nSitemap: #{context.url2}/sitemap.xml\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/quiet", &html(&1, "quiet"))

    opts = crawl("#{context.url}/quiet", context, respect_robots: false)
    assert Store.find_processed({"#{context.url}/quiet", opts.scope})
    assert :counters.get(calls, 1) == 0
  end

  defp waiting_robots?(scope, origin) do
    state = :sys.get_state(Store)
    match?({:loading, _, _, [_ | _]}, get_in(state.robots, [scope, origin]))
  end

  defp crawl(url, context, extra \\ []) do
    scope = extra[:scope] || unique_scope("robots-crawl")

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
end
