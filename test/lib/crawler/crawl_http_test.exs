defmodule Crawler.CrawlHTTPTest do
  use Crawler.TestCase, async: false

  import Plug.Conn

  alias Crawler.Linker
  alias Crawler.Linker.Snapshot
  alias Crawler.Store

  defmodule SecretModifier do
    @behaviour Crawler.Fetcher.Modifier.Spec

    def headers(_opts), do: [{"cookie", "user=from-user"}, {"x-secret", "top-secret"}]
    def opts(_opts), do: [auth: {:bearer, "from-auth"}]
  end

  defmodule AllowAll do
    @behaviour Crawler.Fetcher.UrlFilter.Spec

    def filter(_url, _opts), do: {:ok, true}
  end

  @session "abc-secret-value"

  test "cookies are sent only to the matching host and path" do
    hits = hits()

    adapter = fn request ->
      record(hits, request)

      cond do
        request.url.path == "/robots.txt" ->
          {request, Req.Response.new(status: 404, body: "")}

        request.url.host == "example.com" and request.url.path == "/cookie" ->
          {request, cookie_page()}

        request.url.host == "example.com" and request.url.path == "/cookie-page" ->
          {request, typed("text/html", "page")}

        request.url.host == "example.com" and request.url.path == "/admin/home" ->
          {request, typed("text/html", "admin")}

        request.url.host == "foreign.test" and request.url.path == "/foreign" ->
          {request, typed("text/html", "foreign")}

        true ->
          {request, typed("text/plain", "LEAK")}
      end
    end

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        crawl("http://example.com/cookie", adapter_context(adapter), url_filter: AllowAll)
      end)

    assert hop(hits, "example.com", "/cookie-page").cookie == %{"session" => @session}

    assert hop(hits, "example.com", "/admin/home").cookie == %{
             "session" => @session,
             "admin" => "1"
           }

    assert hop(hits, "foreign.test", "/foreign").cookie == %{}
    refute log =~ @session
  end

  test "a second scope and a reset scope do not keep cookies", context do
    parent = self()

    ReqTestSite.expect(context.site, "GET", "/jar", fn conn ->
      report(parent, conn)

      conn
      |> put_resp_header("set-cookie", "session=#{@session}; Path=/")
      |> html(~s|<a href="/jar-next">n</a>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/jar-next", fn conn ->
      report(parent, conn)
      html(conn, "next")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/jar-other", fn conn ->
      report(parent, conn)
      html(conn, "other")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/jar-again", fn conn ->
      report(parent, conn)
      html(conn, "again")
    end)

    first = crawl("#{context.url}/jar", context)
    assert cookie_map(received!("/jar-next")) == %{"session" => @session}

    crawl("#{context.url}/jar-other", context, scope: unique_scope("cookie-scope"))
    assert received!("/jar-other") == []

    crawl("#{context.url}/jar-again", context, scope: first.scope, force: true)
    assert received!("/jar-again") == []
  end

  test "a same-host redirect keeps user headers and jar cookies" do
    hits = hits()

    adapter = fn request ->
      record(hits, request)

      case request.url.path do
        "/robots.txt" ->
          {request, Req.Response.new(status: 404, body: "")}

        "/start" ->
          {request, redirect("http://example.com/land", "session=#{@session}; Path=/")}

        "/land" ->
          {request, typed("text/html", "land")}
      end
    end

    crawl("http://example.com/start", adapter_context(adapter), modifier: SecretModifier)

    assert hop(hits, "example.com", "/land") == %{
             cookie: %{"user" => "from-user", "session" => @session},
             secret: "top-secret",
             authorization: "Bearer from-auth"
           }
  end

  test "a redirect to another host drops user headers and keeps a matching domain cookie" do
    hits = hits()

    adapter = fn request ->
      record(hits, request)

      cond do
        request.url.path == "/robots.txt" ->
          {request, Req.Response.new(status: 404, body: "")}

        request.url.host == "example.com" and request.url.path == "/start" ->
          {request,
           redirect(
             "https://www.example.com/land",
             "session=#{@session}; Domain=example.com; Path=/"
           )}

        request.url.host == "www.example.com" ->
          {request, typed("text/html", "land")}

        true ->
          {request, typed("text/plain", "LEAK")}
      end
    end

    crawl("http://example.com/start", adapter_context(adapter), modifier: SecretModifier)

    assert hop(hits, "www.example.com", "/land") == %{
             cookie: %{"session" => @session},
             secret: nil,
             authorization: nil
           }

    refute Enum.any?(requested(hits), fn {host, _path, _cookie, _secret, _authorization} ->
             host == "other.test"
           end)
  end

  test "an allowed redirect to a different site drops cookies and custom headers" do
    hits = hits()

    adapter = fn request ->
      record(hits, request)

      cond do
        request.url.path == "/robots.txt" ->
          {request, Req.Response.new(status: 404, body: "")}

        request.url.path == "/start" ->
          {request, redirect("http://other.test/land", "session=#{@session}; Path=/")}

        request.url.host == "other.test" ->
          {request, typed("text/html", "land")}
      end
    end

    crawl("http://example.com/start", adapter_context(adapter),
      modifier: SecretModifier,
      url_filter: AllowAll
    )

    assert hop(hits, "other.test", "/land") == %{
             cookie: %{},
             secret: nil,
             authorization: nil
           }
  end

  test "a secure cookie is not sent after a redirect to http" do
    hits = hits()

    adapter = fn request ->
      record(hits, request)

      case {request.url.scheme, request.url.path} do
        {_, "/robots.txt"} ->
          {request, Req.Response.new(status: 404, body: "")}

        {"https", "/secure"} ->
          {request,
           redirect("http://example.com/secure-land", "session=#{@session}; Secure; Path=/")}

        {"http", "/secure-land"} ->
          {request, typed("text/html", "land")}
      end
    end

    crawl("https://example.com/secure", adapter_context(adapter), modifier: SecretModifier)

    assert hop(hits, "example.com", "/secure-land") == %{
             cookie: %{"user" => "from-user"},
             secret: "top-secret",
             authorization: "Bearer from-auth"
           }
  end

  test "a same-host redirect to http does not repeat a secure cookie" do
    hits = hits()

    adapter = fn request ->
      record(hits, request)

      case {request.url.scheme, request.url.path} do
        {_, "/robots.txt"} ->
          {request, Req.Response.new(status: 404, body: "")}

        {"https", "/secure"} ->
          {request,
           redirect("https://example.com/secure-next", "session=#{@session}; Secure; Path=/")}

        {"https", "/secure-next"} ->
          {request, redirect_to("http://example.com/secure-land")}

        {"http", "/secure-land"} ->
          {request, typed("text/html", "land")}
      end
    end

    crawl("https://example.com/secure", adapter_context(adapter), modifier: SecretModifier)

    assert hop(hits, "example.com", "/secure-next").cookie == %{
             "user" => "from-user",
             "session" => @session
           }

    assert hop(hits, "example.com", "/secure-land") == %{
             cookie: %{"user" => "from-user"},
             secret: "top-secret",
             authorization: "Bearer from-auth"
           }
  end

  test "a same-host redirect does not send a cookie outside its path" do
    hits = hits()

    adapter = fn request ->
      record(hits, request)

      case request.url.path do
        "/robots.txt" ->
          {request, Req.Response.new(status: 404, body: "")}

        "/admin" ->
          {request, redirect("http://example.com/admin/next", "admin=1; Path=/admin")}

        "/admin/next" ->
          {request, redirect_to("http://example.com/outside")}

        "/outside" ->
          {request, typed("text/html", "outside")}
      end
    end

    crawl("http://example.com/admin", adapter_context(adapter), modifier: SecretModifier)

    assert hop(hits, "example.com", "/admin/next").cookie == %{
             "user" => "from-user",
             "admin" => "1"
           }

    assert hop(hits, "example.com", "/outside").cookie == %{"user" => "from-user"}
  end

  test "a same-host redirect does not send a cookie the response deletes" do
    hits = hits()

    adapter = fn request ->
      record(hits, request)

      case request.url.path do
        "/robots.txt" ->
          {request, Req.Response.new(status: 404, body: "")}

        "/once" ->
          {request, redirect("http://example.com/once-next", "session=#{@session}; Path=/")}

        "/once-next" ->
          {request,
           redirect("http://example.com/once-land", "session=#{@session}; Max-Age=0; Path=/")}

        "/once-land" ->
          {request, typed("text/html", "land")}
      end
    end

    crawl("http://example.com/once", adapter_context(adapter), modifier: SecretModifier)

    assert hop(hits, "example.com", "/once-next").cookie == %{
             "user" => "from-user",
             "session" => @session
           }

    assert hop(hits, "example.com", "/once-land").cookie == %{"user" => "from-user"}
  end

  test "a response after the scope is reset does not restore cookies" do
    hits = hits()
    scope = unique_scope("cookie-reset")

    adapter = fn request ->
      record(hits, request)

      cond do
        request.url.path == "/robots.txt" ->
          {request, Req.Response.new(status: 404, body: "")}

        request.url.path == "/reset" ->
          Store.drop_scope(scope)

          {request,
           Req.Response.new(
             status: 200,
             headers: [
               {"content-type", "text/html"},
               {"set-cookie", "session=#{@session}; Path=/"}
             ],
             body: "reset"
           )}

        request.url.path == "/after" ->
          {request, typed("text/html", "after")}
      end
    end

    crawl("http://example.com/reset", adapter_context(adapter), scope: scope)
    assert Store.cookie_header(scope, "http://example.com/after") == nil

    crawl("http://example.com/after", adapter_context(adapter), scope: scope)
    assert hop(hits, "example.com", "/after").cookie == %{}
  end

  test "a gzip page is stored and followed as html", context do
    body = ~s|<a href="/gzip-next">Next</a>|
    root = tmp(unique_scope("gzip-page"))

    ReqTestSite.expect_once(context.site, "GET", "/gzip", fn conn ->
      conn
      |> put_resp_header("content-type", "text/html")
      |> put_resp_header("content-encoding", "gzip")
      |> resp(200, :zlib.gzip(body))
    end)

    ReqTestSite.expect_once(context.site, "GET", "/gzip-next", &html(&1, "next"))

    opts = crawl("#{context.url}/gzip", context, save_to: root)
    saved = File.read!(Path.join(root, Snapshot.path("#{context.url}/gzip")))

    assert Store.find_processed({"#{context.url}/gzip", opts.scope}).body == body
    assert saved =~ "Next"
    refute String.starts_with?(saved, <<31, 139>>)
    assert Store.find_processed({"#{context.url}/gzip-next", opts.scope})
  end

  test "a double gzip page is stored and followed as html", context do
    body = ~s|<a href="/nested-next">Next</a>|
    root = tmp(unique_scope("nested-gzip"))

    ReqTestSite.expect_once(context.site, "GET", "/nested", fn conn ->
      conn
      |> put_resp_header("content-type", "text/html")
      |> put_resp_header("content-encoding", "gzip, gzip")
      |> resp(200, :zlib.gzip(:zlib.gzip(body)))
    end)

    ReqTestSite.expect_once(context.site, "GET", "/nested-next", &html(&1, "next"))

    opts = crawl("#{context.url}/nested", context, save_to: root)
    saved = File.read!(Path.join(root, Snapshot.path("#{context.url}/nested")))

    assert Store.find_processed({"#{context.url}/nested", opts.scope}).body == body
    assert saved =~ "Next"
    refute String.starts_with?(saved, <<31, 139>>)
    assert Store.find_processed({"#{context.url}/nested-next", opts.scope})
  end

  test "refresh and link headers are followed like the same tags", context do
    ReqTestSite.expect_once(context.site, "GET", "/headers", fn conn ->
      conn
      |> put_resp_header("content-type", "text/html")
      |> put_resp_header("refresh", "0; url=/headers-next")
      |> put_resp_header(
        "link",
        ~s|</headers-app.css>; rel="stylesheet", </headers-extra.css>; rel="stylesheet", <https://other.test/page>; rel="next"|
      )
      |> resp(200, "<p>Hello</p>")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/headers-next", &html(&1, "next"))

    for path <- ["/headers-app.css", "/headers-extra.css"] do
      ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
        conn |> put_resp_header("content-type", "text/css") |> resp(200, "")
      end)
    end

    opts = crawl("#{context.url}/headers", context, assets: ["css"])

    assert Store.find_processed({"#{context.url}/headers-next", opts.scope})
    assert Store.find_processed({"#{context.url}/headers-app.css", opts.scope})
    assert Store.find_processed({"#{context.url}/headers-extra.css", opts.scope})
    refute Store.find({"https://other.test/page", opts.scope})
  end

  test "preload link headers are followed like the same tags", context do
    ReqTestSite.expect_once(context.site, "GET", "/preload-page", fn conn ->
      conn
      |> put_resp_header("content-type", "text/html")
      |> put_resp_header(
        "link",
        ~s|</preload.css>; rel=preload; as=style, </hero.png>; rel=preload; as=image; imagesrcset="a.png 1x, b.png 2x"|
      )
      |> resp(200, "<p>Hello</p>")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/preload.css", fn conn ->
      conn |> put_resp_header("content-type", "text/css") |> resp(200, "")
    end)

    for path <- ["/hero.png", "/a.png", "/b.png"] do
      ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
        conn |> put_resp_header("content-type", "image/png") |> resp(200, "png")
      end)
    end

    opts = crawl("#{context.url}/preload-page", context, assets: ["css", "images"])

    assert Store.find_processed({"#{context.url}/preload.css", opts.scope})
    assert Store.find_processed({"#{context.url}/hero.png", opts.scope})
    assert Store.find_processed({"#{context.url}/a.png", opts.scope})
    assert Store.find_processed({"#{context.url}/b.png", opts.scope})
  end

  test "repeated link header fields are all followed", context do
    ReqTestSite.expect_once(context.site, "GET", "/fields", fn conn ->
      conn
      |> put_resp_header("content-type", "text/html")
      |> prepend_resp_headers([
        {"link", ~s|</fields-app.css>; rel="stylesheet"|},
        {"link", ~s|</fields-extra.css>; rel="stylesheet"|}
      ])
      |> resp(200, "<p>Hello</p>")
    end)

    for path <- ["/fields-app.css", "/fields-extra.css"] do
      ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
        conn |> put_resp_header("content-type", "text/css") |> resp(200, "")
      end)
    end

    opts = crawl("#{context.url}/fields", context, assets: ["css"])

    assert Store.find_processed({"#{context.url}/fields-app.css", opts.scope})
    assert Store.find_processed({"#{context.url}/fields-extra.css", opts.scope})
  end

  test "a cross-site refresh header is not fetched", context do
    ReqTestSite.expect_once(context.site, "GET", "/offsite", fn conn ->
      conn
      |> put_resp_header("content-type", "text/html")
      |> put_resp_header("refresh", "0; url=https://other.test/out")
      |> resp(200, "<p>Hello</p>")
    end)

    opts = crawl("#{context.url}/offsite", context)
    refute Store.find({"https://other.test/out", opts.scope})
  end

  test "nofollow skips a refresh header and still fetches its stylesheet", context do
    ReqTestSite.expect_once(context.site, "GET", "/quiet", fn conn ->
      conn
      |> put_resp_header("content-type", "text/html")
      |> put_resp_header("x-robots-tag", "nofollow")
      |> put_resp_header("refresh", "0; url=/secret")
      |> put_resp_header("link", ~s|</stay.css>; rel="stylesheet"|)
      |> resp(200, "<p>Hello</p>")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/stay.css", fn conn ->
      conn |> put_resp_header("content-type", "text/css") |> resp(200, "")
    end)

    opts = crawl("#{context.url}/quiet", context, assets: ["css"])

    refute Store.find({"#{context.url}/secret", opts.scope})
    assert Store.find_processed({"#{context.url}/stay.css", opts.scope})
  end

  test "refresh and link headers on a stylesheet are not followed", context do
    ReqTestSite.expect_once(context.site, "GET", "/sheet.css", fn conn ->
      conn
      |> put_resp_header("content-type", "text/css")
      |> put_resp_header("refresh", "0; url=/sheet-next")
      |> put_resp_header("link", ~s|</sheet-extra.css>; rel="stylesheet"|)
      |> resp(200, "body{}")
    end)

    opts = crawl("#{context.url}/sheet.css", context, assets: ["css"])

    assert Store.find_processed({"#{context.url}/sheet.css", opts.scope})
    refute Store.find({"#{context.url}/sheet-next", opts.scope})
    refute Store.find({"#{context.url}/sheet-extra.css", opts.scope})
  end

  test "responses above the decoded cap are not stored", context do
    root = tmp(unique_scope("body-cap"))
    small = String.duplicate("a", 100)
    large = String.duplicate("b", 2_000)
    gzip = :zlib.gzip(String.duplicate(<<0>>, 10_000))

    ReqTestSite.expect_once(context.site, "GET", "/small", fn conn ->
      conn |> put_resp_header("content-type", "text/plain") |> resp(200, small)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/large", fn conn ->
      conn |> put_resp_header("content-type", "text/html") |> resp(200, large)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/expanded", fn conn ->
      conn
      |> put_resp_header("content-type", "text/html")
      |> put_resp_header("content-encoding", "gzip")
      |> resp(200, gzip)
    end)

    opts = crawl("#{context.url}/small", context, max_body: 1_000, save_to: root)
    assert Store.find_processed({"#{context.url}/small", opts.scope}).body == small

    crawl("#{context.url}/large", context, max_body: 1_000, save_to: root, scope: opts.scope)
    refute Store.find({"#{context.url}/large", opts.scope})
    refute File.exists?(Path.join(root, Snapshot.path("#{context.url}/large")))

    crawl("#{context.url}/expanded", context, max_body: 1_000, save_to: root, scope: opts.scope)
    refute Store.find({"#{context.url}/expanded", opts.scope})
    refute File.exists?(Path.join(root, Snapshot.path("#{context.url}/expanded")))
  end

  test "a missing content type is stored unchanged and is not parsed", context do
    body = <<137, 80, 78, 71>> <> ~s|<a href="/missing-next">Next</a>|
    root = tmp(unique_scope("missing-type"))

    ReqTestSite.expect_once(context.site, "GET", "/missing", &resp(&1, 200, body))

    opts = crawl("#{context.url}/missing", context, save_to: root)
    saved = File.read!(Path.join(root, Snapshot.path("#{context.url}/missing")))

    assert Store.find_processed({"#{context.url}/missing", opts.scope}).body == body
    assert saved == body
    refute Store.find({"#{context.url}/missing-next", opts.scope})
  end

  test "html, css, and javascript responses keep their existing behaviour", context do
    raw = "import './chunk.js'; const label='caf" <> <<0xE9>> <> "';"

    ReqTestSite.expect_once(context.site, "GET", "/typed", fn conn ->
      html(conn, ~s|<a href="/typed-next">n</a>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/typed-next", &html(&1, "next"))

    ReqTestSite.expect_once(context.site, "GET", "/typed.css", fn conn ->
      conn
      |> put_resp_header("content-type", "text/css")
      |> resp(200, "a{background:url(pic.png)}")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/pic.png", fn conn ->
      conn |> put_resp_header("content-type", "image/png") |> resp(200, "png")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/typed.js", fn conn ->
      conn
      |> put_resp_header("content-type", "text/javascript; charset=latin1")
      |> resp(200, raw)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/chunk.js", fn conn ->
      conn |> put_resp_header("content-type", "text/javascript") |> resp(200, "chunk")
    end)

    html_opts = crawl("#{context.url}/typed", context, assets: ["js", "images"])
    assert Store.find_processed({"#{context.url}/typed-next", html_opts.scope})

    css_opts =
      crawl("#{context.url}/typed.css", context,
        assets: ["images"],
        scope: unique_scope("typed-css")
      )

    assert Store.find_processed({"#{context.url}/pic.png", css_opts.scope}).body == "png"

    js_opts =
      crawl("#{context.url}/typed.js", context, assets: ["js"], scope: unique_scope("typed-js"))

    assert Store.find_processed({"#{context.url}/typed.js", js_opts.scope}).body =~ "café"
    assert Store.find_processed({"#{context.url}/chunk.js", js_opts.scope})
  end

  test "status 200 and 203 are stored and followed", context do
    for {path, status} <- [{"/ok", 200}, {"/non-authoritative", 203}] do
      ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
        conn
        |> put_resp_header("content-type", "text/html")
        |> resp(status, ~s|<a href="#{path}-next">n</a>|)
      end)

      ReqTestSite.expect_once(context.site, "GET", path <> "-next", &html(&1, "next"))
    end

    ok = crawl("#{context.url}/ok", context)
    assert Store.find_processed({"#{context.url}/ok-next", ok.scope})

    other = crawl("#{context.url}/non-authoritative", context, scope: unique_scope("status-203"))

    assert Store.find_processed({"#{context.url}/non-authoritative", other.scope}).body =~
             "non-authoritative"

    assert Store.find_processed({"#{context.url}/non-authoritative-next", other.scope})
  end

  test "status 204, 206, and 404 are not stored or followed", context do
    for {path, status} <- [{"/empty", 204}, {"/partial", 206}, {"/missing-page", 404}] do
      calls = :counters.new(1, [:atomics])

      ReqTestSite.expect(context.site, "GET", path, fn conn ->
        :counters.add(calls, 1, 1)

        conn
        |> put_resp_header("content-type", "text/html")
        |> resp(status, ~s|<a href="#{path}-next">n</a>|)
      end)

      opts =
        crawl("#{context.url}#{path}", context,
          retries: 2,
          scope: unique_scope("status-#{status}")
        )

      refute Store.find({"#{context.url}#{path}", opts.scope})
      refute Store.find({"#{context.url}#{path}-next", opts.scope})
      assert :counters.get(calls, 1) == 1
    end
  end

  test "status 408, 429, and 500 are retried", context do
    for status <- [408, 429, 500] do
      path = "/retry-#{status}"
      calls = :counters.new(1, [:atomics])

      ReqTestSite.expect(context.site, "GET", path, fn conn ->
        :counters.add(calls, 1, 1)

        conn
        |> put_resp_header("content-type", "text/html")
        |> resp(status, ~s|<a href="#{path}-next">n</a>|)
      end)

      opts =
        crawl("#{context.url}#{path}", context,
          retries: 1,
          scope: unique_scope("retry-#{status}")
        )

      refute Store.find({"#{context.url}#{path}", opts.scope})
      refute Store.find({"#{context.url}#{path}-next", opts.scope})
      assert :counters.get(calls, 1) == 2
    end
  end

  test "javascript types with a charset parameter are fetched and rewritten", context do
    page = "#{context.url}/scripts/page"
    root = tmp(unique_scope("script-mime"))

    ReqTestSite.expect_once(context.site, "GET", "/scripts/page", fn conn ->
      html(conn, """
      <script type="text/javascript; charset=utf-8" src="app.js"></script>
      <script type="text/javascript; charset=utf-8">import './chunk.js';</script>
      <script type="module" src="mod.js"></script>
      <script type=" text/javascript " src="classic.js"></script>
      <script type="module;charset=utf-8" src="nope.js"></script>
      <script type="application/json" src="data.json"></script>
      <script type="&#160;text/javascript&#160;" src="nbsp.js"></script>
      """)
    end)

    for name <- ["app.js", "chunk.js", "mod.js", "classic.js"] do
      ReqTestSite.expect_once(context.site, "GET", "/scripts/#{name}", fn conn ->
        conn |> put_resp_header("content-type", "text/javascript") |> resp(200, name)
      end)
    end

    opts = crawl(page, context, assets: ["js"], save_to: root)
    saved = File.read!(Path.join(root, Snapshot.path(page)))

    assert Store.find_processed({"#{context.url}/scripts/app.js", opts.scope})
    assert Store.find_processed({"#{context.url}/scripts/chunk.js", opts.scope})
    assert saved =~ Linker.offline_link(page, "#{context.url}/scripts/app.js")
    assert saved =~ Linker.offline_link(page, "#{context.url}/scripts/chunk.js")
    assert saved =~ ~s|src="nope.js"|
    assert saved =~ ~s|src="data.json"|
    assert saved =~ ~s|src="nbsp.js"|
    refute Store.find({"#{context.url}/scripts/nope.js", opts.scope})
  end

  test "a direct fetch keeps caller credentials only on the seed host" do
    hits = hits()

    adapter = fn request ->
      record(hits, request)

      cond do
        request.url.host == "example.com" and request.url.path == "/robots.txt" ->
          {request,
           Req.Response.new(
             status: 200,
             body: "User-agent: *\nAllow: /\n\nSitemap: https://files.test/sitemap.xml\n"
           )}

        request.url.host == "files.test" and request.url.path == "/sitemap.xml" ->
          {request, Req.Response.new(status: 200, body: sitemap_document())}

        request.url.host == "example.com" and request.url.path == "/start" ->
          {request, credential_page()}

        request.url.host == "cdn.test" and request.url.path == "/app.js" ->
          {request, script_cookie("cdn=1; Path=/")}

        request.url.host == "cdn.test" and request.url.path == "/next.js" ->
          {request, typed("text/javascript", "")}

        request.url.host == "example.com" and request.url.path == "/secure.js" ->
          {request, typed("text/javascript", "")}

        request.url.host == "www.example.com" and request.url.path == "/page" ->
          {request, typed("text/html", "www")}

        request.url.host == "example.com" and request.url.path == "/port" ->
          {request, typed("text/html", "port")}

        request.url.host == "example.com" and request.url.path == "/from-sitemap" ->
          {request, typed("text/html", "from-sitemap")}

        request.url.path == "/robots.txt" ->
          {request, Req.Response.new(status: 404, body: "")}

        true ->
          {request, typed("text/plain", "unexpected")}
      end
    end

    crawl("http://example.com/start", adapter_context(adapter),
      assets: ["js"],
      modifier: SecretModifier,
      url_filter: AllowAll
    )

    assert hop(hits, "example.com", "/start") == %{
             cookie: %{"user" => "from-user"},
             secret: "top-secret",
             authorization: "Bearer from-auth"
           }

    assert hop(hits, "example.com", "/robots.txt").secret == "top-secret"
    assert hop(hits, "example.com", "/robots.txt").authorization == "Bearer from-auth"

    for path <- ["/secure.js", "/port", "/from-sitemap"] do
      assert hop(hits, "example.com", path) == %{
               cookie: %{"user" => "from-user", "shared" => "yes"},
               secret: "top-secret",
               authorization: "Bearer from-auth"
             }
    end

    assert hop(hits, "www.example.com", "/page") == %{
             cookie: %{"shared" => "yes"},
             secret: nil,
             authorization: nil
           }

    assert hop(hits, "www.example.com", "/robots.txt") == %{
             cookie: %{"shared" => "yes"},
             secret: nil,
             authorization: nil
           }

    assert hop(hits, "cdn.test", "/robots.txt") == %{
             cookie: %{},
             secret: nil,
             authorization: nil
           }

    assert hop(hits, "cdn.test", "/app.js") == %{
             cookie: %{},
             secret: nil,
             authorization: nil
           }

    assert hop(hits, "cdn.test", "/next.js") == %{
             cookie: %{},
             secret: nil,
             authorization: nil
           }

    assert hop(hits, "files.test", "/sitemap.xml") == %{
             cookie: %{},
             secret: nil,
             authorization: nil
           }
  end

  test "a cross-site document redirect sends lax cookies but not strict cookies" do
    scope = unique_scope("samesite-redirect")

    Store.save_cookies(scope, "https://other.test/", [
      "strict=1; SameSite=Strict; Path=/",
      "lax=1; Path=/"
    ])

    hits = hits()

    adapter = fn request ->
      record(hits, request)

      cond do
        request.url.host == "example.com" and request.url.path == "/start" ->
          {request, redirect_to("https://other.test/land")}

        request.url.host == "other.test" and request.url.path == "/land" ->
          {request, typed("text/html", "land")}

        true ->
          {request, typed("text/plain", "unexpected")}
      end
    end

    crawl("https://example.com/start", adapter_context(adapter),
      scope: scope,
      respect_robots: false,
      url_filter: AllowAll
    )

    assert hop(hits, "other.test", "/land").cookie == %{"lax" => "1"}
  end

  test "a cross-site script redirect and frame do not send a lax cookie" do
    scope = unique_scope("samesite-script")
    hits = hits()

    adapter = fn request ->
      record(hits, request)

      cond do
        request.url.host == "example.com" and request.url.path == "/start" ->
          {request, typed("text/html", cross_site_document())}

        request.url.host == "cdn.test" and request.url.path == "/app.js" ->
          {request, redirect("https://cdn.test/next.js", "cdn=1; Path=/")}

        request.url.host == "cdn.test" and
            request.url.path in ["/next.js", "/frame", "/object", "/embed"] ->
          {request, typed("text/plain", "")}

        true ->
          {request, typed("text/plain", "unexpected")}
      end
    end

    crawl("https://example.com/start", adapter_context(adapter),
      assets: ["js"],
      scope: scope,
      respect_robots: false
    )

    assert Store.cookie_header(scope, "https://cdn.test/next.js") == "cdn=1"

    for path <- ["/next.js", "/frame", "/object", "/embed"] do
      assert hop(hits, "cdn.test", path).cookie == %{}
    end
  end

  test "a partitioned cookie follows the page site rather than the host that set it" do
    scope = unique_scope("partition")
    hits = hits()

    adapter = fn request ->
      record(hits, request)

      cond do
        request.url.host == "example.com" and request.url.path == "/start" ->
          {request, typed("text/html", partition_document())}

        request.url.host == "cdn.test" and request.url.path == "/app.js" ->
          {request, partition_script()}

        request.url.host == "other.test" and request.url.path == "/page" ->
          {request, typed("text/html", ~s|<script src="https://cdn.test/later.js"></script>|)}

        request.url.host == "www.example.com" and request.url.path == "/side" ->
          {request, typed("text/html", ~s|<script src="https://cdn.test/www.js"></script>|)}

        request.url.host == "example.com" and request.url.port == 8443 ->
          {request, typed("text/html", ~s|<script src="https://cdn.test/port.js"></script>|)}

        request.url.host == "cdn.test" ->
          {request, typed("text/javascript", "")}

        true ->
          {request, typed("text/plain", "unexpected")}
      end
    end

    crawl("https://example.com/start", adapter_context(adapter),
      assets: ["js"],
      scope: scope,
      respect_robots: false,
      url_filter: AllowAll
    )

    assert Store.cookie_header(scope, "https://cdn.test/next.js") == "plain=1"

    assert Store.cookie_header(scope, "https://cdn.test/next.js", nil, %{
             site: "https://example.com/start",
             navigation: false
           }) == "part=1; plain=1"

    assert hop(hits, "cdn.test", "/next.js").cookie == %{"part" => "1", "plain" => "1"}
    assert hop(hits, "cdn.test", "/later.js").cookie == %{"plain" => "1"}
    assert hop(hits, "cdn.test", "/www.js").cookie == %{"part" => "1", "plain" => "1"}
    assert hop(hits, "cdn.test", "/port.js").cookie == %{"part" => "1", "plain" => "1"}
  end

  test "a lax cookie follows the registrable domain across host, scheme, and port" do
    hits = hits()

    adapter = fn request ->
      record(hits, request)

      cond do
        request.url.host == "example.com" and request.url.path == "/start" ->
          {request, same_site_page()}

        request.url.host == "www.example.com" and request.url.path == "/page" ->
          {request, typed("text/html", "www")}

        true ->
          {request, typed("text/javascript", "")}
      end
    end

    crawl("http://example.com/start", adapter_context(adapter),
      assets: ["js"],
      respect_robots: false,
      url_filter: AllowAll
    )

    assert hop(hits, "cdn.example.com", "/app.js").cookie == %{"shared" => "1"}
    assert hop(hits, "cdn.test", "/app.js").cookie == %{}
    assert hop(hits, "example.com", "/secure.js").cookie == %{"local" => "1", "shared" => "1"}
    assert hop(hits, "example.com", "/port.js").cookie == %{"local" => "1", "shared" => "1"}
    assert hop(hits, "www.example.com", "/page").cookie == %{"shared" => "1"}
  end

  test "robots and sitemap fetches are not document navigations" do
    scope = unique_scope("cookie-fetch-kind")

    Store.save_cookies(scope, "https://cdn.test/", ["cdn=1; Path=/"])

    Store.save_cookies(scope, "https://other.test/", [
      "strict=1; SameSite=Strict; Path=/",
      "lax=1; Path=/"
    ])

    hits = hits()

    adapter = fn request ->
      record(hits, request)

      cond do
        request.url.host == "www.example.com" and request.url.path == "/robots.txt" ->
          {request,
           Req.Response.new(
             status: 200,
             body: "User-agent: *\nAllow: /\nSitemap: https://cdn.test/sitemap.xml\n"
           )}

        request.url.path == "/robots.txt" ->
          {request, Req.Response.new(status: 404, body: "")}

        request.url.host == "example.com" and request.url.path == "/start" ->
          {request, typed("text/html", fetch_kind_document())}

        request.url.host == "cdn.test" and request.url.path == "/sitemap.xml" ->
          {request, Req.Response.new(status: 200, body: "ok")}

        true ->
          {request, typed("text/html", "land")}
      end
    end

    crawl("https://example.com/start", adapter_context(adapter),
      scope: scope,
      url_filter: AllowAll
    )

    assert hop(hits, "other.test", "/robots.txt").cookie == %{}
    assert hop(hits, "other.test", "/land").cookie == %{"lax" => "1"}
    assert hop(hits, "cdn.test", "/sitemap.xml").cookie == %{}
  end

  test "a seed sitemap keeps the page as the cookie document" do
    scope = unique_scope("seed-sitemap-cookies")

    Store.save_cookies(scope, "https://cdn.test/", ["cdn=1; Path=/"])

    hits = hits()

    adapter = fn request ->
      record(hits, request)

      cond do
        request.url.host == "example.com" and request.url.path == "/robots.txt" ->
          {request,
           Req.Response.new(
             status: 200,
             body: "User-agent: *\nAllow: /\nSitemap: https://cdn.test/sitemap.xml\n"
           )}

        request.url.host == "example.com" and request.url.path == "/start" ->
          {request, typed("text/html", "start")}

        request.url.host == "cdn.test" and request.url.path == "/sitemap.xml" ->
          {request, sitemap_with_image()}

        request.url.host == "cdn.test" and request.url.path == "/pic.png" ->
          {request, typed("image/png", "img")}

        request.url.path == "/robots.txt" ->
          {request, Req.Response.new(status: 404, body: "")}

        true ->
          {request, typed("text/html", "land")}
      end
    end

    crawl("https://example.com/start", adapter_context(adapter),
      assets: ["images"],
      scope: scope
    )

    assert hop(hits, "cdn.test", "/sitemap.xml").cookie == %{}
    assert hop(hits, "cdn.test", "/pic.png").cookie == %{"part" => "1"}
    assert hop(hits, "cdn.test", "/robots.txt").cookie == %{"part" => "1"}

    assert Store.cookie_header(scope, "https://cdn.test/pic.png", nil, %{
             site: "https://example.com/start",
             navigation: false
           }) == "part=1"

    assert Store.cookie_header(scope, "https://cdn.test/pic.png", nil, %{
             site: "https://other.test/page",
             navigation: false
           }) == nil
  end

  defp cross_site_document do
    """
    <script src="https://cdn.test/app.js"></script>
    <iframe src="https://cdn.test/frame"></iframe>
    <object data="https://cdn.test/object"></object>
    <embed src="https://cdn.test/embed"></embed>
    """
  end

  defp partition_document do
    """
    <script src="https://cdn.test/app.js"></script>
    <script src="https://cdn.test/next.js"></script>
    <a href="https://other.test/page">o</a>
    <a href="https://www.example.com/side">w</a>
    <a href="https://example.com:8443/port">p</a>
    """
  end

  defp partition_script do
    Req.Response.new(
      status: 200,
      headers: [
        {"content-type", "text/javascript"},
        {"set-cookie", "part=1; Path=/; Secure; SameSite=None; Partitioned"},
        {"set-cookie", "plain=1; Path=/; Secure; SameSite=None"}
      ],
      body: ""
    )
  end

  defp same_site_page do
    Req.Response.new(
      status: 200,
      headers: [
        {"content-type", "text/html"},
        {"set-cookie", "shared=1; Domain=example.com; Path=/"},
        {"set-cookie", "local=1; Path=/"}
      ],
      body: """
      <script src="https://cdn.example.com/app.js"></script>
      <script src="https://cdn.test/app.js"></script>
      <script src="https://example.com/secure.js"></script>
      <script src="http://example.com:8443/port.js"></script>
      <a href="https://www.example.com/page">w</a>
      """
    )
  end

  defp sitemap_with_image do
    Req.Response.new(
      status: 200,
      headers: [
        {"content-type", "application/xml"},
        {"set-cookie", "part=1; Path=/; Secure; SameSite=None; Partitioned"}
      ],
      body: """
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset>
        <url>
          <loc>https://example.com/from-sitemap</loc>
          <image:image><image:loc>https://cdn.test/pic.png</image:loc></image:image>
        </url>
      </urlset>
      """
    )
  end

  defp fetch_kind_document do
    """
    <a href="https://other.test/land">o</a>
    <a href="https://www.example.com/next">w</a>
    """
  end

  defp crawl(url, context, extra \\ []) do
    scope = extra[:scope] || unique_scope("http")

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

  defp report(parent, conn) do
    send(parent, {:cookie, conn.request_path, get_req_header(conn, "cookie")})
    conn
  end

  defp received!(path) do
    assert_received {:cookie, ^path, header}
    header
  end

  defp cookie_map([]), do: %{}

  defp cookie_map([header]) do
    Map.new(String.split(header, ";"), fn piece ->
      [name, value] = piece |> String.trim() |> String.split("=", parts: 2)
      {name, value}
    end)
  end

  defp credential_page do
    Req.Response.new(
      status: 200,
      headers: [
        {"content-type", "text/html"},
        {"set-cookie", "shared=yes; Domain=example.com; Path=/"}
      ],
      body: """
      <script src="https://cdn.test/app.js"></script>
      <script src="https://cdn.test/next.js"></script>
      <script src="https://example.com/secure.js"></script>
      <a href="https://www.example.com/page">w</a>
      <a href="https://example.com:8443/port">p</a>
      """
    )
  end

  defp sitemap_document do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset>
      <url><loc>https://example.com/from-sitemap</loc></url>
    </urlset>
    """
  end

  defp script_cookie(set_cookie) do
    Req.Response.new(
      status: 200,
      headers: [
        {"content-type", "text/javascript"},
        {"set-cookie", set_cookie}
      ],
      body: ""
    )
  end

  defp cookie_page do
    Req.Response.new(
      status: 200,
      headers: [
        {"content-type", "text/html"},
        {"set-cookie", "session=#{@session}; Path=/"},
        {"set-cookie", "admin=1; Path=/admin"}
      ],
      body:
        ~s|<a href="/cookie-page">p</a><a href="/admin/home">a</a><a href="http://foreign.test/foreign">f</a>|
    )
  end

  defp typed(type, body),
    do: Req.Response.new(status: 200, headers: [{"content-type", type}], body: body)

  defp redirect(location, set_cookie) do
    Req.Response.new(
      status: 302,
      headers: [{"location", location}, {"set-cookie", set_cookie}],
      body: ""
    )
  end

  defp redirect_to(location) do
    Req.Response.new(status: 302, headers: [{"location", location}], body: "")
  end

  defp adapter_context(adapter), do: %{req_options: [adapter: adapter, retry: false]}

  defp hits do
    {:ok, hits} = Agent.start_link(fn -> [] end)
    hits
  end

  defp record(hits, request) do
    cookie = request |> Req.Request.get_header("cookie") |> List.first()
    secret = request |> Req.Request.get_header("x-secret") |> List.first()
    authorization = request |> Req.Request.get_header("authorization") |> List.first()

    Agent.update(
      hits,
      &[{request.url.host, request.url.path, cookie, secret, authorization} | &1]
    )
  end

  defp requested(hits), do: Agent.get(hits, & &1)

  defp hop(hits, host, path) do
    {_host, _path, cookie, secret, authorization} =
      Enum.find(requested(hits), fn
        {^host, ^path, _cookie, _secret, _authorization} -> true
        _other -> false
      end)

    %{
      cookie: cookie_map(List.wrap(cookie)),
      secret: secret,
      authorization: authorization
    }
  end
end
