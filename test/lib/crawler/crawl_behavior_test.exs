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
end
