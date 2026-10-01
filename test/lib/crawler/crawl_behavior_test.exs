defmodule Crawler.CrawlBehaviorTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  test "keeps pages after the crawl is idle and does not fetch them again", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    page = "#{url}/behavior/stored"

    ReqTestSite.expect_once(site, "GET", "/behavior/stored", fn conn ->
      Plug.Conn.resp(conn, 200, "<html>stored</html>")
    end)

    {:ok, opts} =
      Crawler.crawl(page,
        scope: "stored",
        workers: 1,
        timeout: 50,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)

      assert %Store.Page{url: ^page, body: "<html>stored</html>"} =
               Store.find_processed({page, "stored"})

      assert page in Store.all_urls()
    end)

    {:ok, again} =
      Crawler.crawl(page, scope: "stored", queue: opts[:queue], req_options: req_options)

    wait(fn ->
      refute Crawler.running?(again)
      assert Store.find_processed({page, "stored"})
    end)
  end

  test "a single page is not reported as running after it finishes", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    page = "#{url}/behavior/one"

    ReqTestSite.expect_once(site, "GET", "/behavior/one", fn conn ->
      Plug.Conn.resp(conn, 200, "one")
    end)

    {:ok, opts} = Crawler.crawl(page, scope: "one-page", workers: 1, req_options: req_options)

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({page, "one-page"})
    end)
  end

  test "worker limit, pause, and running? follow in-flight fetches", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()

    for path <- ["/behavior/limit/a", "/behavior/limit/b"] do
      ReqTestSite.stub(site, "GET", path, fn conn ->
        send(parent, {:started, path, self()})

        receive do
          :release -> Plug.Conn.resp(conn, 200, path)
        after
          5_000 -> Plug.Conn.resp(conn, 500, "late")
        end
      end)
    end

    {:ok, opts} =
      Crawler.crawl("#{url}/behavior/limit/a",
        scope: "limit",
        workers: 1,
        interval: 0,
        req_options: req_options
      )

    assert_receive {:started, "/behavior/limit/a", first}, 1_000
    assert Crawler.running?(opts)

    {:ok, _second} =
      Crawler.crawl("#{url}/behavior/limit/b",
        scope: "limit",
        queue: opts[:queue],
        workers: 1,
        req_options: req_options
      )

    refute_receive {:started, "/behavior/limit/b", _pid}, 200

    Crawler.pause(opts)
    assert Process.alive?(first)
    refute Crawler.running?(opts)

    Crawler.resume(opts)
    send(first, :release)

    assert_receive {:started, "/behavior/limit/b", second}, 1_000
    assert Crawler.running?(opts)
    send(second, :release)

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.ops_count("limit") == 2
    end)
  end

  test "timeout infinity still crawls", %{site: site, url: url, req_options: req_options} do
    page = "#{url}/behavior/forever"

    ReqTestSite.expect_once(site, "GET", "/behavior/forever", fn conn ->
      Plug.Conn.resp(conn, 200, "ok")
    end)

    {:ok, opts} =
      Crawler.crawl(page,
        scope: "forever",
        timeout: :infinity,
        workers: 1,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({page, "forever"})
    end)
  end

  test "retries retryable responses and leaves a slow attempt able to retry", %{url: url} do
    {:ok, attempts} = Agent.start_link(fn -> %{} end)

    adapter = fn request ->
      path = request.url.path

      count =
        Agent.get_and_update(attempts, fn state ->
          count = Map.get(state, path, 0) + 1
          {count, Map.put(state, path, count)}
        end)

      response =
        cond do
          path == "/retry/status" and count < 3 ->
            Req.Response.new(status: 500, body: "nope")

          path == "/retry/missing" ->
            Req.Response.new(status: 404, body: "missing")

          path == "/retry/slow" and count == 1 ->
            Process.sleep(40)
            {request, %Req.TransportError{reason: :timeout}}

          true ->
            Req.Response.new(status: 200, body: "ok")
        end

      case response do
        {%Req.Request{}, _exception} = result -> result
        response -> {request, response}
      end
    end

    req_options = [adapter: adapter, retry: false]
    scope = "retries"

    {:ok, status_opts} =
      Crawler.crawl("#{url}/retry/status",
        scope: scope,
        retries: 2,
        timeout: 1_000,
        workers: 1,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(status_opts)
      assert Store.find_processed({"#{url}/retry/status", scope})
      assert Agent.get(attempts, & &1["/retry/status"]) == 3
    end)

    {:ok, missing_opts} =
      Crawler.crawl("#{url}/retry/missing",
        scope: scope,
        retries: 2,
        workers: 1,
        queue: status_opts[:queue],
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(missing_opts)
      assert Agent.get(attempts, & &1["/retry/missing"]) == 1
      refute Store.find_processed({"#{url}/retry/missing", scope})
    end)

    {:ok, slow_opts} =
      Crawler.crawl("#{url}/retry/slow",
        scope: scope,
        retries: 1,
        timeout: 30,
        workers: 1,
        queue: status_opts[:queue],
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(slow_opts)
      assert Agent.get(attempts, & &1["/retry/slow"]) == 2
      assert Store.find_processed({"#{url}/retry/slow", scope})
    end)
  end

  test "overlapping crawls keep separate queues, budgets, and urls", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()

    ReqTestSite.stub(site, "GET", "/behavior/iso/a", fn conn ->
      send(parent, {:started, :a, self()})

      receive do
        :release ->
          Plug.Conn.resp(conn, 200, ~s(<a href="#{url}/behavior/iso/a1">1</a>))
      after
        5_000 -> Plug.Conn.resp(conn, 500, "late")
      end
    end)

    ReqTestSite.expect_once(site, "GET", "/behavior/iso/a1", fn conn ->
      Plug.Conn.resp(conn, 200, ~s(<a href="#{url}/behavior/iso/a2">2</a>))
    end)

    ReqTestSite.stub(site, "GET", "/behavior/iso/b", fn conn ->
      send(parent, {:started, :b, self()})

      receive do
        :release -> Plug.Conn.resp(conn, 200, "b")
      after
        5_000 -> Plug.Conn.resp(conn, 500, "late")
      end
    end)

    {:ok, held} =
      Crawler.crawl("#{url}/behavior/iso/b",
        max_pages: 2,
        workers: 1,
        store: Store,
        req_options: req_options
      )

    assert_receive {:started, :b, held_pid}, 1_000

    {:ok, other} =
      Crawler.crawl("#{url}/behavior/iso/a",
        max_pages: 2,
        workers: 1,
        store: Store,
        req_options: req_options
      )

    assert_receive {:started, :a, other_pid}, 1_000
    assert other[:queue] != held[:queue]

    Crawler.pause(held)
    assert Process.alive?(held_pid)
    assert Process.alive?(other_pid)
    assert Crawler.running?(other)
    assert OPQ.info(held[:queue]) |> elem(0) == :paused
    assert OPQ.info(other[:queue]) |> elem(0) == :normal

    send(other_pid, :release)

    wait(fn ->
      assert Store.ops_count(other[:scope]) == 2
      assert Store.find_processed({"#{url}/behavior/iso/a", other[:scope]})
      assert Store.find_processed({"#{url}/behavior/iso/a1", other[:scope]})
      refute Store.find({"#{url}/behavior/iso/a2", other[:scope]})
      refute Store.find({"#{url}/behavior/iso/a", held[:scope]})
    end)

    send(held_pid, :release)
    Crawler.resume(held)

    wait(fn ->
      refute Crawler.running?(held)
      assert Store.ops_count(held[:scope]) == 1
    end)

    {:ok, capped} =
      Crawler.crawl("#{url}/behavior/iso/a2",
        scope: other[:scope],
        queue: other[:queue],
        max_pages: 2,
        req_options: req_options
      )

    assert capped[:queue] == other[:queue]

    wait(fn ->
      refute Crawler.running?(capped)
      refute Store.find({"#{url}/behavior/iso/a2", other[:scope]})
    end)
  end

  test "the same url can be fetched by two crawls", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    {:ok, hits} = Agent.start_link(fn -> 0 end)
    page = "#{url}/behavior/shared-url"

    ReqTestSite.stub(site, "GET", "/behavior/shared-url", fn conn ->
      Agent.update(hits, &(&1 + 1))
      Plug.Conn.resp(conn, 200, "shared")
    end)

    {:ok, first} = Crawler.crawl(page, scope: "crawl-a", workers: 1, req_options: req_options)
    {:ok, second} = Crawler.crawl(page, scope: "crawl-b", workers: 1, req_options: req_options)

    wait(fn ->
      refute Crawler.running?(first)
      refute Crawler.running?(second)
      assert Agent.get(hits, & &1) == 2
      assert Store.find_processed({page, "crawl-a"})
      assert Store.find_processed({page, "crawl-b"})
    end)
  end

  test "discovers ordinary links and assets once", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    host = "#{site.host}:#{site.port}"

    ReqTestSite.expect_once(site, "GET", "/behavior/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "#{url}/behavior/dir/page")
      |> Plug.Conn.resp(302, "")
    end)

    body = """
    <html>
      <head>
        <base href="#{url}/behavior/other/">
        <script src="/behavior/app.js"></script>
        <script type="module" src="/behavior/mod.js"></script>
        <script src="//#{host}/behavior/lib.js"></script>
      </head>
      <a href="next">next</a>
      <a href="#{url}/behavior/dir/page#a">a</a>
      <a href="#{url}/behavior/dir/page#b">b</a>
      <a href="mailto:a@b.c">mail</a>
      <a href="javascript:void(0)">js</a>
      <a href="/behavior/search?q=1">search</a>
    </html>
    """

    ReqTestSite.expect_once(site, "GET", "/behavior/dir/page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, body)
    end)

    for path <- [
          "/behavior/other/next",
          "/behavior/app.js",
          "/behavior/mod.js",
          "/behavior/lib.js",
          "/behavior/search"
        ] do
      ReqTestSite.expect_once(site, "GET", path, fn conn ->
        Plug.Conn.resp(conn, 200, path)
      end)
    end

    {:ok, opts} =
      Crawler.crawl("#{url}/behavior/old",
        scope: "links",
        assets: ["js"],
        max_depths: 2,
        workers: 2,
        save_to: tmp("behavior-links"),
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.ops_count("links") == 6
      assert File.read!(tmp("behavior-links/#{site.path}/behavior/old", "__index.html")) =~ "q=1"
    end)
  end

  test "a redirect fragment does not fetch the landing page again", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    page = "#{url}/behavior/frag/page"

    ReqTestSite.expect_once(site, "GET", "/behavior/frag/from", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "#{page}#a")
      |> Plug.Conn.resp(302, "")
    end)

    ReqTestSite.expect_once(site, "GET", "/behavior/frag/page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, ~s(<a href="#{page}#b">b</a>))
    end)

    {:ok, opts} =
      Crawler.crawl("#{url}/behavior/frag/from",
        scope: "frag",
        workers: 2,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)

      assert %Store.Page{body: body} = Store.find_processed({page, "frag"})
      assert body =~ "#{page}#b"
      assert Store.ops_count("frag") == 1
      refute Store.find({"#{page}#a", "frag"})
      refute Store.find({"#{page}#b", "frag"})
    end)
  end

  test "fetches media and style links and stores distinct offline files", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    sheet = """
    @import "other.css";
    @import url("nested.css");
    body { background: url( "spaced.png" ); }
    @font-face { src: url( 'font.woff2' ); }
    """

    entry = """
    <html>
      <img src="a.jpg" srcset="a.jpg 1x, b.jpg 2x">
      <picture><source srcset="c.webp" type="image/webp"><img src="c.jpg"></picture>
      <video src="d.mp4" poster="d.jpg"></video>
      <audio src="e.mp3"></audio>
      <link rel="preload" as="style" href="pre.css">
      <link rel="stylesheet alternate" href="alt.css">
      <link rel="stylesheet" href="sheet.css">
      <style>body { background: url(bg.png); }</style>
      <div style="background: url('bg2.png')"></div>
      <a href="/archive/search?q=1&amp;x=2">one</a>
      <a href="/archive/search?q=2">two</a>
      <a href="/archive/bare">bare</a>
      <a href="/archive/bare/index.html">index</a>
    </html>
    """

    ReqTestSite.expect_once(site, "GET", "/archive/entry", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, entry)
    end)

    ReqTestSite.expect_once(site, "GET", "/archive/sheet.css", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/css")
      |> Plug.Conn.resp(200, sheet)
    end)

    for {path, type, body} <- [
          {"/archive/a.jpg", "image/jpeg", "a"},
          {"/archive/b.jpg", "image/jpeg", "b"},
          {"/archive/c.webp", "image/webp", "c"},
          {"/archive/c.jpg", "image/jpeg", "c-jpg"},
          {"/archive/d.mp4", "video/mp4", "d"},
          {"/archive/d.jpg", "image/jpeg", "poster"},
          {"/archive/e.mp3", "audio/mpeg", "e"},
          {"/archive/pre.css", "text/css", "/* pre */"},
          {"/archive/alt.css", "text/css", "/* alt */"},
          {"/archive/bg.png", "image/png", "bg"},
          {"/archive/bg2.png", "image/png", "bg2"},
          {"/archive/other.css", "text/css", "/* other */"},
          {"/archive/nested.css", "text/css", "/* nested */"},
          {"/archive/spaced.png", "image/png", "spaced"},
          {"/archive/font.woff2", "font/woff2", "font"},
          {"/archive/bare", "text/html", "PAGE"},
          {"/archive/bare/index.html", "text/html", "INDEX"}
        ] do
      ReqTestSite.expect_once(site, "GET", path, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", type)
        |> Plug.Conn.resp(200, body)
      end)
    end

    ReqTestSite.stub(site, "GET", "/archive/search", fn conn ->
      label = if conn.query_string == "q=1&x=2", do: "1", else: "2"

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "results for " <> label)
    end)

    {:ok, opts} =
      Crawler.crawl("#{url}/archive/entry",
        scope: "archive",
        assets: ["images", "css"],
        max_depths: 3,
        workers: 4,
        save_to: tmp("behavior-archive"),
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)

      root = tmp("behavior-archive/#{site.path}/archive")
      page = File.read!(Path.join(root, "entry/__index.html"))
      css = File.read!(Path.join(root, "sheet.css"))
      paths = Path.wildcard(Path.join(tmp("behavior-archive"), "**/*"))

      assert "PAGE" == File.read!(Path.join(root, "bare/__index.html"))
      assert "INDEX" == File.read!(Path.join(root, "bare/index.html"))

      assert Enum.any?(paths, &(File.regular?(&1) and File.read!(&1) == "results for 1"))
      assert Enum.any?(paths, &(File.regular?(&1) and File.read!(&1) == "results for 2"))

      Enum.each(paths, fn path ->
        refute path =~ "?"
        refute path =~ "&"
      end)

      refute page =~ ~s|srcset="a.jpg 1x, b.jpg 2x"|
      refute page =~ ~s|src="d.mp4"|
      refute page =~ ~s|href="pre.css"|
      refute page =~ "url('bg2.png')"
      refute page =~ ~s|href="/archive/search?q=1&amp;x=2"|
      assert page =~ "b.jpg"
      assert page =~ "c.webp"
      assert page =~ "e.mp3"
      assert page =~ "q=1"
      assert page =~ "x=2"

      refute css =~ ~s|@import "other.css"|
      refute css =~ ~s|url( "spaced.png" )|
      refute css =~ "url( 'font.woff2' )"
      assert css =~ "other.css"
      assert css =~ "nested.css"
      assert css =~ "spaced.png"
      assert css =~ "font.woff2"
    end)
  end

  test "force refreshes a scope", %{site: site, url: url, req_options: req_options} do
    {:ok, hits} = Agent.start_link(fn -> 0 end)
    page = "#{url}/behavior/refresh"

    ReqTestSite.stub(site, "GET", "/behavior/refresh", fn conn ->
      Agent.update(hits, &(&1 + 1))
      Plug.Conn.resp(conn, 200, "fresh")
    end)

    {:ok, first} =
      Crawler.crawl(page, scope: "refresh", workers: 1, store: Store, req_options: req_options)

    wait(fn ->
      refute Crawler.running?(first)
      assert Agent.get(hits, & &1) == 1
    end)

    {:ok, second} =
      Crawler.crawl(page,
        scope: "refresh",
        force: true,
        workers: 1,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(second)
      assert Agent.get(hits, & &1) == 2
      assert %Store.Page{body: "fresh"} = Store.find_processed({page, "refresh"})
    end)
  end

  defp released_body(gate, pid) do
    deadline = System.monotonic_time(:millisecond) + 5_000

    Stream.repeatedly(fn ->
      Process.sleep(10)
      Agent.get(gate, &Map.get(&1, pid))
    end)
    |> Enum.find(fn
      body when is_binary(body) -> true
      _ -> System.monotonic_time(:millisecond) > deadline
    end)
    |> case do
      body when is_binary(body) -> body
      _ -> "late"
    end
  end

  test "a forced recrawl keeps the new page when the old fetch finishes later", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    page = "#{url}/behavior/refresh-race"
    {:ok, gate} = Agent.start_link(fn -> %{} end)

    ReqTestSite.stub(site, "GET", "/behavior/refresh-race", fn conn ->
      pid = self()
      send(parent, {:started, pid})
      body = released_body(gate, pid)
      send(parent, {:finished, body})
      Plug.Conn.resp(conn, 200, body)
    end)

    {:ok, first} =
      Crawler.crawl(page,
        scope: "refresh-race",
        workers: 1,
        store: Store,
        save_to: tmp("behavior-refresh-race"),
        retries: 1,
        req_options: req_options
      )

    assert_receive {:started, old}, 1_000

    {:ok, second} =
      Crawler.crawl(page,
        scope: "refresh-race",
        force: true,
        workers: 1,
        store: Store,
        save_to: tmp("behavior-refresh-race"),
        retries: 1,
        req_options: req_options
      )

    assert_receive {:started, new}, 1_000
    Agent.update(gate, &Map.put(&1, new, "NEW"))

    wait(fn ->
      refute Crawler.running?(second)
      assert %Store.Page{body: "NEW"} = Store.find_processed({page, "refresh-race"})
    end)

    Agent.update(gate, &Map.put(&1, old, "OLD"))
    assert_receive {:finished, "OLD"}, 1_000

    wait(fn ->
      assert {:normal, %{data: {[], []}}, 1} = OPQ.info(first[:queue])
      assert %Store.Page{body: "NEW"} = Store.find_processed({page, "refresh-race"})

      assert File.read!(
               tmp("behavior-refresh-race/#{site.path}/behavior/refresh-race", "__index.html")
             ) == "NEW"
    end)
  end

  test "a trailing slash is the same url and offline file", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    ReqTestSite.expect_once(site, "GET", "/slash/entry", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, """
      <html>
        <a href="#{url}/slash/foo">a</a>
        <a href="#{url}/slash/foo/">b</a>
      </html>
      """)
    end)

    hits = :counters.new(1, [:atomics])

    for path <- ["/slash/foo", "/slash/foo/"] do
      ReqTestSite.stub(site, "GET", path, fn conn ->
        :counters.add(hits, 1, 1)

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.resp(200, "FOO")
      end)
    end

    {:ok, opts} =
      Crawler.crawl("#{url}/slash/entry",
        scope: "slash",
        workers: 2,
        save_to: tmp("behavior-slash"),
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)
      assert :counters.get(hits, 1) == 1
      assert File.read!(tmp("behavior-slash/#{site.path}/slash/foo", "__index.html")) == "FOO"
      assert Store.find_processed({"#{url}/slash/foo", "slash"})
      assert Store.find_processed({"#{url}/slash/foo/", "slash"})
    end)
  end

  test "a directory url keeps relative links inside that directory", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    ReqTestSite.expect_once(site, "GET", "/dir/docs/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, ~s(<a href="intro">intro</a>))
    end)

    ReqTestSite.expect_once(site, "GET", "/dir/docs/intro", fn conn ->
      Plug.Conn.resp(conn, 200, "INTRO")
    end)

    {:ok, opts} =
      Crawler.crawl("#{url}/dir/docs/",
        scope: "directory",
        workers: 2,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({"#{url}/dir/docs/intro", "directory"})
      refute Store.find({"#{url}/intro", "directory"})
      refute Store.find({"#{url}/dir/intro", "directory"})
    end)
  end

  test "a failed redirect does not leave the target url blocked", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    landing = "#{url}/alias/landing/"
    blocked = tmp("behavior-alias-block", "not-a-directory")
    File.write!(blocked, "not-a-directory")

    ReqTestSite.expect(site, "GET", "/alias/from", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", landing)
      |> Plug.Conn.resp(302, "")
    end)

    ReqTestSite.expect(site, "GET", "/alias/landing/", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "LANDED")
    end)

    {:ok, failed} =
      Crawler.crawl("#{url}/alias/from",
        scope: "alias-fail",
        workers: 1,
        save_to: blocked,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(failed)
      refute Store.find({"#{url}/alias/from", "alias-fail"})
      refute Store.find({landing, "alias-fail"})
    end)

    {:ok, again} =
      Crawler.crawl(landing,
        scope: "alias-fail",
        workers: 1,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(again)
      assert %Store.Page{body: "LANDED"} = Store.find_processed({landing, "alias-fail"})
    end)
  end

  test "a dotted directory does not block a child path", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    ReqTestSite.expect_once(site, "GET", "/dot/about.me", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "PARENT")
    end)

    ReqTestSite.expect_once(site, "GET", "/dot/about.me/team", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "CHILD")
    end)

    {:ok, parent} =
      Crawler.crawl("#{url}/dot/about.me",
        scope: "dotted",
        workers: 1,
        save_to: tmp("behavior-dotted"),
        req_options: req_options
      )

    {:ok, child} =
      Crawler.crawl("#{url}/dot/about.me/team",
        scope: "dotted",
        queue: parent[:queue],
        save_to: tmp("behavior-dotted"),
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(child)

      root = tmp("behavior-dotted/#{site.path}/dot")
      assert File.read!(Path.join(root, "about.me/__index.html")) == "PARENT"
      assert File.read!(Path.join(root, "about.me/team/__index.html")) == "CHILD"
    end)
  end

  test "saved xhtml resolves a directory base and drops the live tag", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    page = "#{url}/xhtml/page"

    ReqTestSite.expect_once(site, "GET", "/xhtml/page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/xhtml+xml")
      |> Plug.Conn.resp(200, """
      <html><head><base href="#{url}/xhtml/dir/" /></head>
      <a href="intro">intro</a></html>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/xhtml/dir/intro", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/xhtml+xml")
      |> Plug.Conn.resp(200, "INTRO")
    end)

    {:ok, opts} =
      Crawler.crawl(page,
        scope: "xhtml",
        workers: 2,
        save_to: tmp("behavior-xhtml"),
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({"#{url}/xhtml/dir/intro", "xhtml"})

      html = File.read!(tmp("behavior-xhtml/#{site.path}/xhtml/page", "__index.html"))
      refute html =~ ~r/<base[^>]+href=['"]https?:\/\//i
      assert html =~ "intro"
      refute html =~ ~s|href="intro"|
    end)
  end

  test "saved html drops a live base href", %{site: site, url: url, req_options: req_options} do
    page = "#{url}/base/page"

    ReqTestSite.expect_once(site, "GET", "/base/page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, """
      <html><head><base href="#{url}/base/dir/"></head>
      <a href="next">next</a></html>
      """)
    end)

    ReqTestSite.expect_once(site, "GET", "/base/dir/next", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "NEXT")
    end)

    {:ok, opts} =
      Crawler.crawl(page,
        scope: "base",
        workers: 2,
        save_to: tmp("behavior-base"),
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)
      assert Store.find_processed({"#{url}/base/dir/next", "base"})

      html = File.read!(tmp("behavior-base/#{site.path}/base/page", "__index.html"))
      refute html =~ ~r/<base[^>]+href=['"]https?:\/\//i
      refute html =~ ~s|href="next"|
      refute html =~ "#{url}/base/dir/next"
      assert html =~ "next/__index.html"
    end)
  end

  test "crawls embedded resources and skips them when assets are empty", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    page = "#{url}/embed/page"

    html = """
    <html>
      <area href="area.html">
      <iframe src="frame.html"></iframe>
      <link rel="icon" href="icon.png">
      <link rel="shortcut icon" href="shortcut.png">
      <link rel="preload" as="image" href="pre.png">
      <link rel="preload" as="script" href="pre.js">
      <link rel="preload" as="font" href="pre.woff2">
      <track src="cap.vtt">
      <svg><image href="svg.png"></image><use href="icons.svg#a"></use></svg>
    </html>
    """

    ReqTestSite.expect_once(site, "GET", "/embed/page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, html)
    end)

    for path <- ~w(
      /embed/area.html
      /embed/frame.html
      /embed/icon.png
      /embed/shortcut.png
      /embed/pre.png
      /embed/pre.js
      /embed/pre.woff2
      /embed/cap.vtt
      /embed/svg.png
      /embed/icons.svg
    ) do
      ReqTestSite.expect_once(site, "GET", path, fn conn ->
        type =
          if String.ends_with?(path, ".html"), do: "text/html", else: "application/octet-stream"

        conn
        |> Plug.Conn.put_resp_header("content-type", type)
        |> Plug.Conn.resp(200, path)
      end)
    end

    {:ok, opts} =
      Crawler.crawl(page,
        scope: "embed",
        assets: ["images", "css", "js"],
        max_depths: 2,
        workers: 4,
        save_to: tmp("behavior-embed"),
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)

      for path <- ~w(
        /embed/area.html
        /embed/frame.html
        /embed/icon.png
        /embed/shortcut.png
        /embed/pre.png
        /embed/pre.js
        /embed/pre.woff2
        /embed/cap.vtt
        /embed/svg.png
        /embed/icons.svg
      ) do
        assert Store.find_processed({"#{url}#{path}", "embed"})
      end

      saved = File.read!(tmp("behavior-embed/#{site.path}/embed/page", "__index.html"))

      for raw <- ~w(
        area.html
        frame.html
        icon.png
        shortcut.png
        pre.png
        pre.js
        pre.woff2
        cap.vtt
        svg.png
      ) do
        refute saved =~ ~s|="#{raw}"|
      end

      refute saved =~ ~s|href="icons.svg#a"|
      assert saved =~ "icons.svg#a"
    end)

    bare = "#{url}/embed/bare"

    ReqTestSite.expect_once(site, "GET", "/embed/bare", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, """
      <link rel="icon" href="icon.png"><link rel="preload" as="script" href="pre.js">
      """)
    end)

    {:ok, skipped} =
      Crawler.crawl(bare,
        scope: "embed-empty",
        assets: [],
        workers: 1,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(skipped)
      assert Store.find_processed({bare, "embed-empty"})
      refute Store.find({"#{url}/embed/icon.png", "embed-empty"})
      refute Store.find({"#{url}/embed/pre.js", "embed-empty"})
    end)
  end

  test "a failed fetch can succeed on a later crawl", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    {:ok, hits} = Agent.start_link(fn -> 0 end)
    page = "#{url}/behavior/retry-later"

    ReqTestSite.stub(site, "GET", "/behavior/retry-later", fn conn ->
      count = Agent.get_and_update(hits, fn count -> {count, count + 1} end)

      if count == 0 do
        Plug.Conn.resp(conn, 404, "missing")
      else
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.resp(200, "found")
      end
    end)

    {:ok, first} =
      Crawler.crawl(page,
        scope: "retry-later",
        workers: 1,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(first)
      refute Store.find_processed({page, "retry-later"})
      refute Store.find({page, "retry-later"})
    end)

    {:ok, second} =
      Crawler.crawl(page,
        scope: "retry-later",
        force: true,
        workers: 1,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(second)
      assert %Store.Page{body: "found"} = Store.find_processed({page, "retry-later"})
    end)
  end
end
