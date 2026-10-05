defmodule Crawler.CrawlReliabilityTest do
  use Crawler.TestCase, async: false

  import Plug.Conn

  alias Crawler.Store

  defmodule AllowAll do
    @behaviour Crawler.Fetcher.UrlFilter.Spec

    def filter(_url, _opts), do: {:ok, true}
  end

  defmodule DenySecret do
    @behaviour Crawler.Fetcher.UrlFilter.Spec

    def filter(url, _opts), do: {:ok, URI.parse(url).path != "/secret"}
  end

  test "local pages are crawled and ordinary links do not change port", context do
    page = "#{context.url}/local"
    nxt = "#{context.url}/next"
    away = "#{context.url2}/away"
    script = "#{context.url2}/app.js"

    ReqTestSite.expect_once(context.site, "GET", "/local", fn conn ->
      html(
        conn,
        ~s|<a href="/next">n</a><a href="#{away}">a</a><script src="#{script}"></script>|
      )
    end)

    ReqTestSite.expect_once(context.site, "GET", "/next", &html(&1, "next"))

    ReqTestSite.expect_once(context.site2, "GET", "/app.js", fn conn ->
      conn |> put_resp_header("content-type", "text/javascript") |> resp(200, "js")
    end)

    opts = crawl(page, context, assets: ["js"])

    assert Store.find_processed({page, opts.scope})
    assert Store.find_processed({nxt, opts.scope})
    assert Store.find_processed({script, opts.scope}).body == "js"
    refute Store.find({away, opts.scope})
  end

  test "www and default ports stay in the site while another host stays out" do
    hits = hits()
    page = "http://example.com/index"

    adapter = fn request ->
      record(hits, request)

      cond do
        request.url.path == "/robots.txt" ->
          {request, Req.Response.new(status: 404, body: "")}

        request.url.host in ["example.com", "www.example.com"] and request.url.path == "/index" ->
          {request, page_response(index_html())}

        request.url.host == "www.example.com" and request.url.path == "/about" ->
          {request, page_response("about")}

        request.url.host == "cdn.example" and request.url.path == "/app.js" ->
          {request, typed("text/javascript", "js")}

        request.url.host == "cdn.example" and request.url.path == "/app.css" ->
          {request, typed("text/css", "css")}

        request.url.host == "cdn.example" and request.url.path == "/pic.png" ->
          {request, typed("image/png", "png")}

        request.url.host == "cdn.example" and request.url.path == "/font.woff2" ->
          {request, typed("font/woff2", "font")}

        true ->
          {request, typed("text/plain", "LEAK")}
      end
    end

    opts = crawl(page, adapter_context(adapter), assets: ["js", "css", "images"])
    requested = requested(hits)

    assert Store.find_processed({page, opts.scope}).body =~ "index"
    assert Store.find_processed({"https://www.example.com/about", opts.scope})
    assert Store.find_processed({"https://cdn.example/app.js", opts.scope})
    assert Store.find_processed({"https://cdn.example/app.css", opts.scope})
    assert Store.find_processed({"https://cdn.example/pic.png", opts.scope})
    assert Store.find_processed({"https://cdn.example/font.woff2", opts.scope})
    refute Store.find({"http://blog.example.com/post", opts.scope})
    refute Store.find({"https://cdn.example/page", opts.scope})
    refute Enum.any?(requested, fn {host, _path} -> host == "blog.example.com" end)
    refute {"cdn.example", "/page"} in requested
  end

  test "a custom filter can allow another host", context do
    page = "#{context.url}/filter"
    other = "#{context.url2}/other"

    ReqTestSite.expect_once(context.site, "GET", "/filter", fn conn ->
      html(conn, ~s|<a href="#{other}">o</a>|)
    end)

    ReqTestSite.expect_once(context.site2, "GET", "/other", &html(&1, "other"))

    opts = crawl(page, context, url_filter: AllowAll)
    assert Store.find_processed({other, opts.scope}).body == "other"
  end

  test "a custom filter can deny a same-site path", context do
    page = "#{context.url}/guard"
    secret = "#{context.url}/secret"
    nxt = "#{context.url}/guard-next"

    ReqTestSite.expect_once(context.site, "GET", "/guard", fn conn ->
      html(conn, ~s|<a href="/secret">s</a><a href="/guard-next">n</a>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/guard-next", &html(&1, "next"))

    opts = crawl(page, context, url_filter: DenySecret)
    assert Store.find_processed({nxt, opts.scope})
    refute Store.find({secret, opts.scope})
  end

  test "a robots server error blocks the page and is requested again", context do
    calls = :counters.new(1, [:atomics])

    ReqTestSite.expect(context.site, "GET", "/robots.txt", fn conn ->
      :counters.add(calls, 1, 1)
      resp(conn, 500, "")
    end)

    page = "#{context.url}/blocked"
    opts = crawl(page, context)
    refute Store.find({page, opts.scope})
    assert :counters.get(calls, 1) == 1

    crawl(page, context, scope: opts.scope)
    refute Store.find({page, opts.scope})
    assert :counters.get(calls, 1) == 2
  end

  test "a missing robots file still crawls the site", context do
    page = "#{context.url}/open"
    nxt = "#{context.url}/open-next"

    ReqTestSite.expect_once(
      context.site,
      "GET",
      "/open",
      &html(&1, ~s|<a href="/open-next">n</a>|)
    )

    ReqTestSite.expect_once(context.site, "GET", "/open-next", &html(&1, "next"))

    opts = crawl(page, context)
    assert Store.find_processed({nxt, opts.scope})
    refute Store.find({"#{context.url}/robots.txt", opts.scope})
  end

  test "the crawler group replaces star rules and a robots fetch is not a page", context do
    page = "#{context.url}/docs"
    secret = "#{context.url}/secret"
    hidden = "#{context.url}/hidden"
    visible = "#{context.url}/docs/public"

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, """
      User-agent: *
      Disallow: /secret
      Allow: /docs/public

      User-agent: Googlebot
      Disallow: /

      User-agent: Crawler
      Disallow: /hidden
      Allow: /docs/public
      """)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/docs", fn conn ->
      html(conn, ~s|<a href="/secret">s</a><a href="/hidden">h</a><a href="/docs/public">p</a>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/secret", &html(&1, "secret"))
    ReqTestSite.expect_once(context.site, "GET", "/docs/public", &html(&1, "public"))

    opts = crawl(page, context, max_pages: 3)

    assert Store.find_processed({page, opts.scope})
    assert Store.find_processed({secret, opts.scope}).body == "secret"
    assert Store.find_processed({visible, opts.scope}).body == "public"
    refute Store.find({hidden, opts.scope})
    refute Store.find({"#{context.url}/robots.txt", opts.scope})
    assert Store.ops_count(opts.scope) == 3
  end

  test "star rules apply when the product token does not match", context do
    page = "#{context.url}/home"

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, "User-agent: *\nDisallow: /secret\nAllow: /docs/public\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/home", fn conn ->
      html(conn, ~s|<a href="/secret">s</a><a href="/docs/public">p</a>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/docs/public", &html(&1, "public"))

    opts = crawl(page, context, user_agent: "CrawlerBot/1.0")
    assert Store.find_processed({"#{context.url}/docs/public", opts.scope})
    refute Store.find({"#{context.url}/secret", opts.scope})
  end

  test "one origin fetches robots.txt once while several workers wait", context do
    parent = self()
    scope = unique_scope("robots-flight")

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      send(parent, {:robots, self()})
      assert_receive :release, 5_000
      resp(conn, 200, "User-agent: *\nAllow: /\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/flight-a", &html(&1, "a"))
    ReqTestSite.expect_once(context.site, "GET", "/flight-b", &html(&1, "b"))

    {:ok, first} =
      start_crawl("#{context.url}/flight-a",
        store: Store,
        workers: 1,
        scope: scope,
        req_options: context.req_options
      )

    assert_receive {:robots, pid}, 1_000

    {:ok, second} =
      start_crawl("#{context.url}/flight-b",
        store: Store,
        workers: 1,
        scope: scope,
        req_options: context.req_options
      )

    refute_receive {:robots, _pid}, 200
    send(pid, :release)
    await_idle(first)
    await_idle(second)
    assert Store.find_processed({"#{context.url}/flight-a", scope})
    assert Store.find_processed({"#{context.url}/flight-b", scope})
  end

  test "a new scope and a reset scope do not reuse robots rules", context do
    calls = :counters.new(1, [:atomics])

    ReqTestSite.expect(context.site, "GET", "/robots.txt", fn conn ->
      :counters.add(calls, 1, 1)

      body =
        if :counters.get(calls, 1) == 1 do
          "User-agent: *\nDisallow: /shared-next\n"
        else
          "User-agent: *\nAllow: /\n"
        end

      resp(conn, 200, body)
    end)

    ReqTestSite.expect(
      context.site,
      "GET",
      "/shared",
      &html(&1, ~s|<a href="/shared-next">n</a>|)
    )

    ReqTestSite.stub(context.site, "GET", "/shared-next", &html(&1, "next"))

    first = crawl("#{context.url}/shared", context)
    refute Store.find({"#{context.url}/shared-next", first.scope})

    second = crawl("#{context.url}/shared", context, scope: unique_scope("robots-scope"))
    assert Store.find_processed({"#{context.url}/shared-next", second.scope})

    third = crawl("#{context.url}/shared", context, scope: first.scope, force: true)
    assert Store.find_processed({"#{context.url}/shared-next", third.scope})
    assert :counters.get(calls, 1) == 3
  end

  test "nofollow skips navigation and still fetches scripts", context do
    page = "#{context.url}/quiet"
    script = "#{context.url}/quiet.js"

    ReqTestSite.expect_once(context.site, "GET", "/quiet", fn conn ->
      conn
      |> put_resp_header("content-type", "text/html")
      |> put_resp_header("x-robots-tag", "nofollow")
      |> resp(
        200,
        ~s|<a href="/quiet-next">n</a><meta http-equiv="refresh" content="0; url=/jump"><script src="/quiet.js"></script>|
      )
    end)

    ReqTestSite.expect_once(context.site, "GET", "/quiet.js", fn conn ->
      conn |> put_resp_header("content-type", "text/javascript") |> resp(200, "js")
    end)

    opts = crawl(page, context, assets: ["js"])
    assert Store.find_processed({page, opts.scope})
    assert Store.find_processed({script, opts.scope})
    refute Store.find({"#{context.url}/quiet-next", opts.scope})
    refute Store.find({"#{context.url}/jump", opts.scope})
  end

  test "meta robots nofollow is limited to the named crawler", context do
    page = "#{context.url}/meta"

    ReqTestSite.expect_once(context.site, "GET", "/meta", fn conn ->
      html(conn, ~s|<meta name="googlebot" content="nofollow"><a href="/meta-next">n</a>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/meta-next", &html(&1, "next"))

    ReqTestSite.expect_once(context.site, "GET", "/named", fn conn ->
      html(
        conn,
        ~s|<meta name="crawler" content="none"><a href="/named-next">n</a><script src="/named.js"></script>|
      )
    end)

    ReqTestSite.expect_once(context.site, "GET", "/named.js", fn conn ->
      conn |> put_resp_header("content-type", "text/javascript") |> resp(200, "js")
    end)

    opts = crawl(page, context, assets: ["js"])
    assert Store.find_processed({"#{context.url}/meta-next", opts.scope})

    named =
      crawl("#{context.url}/named", context,
        assets: ["js"],
        scope: unique_scope("named-nofollow")
      )

    refute Store.find({"#{context.url}/named-next", named.scope})
    assert Store.find_processed({"#{context.url}/named.js", named.scope})
  end

  test "rel nofollow skips the link and noreferrer does not", context do
    page = "#{context.url}/rel"

    ReqTestSite.expect_once(context.site, "GET", "/rel", fn conn ->
      html(
        conn,
        ~s|<a href="/rel-next" rel="noreferrer">n</a><a href="/rel-secret" rel="nofollow">s</a><svg><a href="/svg-next">n</a><a href="/svg-secret" rel="nofollow">s</a></svg>|
      )
    end)

    ReqTestSite.expect_once(context.site, "GET", "/rel-next", &html(&1, "next"))
    ReqTestSite.expect_once(context.site, "GET", "/svg-next", &html(&1, "svg"))

    opts = crawl(page, context)
    assert Store.find_processed({"#{context.url}/rel-next", opts.scope})
    assert Store.find_processed({"#{context.url}/svg-next", opts.scope})
    refute Store.find({"#{context.url}/rel-secret", opts.scope})
    refute Store.find({"#{context.url}/svg-secret", opts.scope})
  end

  test "respect_robots false follows a disallowed path and a nofollow link", context do
    page = "#{context.url}/ignore"
    robots = :counters.new(1, [:atomics])

    ReqTestSite.stub(context.site, "GET", "/robots.txt", fn conn ->
      :counters.add(robots, 1, 1)
      resp(conn, 200, "User-agent: *\nDisallow: /ignore-secret\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/ignore", fn conn ->
      html(conn, ~s|<a href="/ignore-secret" rel="nofollow">s</a>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/ignore-secret", &html(&1, "secret"))

    opts = crawl(page, context, respect_robots: false)
    assert Store.find_processed({"#{context.url}/ignore-secret", opts.scope}).body == "secret"
    refute Store.find({"#{context.url}/robots.txt", opts.scope})
    assert :counters.get(robots, 1) == 0
  end

  defp crawl(url, context, extra \\ []) do
    scope = extra[:scope] || unique_scope("reliability")

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

  defp page_response(body), do: typed("text/html", body)

  defp typed(type, body),
    do: Req.Response.new(status: 200, headers: [{"content-type", type}], body: body)

  defp index_html do
    """
    <a href="https://www.example.com/about">about</a>
    <a href="http://blog.example.com/post">blog</a>
    <a href="https://cdn.example/page">cdn</a>
    <script src="https://cdn.example/app.js"></script>
    <link rel="stylesheet" href="https://cdn.example/app.css">
    <img src="https://cdn.example/pic.png">
    <link rel="preload" as="font" href="https://cdn.example/font.woff2">
    index
    """
  end

  defp adapter_context(adapter), do: %{req_options: [adapter: adapter, retry: false]}

  defp hits do
    {:ok, hits} = Agent.start_link(fn -> [] end)
    hits
  end

  defp record(hits, request) do
    Agent.update(hits, &[{request.url.host, request.url.path} | &1])
  end

  defp requested(hits), do: Agent.get(hits, & &1)
end
