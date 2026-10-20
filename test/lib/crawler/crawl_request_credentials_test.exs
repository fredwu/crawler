defmodule Crawler.CrawlRequestCredentialsTest do
  use Crawler.TestCase, async: false

  alias Crawler.Parser.CssParser
  alias Crawler.Store

  defmodule AllowAll do
    @behaviour Crawler.Fetcher.UrlFilter.Spec

    def filter(_url, _opts), do: {:ok, true}
  end

  defmodule CallerModifier do
    @behaviour Crawler.Fetcher.Modifier.Spec

    def headers(_opts), do: [{"cookie", "extra=1"}]
    def opts(_opts), do: [auth: {:bearer, "secret"}]
  end

  @both %{"session" => "1", "open" => "1"}
  @open %{"open" => "1"}
  @none %{}

  test "stylesheet urls keep font, import, and image kinds" do
    source = """
    @import "extra.css";
    @font-face { src: url("font.woff2"), url(font2.woff2); }
    body { background: url("bg.png"); }
    div { background-image: image-set("set.png" 1x); }
    div { background-image: image("pic.png"); }
    @font-face; body { background: url("after.png"); }
    """

    kinds = source |> CssParser.spans() |> Map.new(&{&1.value, &1.kind})

    assert kinds["extra.css"] == :import
    assert kinds["font.woff2"] == :font
    assert kinds["font2.woff2"] == :font
    assert kinds["bg.png"] == :url
    assert kinds["set.png"] == :url
    assert kinds["pic.png"] == :url
    assert kinds["after.png"] == :url
  end

  test "modules, workers, and their imports follow crossorigin" do
    hits =
      crawl_routes("https://www.example.com/start", [
        {%{host: "www.example.com", path: "/start"}, page(module_page())},
        {%{host: "www.example.com", path: "/app.js"},
         asset(
           "text/javascript",
           ~s|import "/static.js"; import "https://cdn.example.com/static.js"; import("/dynamic.js");|
         )},
        {%{host: "www.example.com", path: "/worker.js"},
         asset(
           "text/javascript",
           ~s|importScripts("/imported.js"); importScripts("https://cdn.example.com/imported.js");|
         )},
        {%{host: "other.test", path: "/app.js"},
         asset(
           "text/javascript",
           ~s|import "https://cdn.example.com/foreign-lib.js"; new Worker("https://cdn.example.com/mod-worker.js");|
         )}
      ])

    assert length(requests(hits, "https://www.example.com/app.js")) == 1
    assert_cookie(hits, "https://www.example.com/app.js", @both)
    assert_cookie(hits, "https://www.example.com/static.js", @both)
    assert_cookie(hits, "https://www.example.com/dynamic.js", @both)
    assert_cookie(hits, "https://www.example.com/lib.js", @both)
    assert_cookie(hits, "https://www.example.com/worker.js", @both)
    assert_cookie(hits, "https://www.example.com/imported.js", @both)
    assert_cookie(hits, "https://www.example.com/preload-worker.js", @both)

    for url <- [
          "https://cdn.example.com/app.js",
          "https://www.example.com:8443/app.js",
          "https://other.test/anon.js",
          "https://cdn.example.com/preload.js",
          "https://cdn.example.com/lib.js",
          "https://cdn.example.com/static.js",
          "https://cdn.example.com/worker.js",
          "https://cdn.example.com/imported.js",
          "https://cdn.example.com/paint.js",
          "https://cdn.example.com/mod-worker.js"
        ] do
      assert_cookie(hits, url, @none)
    end

    assert_cookie(hits, "https://other.test/app.js", @open)
    assert_cookie(hits, "https://other.test/lib.js", @open)
    assert_cookie(hits, "https://cdn.example.com/foreign-lib.js", @both)
    assert_cookie(hits, "https://cdn.example.com/cred-lib.js", @both)
    assert_cookie(hits, "https://cdn.example.com/classic.js", @both)
    assert_cookie(hits, "https://cdn.example.com/preload-classic.js", @both)
    assert_cookie(hits, "https://cdn.example.com/cred-worker.js", @both)
  end

  test "fonts stay same-origin and imports keep the stylesheet mode" do
    hits =
      crawl_routes("https://www.example.com/start", [
        {%{host: "www.example.com", path: "/start"}, page(font_page())},
        {%{host: "www.example.com", path: "/app.css"}, asset("text/css", app_css())},
        {%{host: "www.example.com", path: "/anon.css"}, asset("text/css", anon_css())},
        {%{host: "www.example.com", path: "/cred.css"}, asset("text/css", cred_css())}
      ])

    assert_cookie(hits, "https://www.example.com/app.css", @both)
    assert_cookie(hits, "https://www.example.com/anon.css", @both)
    assert_cookie(hits, "https://www.example.com/font.woff2", @both)
    assert_cookie(hits, "https://cdn.example.com/font.woff2", @none)
    assert_cookie(hits, "https://cdn.example.com/preload.woff2", @none)
    assert_cookie(hits, "https://cdn.example.com/anon-font.woff2", @none)
    assert_cookie(hits, "https://cdn.example.com/cred-font.woff2", @none)
    assert_cookie(hits, "https://cdn.example.com/inline-font.woff2", @none)
    assert_cookie(hits, "https://other.test/bg.png", @open)
    assert_cookie(hits, "https://other.test/inline-bg.png", @open)
    assert_cookie(hits, "https://other.test/picture.png", @open)
    assert_cookie(hits, "https://cdn.example.com/extra.css", @both)
    assert_cookie(hits, "https://cdn.example.com/inline.css", @both)
    assert_cookie(hits, "https://cdn.example.com/cred-extra.css", @both)
    assert_cookie(hits, "https://cdn.example.com/anon-extra.css", @none)
    assert_cookie(hits, "https://cdn.example.com/anon-bg.png", @both)
    assert_cookie(hits, "https://cdn.example.com/set.png", @both)
  end

  test "ordinary crossorigin keywords choose include or same-origin" do
    hits =
      crawl_routes("https://www.example.com/start", [
        {%{host: "www.example.com", path: "/start"}, page(crossorigin_page())}
      ])

    assert_cookie(hits, "https://www.example.com/anon.png", @both)
    assert_cookie(hits, "https://other.test/plain.png", @open)
    assert_cookie(hits, "https://other.test/cred.png", @open)
    assert_cookie(hits, "https://other.test/anon.png", @none)
    assert_cookie(hits, "https://other.test/empty.png", @none)
    assert_cookie(hits, "https://other.test/bogus.png", @none)
    assert_cookie(hits, "https://cdn.example.com/site.png", @both)
    assert_cookie(hits, "https://cdn.example.com/site.js", @both)
    assert_cookie(hits, "https://cdn.example.com/site.css", @both)
    assert_cookie(hits, "https://cdn.example.com/anon-site.png", @none)
    assert_cookie(hits, "https://cdn.example.com/hero.png", @none)
    assert_cookie(hits, "https://cdn.example.com/hero-2x.png", @none)
    assert_cookie(hits, "https://cdn.example.com/plain-hero.png", @both)
    assert_cookie(hits, "https://cdn.example.com/plain-hero-2x.png", @both)
    assert_cookie(hits, "https://cdn.example.com/icon.png", @none)
    assert_cookie(hits, "https://cdn.example.com/plain-icon.png", @both)
    assert_cookie(hits, "https://cdn.example.com/xlink-icon.png", @none)
    assert_cookie(hits, "https://other.test/anon-frame", @open)
    assert_cookie(hits, "https://other.test/anon-object", @open)
    assert_cookie(hits, "https://other.test/anon-embed", @open)
  end

  test "prefetch is not a page open and speculation rules keep their action" do
    hits =
      crawl_routes("https://www.example.com/start", [
        {%{host: "www.example.com", path: "/start"}, page(prefetch_page())}
      ])

    assert_cookie(hits, "https://www.example.com/soon", @both)
    assert_cookie(hits, "https://cdn.example.com/soon", @both)
    assert_cookie(hits, "https://cdn.example.com/spec-soon", @both)
    assert_cookie(hits, "https://other.test/next", @open)
    assert_cookie(hits, "https://other.test/anon-next", @none)
    assert_cookie(hits, "https://other.test/cred-next", @open)
    assert_cookie(hits, "https://other.test/link", @both)
    assert_cookie(hits, "https://other.test/area", @both)
    assert_cookie(hits, "https://other.test/refresh", @both)
    assert_cookie(hits, "https://other.test/prerender", @both)
    assert_cookie(hits, "https://other.test/spec-render", @both)
    assert_cookie(hits, "https://other.test/frame", @open)
    assert_cookie(hits, "https://other.test/object", @open)
    assert_cookie(hits, "https://other.test/embed", @open)
    assert_cookie(hits, "https://other.test/spec-next", @none)
    refute requested?(hits, "https://other.test/ignored-doc")
    refute requested?(hits, "https://www.example.com/where-hidden")
  end

  test "redirect hops rebuild cookies for the credential mode and the landed page" do
    hits =
      crawl_routes("https://www.example.com/start", [
        {%{host: "www.example.com", path: "/start"}, page(redirect_page())},
        {%{host: "www.example.com", path: "/app.js"}, redirect("https://cdn.example.com/app.js")},
        {%{host: "www.example.com", path: "/pic.png"}, redirect("https://other.test/pic.png")},
        {%{host: "www.example.com", path: "/go"}, redirect("https://other.test/land")}
      ])

    assert_cookie(hits, "https://www.example.com/app.js", @both)
    assert_cookie(hits, "https://cdn.example.com/app.js", @none)
    assert_cookie(hits, "https://www.example.com/pic.png", @both)
    assert_cookie(hits, "https://other.test/pic.png", @open)
    assert_cookie(hits, "https://www.example.com/go", @both)
    assert_cookie(hits, "https://other.test/land", @both)

    home =
      crawl_routes("https://shop.example.com/start", [
        {%{host: "shop.example.com", path: "/start"},
         redirect("https://www.example.com/home", session_cookies())},
        {%{host: "www.example.com", path: "/home"}, page(home_page())}
      ])

    assert_cookie(home, "https://www.example.com/app.js", @both)
    assert_cookie(home, "https://shop.example.com/back.js", @none)
  end

  test "caller cookies follow the credential mode and authorization follows the host" do
    hits =
      crawl_routes(
        "https://www.example.com/start",
        [
          {%{host: "www.example.com", path: "/start"}, page(caller_page())},
          {%{host: "www.example.com", path: "/mod.js"},
           redirect("http://www.example.com/mod.js")},
          {%{host: "www.example.com", path: "/jump"},
           redirect("https://www.example.com:8443/landed")}
        ],
        modifier: CallerModifier
      )

    assert_caller(hits, "https://www.example.com/app.js", @both, "extra", "Bearer secret")
    assert_caller(hits, "https://www.example.com/soon", @both, "extra", "Bearer secret")
    assert_cookie(hits, "https://cdn.example.com/app.js", @none)
    assert_blank(hits, "https://cdn.example.com/app.js")
    assert_cookie(hits, "https://other.test/anon.png", @none)
    assert_blank(hits, "https://other.test/anon.png")
    assert_cookie(hits, "https://other.test/next", @open)
    assert_blank(hits, "https://other.test/next")
    assert_caller(hits, "https://www.example.com:8443/next", @both, "extra", "Bearer secret")
    assert_cookie(hits, "https://www.example.com:8443/app.js", @none)
    assert hop(hits, "https://www.example.com:8443/app.js").authorization == "Bearer secret"
    refute hop(hits, "https://www.example.com:8443/app.js").cookie["extra"]
    assert_blank(hits, "https://other.test/land")
    assert_cookie(hits, "https://other.test/land", @both)

    assert_caller(hits, "https://www.example.com/mod.js", @both, "extra", "Bearer secret")
    assert_cookie(hits, "http://www.example.com/mod.js", @none)
    assert hop(hits, "http://www.example.com/mod.js").authorization == "Bearer secret"

    assert_caller(hits, "https://www.example.com/jump", @both, "extra", "Bearer secret")
    assert_caller(hits, "https://www.example.com:8443/landed", @both, "extra", "Bearer secret")
  end

  test "existing same-site, partition, and prefix rules still apply" do
    hits =
      crawl_routes("https://www.example.com/start", [
        {%{host: "www.example.com", path: "/start"}, page(rules_page(), rules_cookies())},
        {%{host: "other.test", path: "/page"},
         asset("text/html", ~s|<img src="https://cdn.example.com/from-other.png">|)}
      ])

    assert hop(hits, "https://www.example.com/app.js").cookie["plain"] == "1"
    assert hop(hits, "https://www.example.com/app.js").cookie["__Host-a"] == "1"
    assert hop(hits, "https://www.example.com/app.js").cookie["part"] == "1"
    assert hop(hits, "https://cdn.example.com/plain.png").cookie["plain"] == "1"
    assert hop(hits, "https://cdn.example.com/plain.png").cookie["open"] == "1"
    assert hop(hits, "https://cdn.example.com/plain.png").cookie["part"] == "1"
    refute hop(hits, "https://cdn.example.com/plain.png").cookie["__Host-a"]
    assert_cookie(hits, "https://cdn.example.com/from-other.png", @open)

    first =
      crawl_routes("https://www.example.com/jar", [
        {%{path: "/jar"}, page(~s|<a href="/jar-next"></a>|)}
      ])

    assert_cookie(first, "https://www.example.com/jar-next", @both)

    other =
      crawl_routes(
        "https://www.example.com/jar-other",
        [{%{path: "/jar-other"}, asset("text/html", "other")}],
        scope: unique_scope("credential-scope")
      )

    assert_cookie(other, "https://www.example.com/jar-other", @none)
  end

  test "a reset drops cookies and ignores a late set-cookie" do
    scope = unique_scope("credential-reset")
    hits = hits()

    adapter = fn request ->
      record(hits, request)

      response =
        if request.url.path == "/reset" do
          Store.drop_scope(scope)
          page("reset")
        else
          asset("text/html", "after")
        end

      {request, response}
    end

    crawl("https://www.example.com/reset", adapter, scope: scope)
    assert Store.cookie_header(scope, "https://www.example.com/after") == nil

    crawl("https://www.example.com/after", adapter, scope: scope)
    assert_cookie(hits, "https://www.example.com/after", @none)
  end

  defp module_page do
    """
    <script type="module" src="/app.js"></script>
    <script type="module" src="https://www.example.com:443/app.js"></script>
    <script type="module" src="https://cdn.example.com/app.js"></script>
    <script type="module" src="https://www.example.com:8443/app.js"></script>
    <script type="module" src="https://other.test/app.js" crossorigin="use-credentials"></script>
    <script type="module" src="https://other.test/anon.js" crossorigin="anonymous"></script>
    <link rel="modulepreload" href="https://cdn.example.com/preload.js">
    <script type="module" crossorigin="Use-Credentials">
    import "https://other.test/lib.js";
    import "https://cdn.example.com/cred-lib.js";
    </script>
    <script>
    import("/lib.js");
    import("https://cdn.example.com/lib.js");
    new Worker("/worker.js");
    new Worker("https://cdn.example.com/worker.js");
    CSS.paintWorklet.addModule("https://cdn.example.com/paint.js");
    </script>
    <script src="https://cdn.example.com/classic.js"></script>
    <link rel="preload" as="script" href="https://cdn.example.com/preload-classic.js">
    <link rel="preload" as="worker" href="/preload-worker.js">
    <link rel="preload" as="worker" href="https://cdn.example.com/cred-worker.js" crossorigin="use-credentials">
    """
  end

  defp font_page do
    """
    <link rel="stylesheet" href="/app.css">
    <link rel="stylesheet" href="/anon.css" crossorigin="anonymous">
    <link rel="stylesheet" href="/cred.css" crossorigin="use-credentials">
    <link rel="preload" as="font" href="https://cdn.example.com/preload.woff2">
    <style>
    @import "https://cdn.example.com/inline.css";
    @font-face { src: url("https://cdn.example.com/inline-font.woff2"); }
    body { background: url("https://other.test/inline-bg.png"); }
    div { background-image: image-set("https://cdn.example.com/set.png" 1x); }
    div { background-image: image("https://other.test/picture.png"); }
    </style>
    """
  end

  defp app_css do
    """
    @import "https://cdn.example.com/extra.css";
    @font-face { src: url("/font.woff2"), url("https://cdn.example.com/font.woff2"); }
    body { background: url("https://other.test/bg.png"); }
    """
  end

  defp anon_css do
    """
    @import "https://cdn.example.com/anon-extra.css";
    @font-face { src: url("https://cdn.example.com/anon-font.woff2"); }
    body { background: url("https://cdn.example.com/anon-bg.png"); }
    """
  end

  defp cred_css do
    """
    @import "https://cdn.example.com/cred-extra.css";
    @font-face { src: url("https://cdn.example.com/cred-font.woff2"); }
    """
  end

  defp crossorigin_page do
    """
    <img src="/anon.png" crossorigin="anonymous">
    <img src="https://other.test/plain.png">
    <img src="https://other.test/cred.png" crossorigin="Use-Credentials">
    <img src="https://other.test/anon.png" crossorigin="anonymous">
    <img src="https://other.test/empty.png" crossorigin="">
    <img src="https://other.test/bogus.png" crossorigin="bogus">
    <img src="https://cdn.example.com/site.png">
    <img src="https://cdn.example.com/anon-site.png" crossorigin="Anonymous">
    <script src="https://cdn.example.com/site.js"></script>
    <link rel="stylesheet" href="https://cdn.example.com/site.css">
    <link rel="preload" as="image" href="https://cdn.example.com/hero.png" imagesrcset="https://cdn.example.com/hero-2x.png 2x" crossorigin="anonymous">
    <link rel="preload" as="image" href="https://cdn.example.com/plain-hero.png" imagesrcset="https://cdn.example.com/plain-hero-2x.png 2x">
    <svg><image href="https://cdn.example.com/icon.png" crossorigin="anonymous"></image></svg>
    <svg><image href="https://cdn.example.com/plain-icon.png"></image></svg>
    <svg><image xlink:href="https://cdn.example.com/xlink-icon.png" crossorigin="anonymous"></image></svg>
    <iframe src="https://other.test/anon-frame" crossorigin="anonymous"></iframe>
    <object data="https://other.test/anon-object" crossorigin="anonymous"></object>
    <embed src="https://other.test/anon-embed" crossorigin="anonymous">
    """
  end

  defp prefetch_page do
    """
    <link rel="prefetch" href="/soon">
    <link rel="prefetch" href="https://cdn.example.com/soon">
    <link rel="prefetch" href="https://other.test/next">
    <link rel="prefetch" href="https://other.test/anon-next" crossorigin="anonymous">
    <link rel="prefetch" href="https://other.test/cred-next" crossorigin="use-credentials">
    <a href="https://other.test/link"></a>
    <area href="https://other.test/area"></area>
    <meta http-equiv="refresh" content="0; url=https://other.test/refresh">
    <link rel="prerender" href="https://other.test/prerender">
    <iframe src="https://other.test/frame"></iframe>
    <object data="https://other.test/object"></object>
    <embed src="https://other.test/embed"></embed>
    <script type="speculationrules">
    {
      "prefetch": [
        {"urls": ["https://other.test/spec-next", "https://cdn.example.com/spec-soon"]},
        {"source": "document", "urls": ["https://other.test/ignored-doc"]}
      ],
      "prerender": [
        {"urls": ["https://other.test/spec-render"]},
        {"where": {"href_matches": "/where-hidden"}}
      ]
    }
    </script>
    """
  end

  defp redirect_page do
    """
    <script type="module" src="/app.js"></script>
    <img src="/pic.png">
    <a href="/go"></a>
    """
  end

  defp home_page do
    """
    <script type="module" src="/app.js"></script>
    <script type="module" src="https://shop.example.com/back.js"></script>
    """
  end

  defp caller_page do
    """
    <script type="module" src="/app.js"></script>
    <script type="module" src="https://cdn.example.com/app.js"></script>
    <img src="https://other.test/anon.png" crossorigin="anonymous">
    <link rel="prefetch" href="/soon">
    <link rel="prefetch" href="https://other.test/next">
    <a href="https://www.example.com:8443/next"></a>
    <script type="module" src="https://www.example.com:8443/app.js"></script>
    <script type="module" src="/mod.js"></script>
    <a href="/jump"></a>
    <a href="https://other.test/land"></a>
    """
  end

  defp rules_page do
    """
    <script type="module" src="/app.js"></script>
    <img src="https://cdn.example.com/plain.png">
    <a href="https://other.test/page"></a>
    """
  end

  defp rules_cookies do
    [
      "plain=1; Domain=example.com; Path=/",
      "part=1; Domain=example.com; Path=/; Secure; SameSite=None; Partitioned",
      "__Host-a=1; Secure; Path=/"
    ]
  end

  defp session_cookies do
    [
      "session=1; Domain=example.com; Path=/; SameSite=Lax",
      "open=1; Domain=example.com; Path=/; Secure; SameSite=None"
    ]
  end

  # Domain=example.com does not match other.test. The foreign host's own
  # cookies are what an include request can send there.
  defp seed_foreign_cookies(scope) do
    Store.save_cookies(scope, "https://other.test/", [
      "session=1; Path=/; SameSite=Lax",
      "open=1; Path=/; Secure; SameSite=None"
    ])
  end

  defp page(body, extra \\ []) do
    Req.Response.new(
      status: 200,
      headers:
        [
          {"content-type", "text/html"},
          {"set-cookie", "session=1; Domain=example.com; Path=/; SameSite=Lax"},
          {"set-cookie", "open=1; Domain=example.com; Path=/; Secure; SameSite=None"}
        ] ++ Enum.map(extra, &{"set-cookie", &1}),
      body: body
    )
  end

  defp asset(type, body) do
    Req.Response.new(status: 200, headers: [{"content-type", type}], body: body)
  end

  defp redirect(location, cookies \\ []) do
    Req.Response.new(
      status: 302,
      headers: [{"location", location} | Enum.map(cookies, &{"set-cookie", &1})],
      body: ""
    )
  end

  defp crawl_routes(url, routes, extra \\ []) do
    hits = hits()
    crawl(url, serve(hits, routes), extra)
    hits
  end

  defp serve(hits, routes) do
    fn request ->
      record(hits, request)
      {request, route_response(request, routes)}
    end
  end

  defp route_response(request, routes) do
    Enum.find_value(routes, fn {spec, response} ->
      if route?(request, spec), do: response
    end) || asset("text/plain", "")
  end

  defp route?(request, spec) do
    host? = is_nil(spec[:host]) or request.url.host == spec[:host]
    path? = is_nil(spec[:path]) or request.url.path == spec[:path]
    scheme? = is_nil(spec[:scheme]) or request.url.scheme == spec[:scheme]
    port? = is_nil(spec[:port]) or same_port?(request.url.scheme, request.url.port, spec[:port])
    host? and path? and scheme? and port?
  end

  defp crawl(url, adapter, extra) do
    scope = extra[:scope] || unique_scope("credentials")
    seed_foreign_cookies(scope)

    opts =
      Keyword.merge(
        [
          store: Store,
          workers: 1,
          scope: scope,
          retries: 0,
          max_depths: 3,
          respect_robots: false,
          url_filter: AllowAll,
          assets: ["js", "css", "images"],
          user_agent: "Crawler/1.5.0 (test)",
          req_options: [adapter: adapter, retry: false]
        ],
        extra
      )

    {:ok, opts} = start_crawl(url, opts)
    await_idle(opts)
    opts
  end

  defp hits do
    {:ok, hits} = Agent.start_link(fn -> [] end)
    hits
  end

  defp record(hits, request) do
    Agent.update(hits, &[request_fact(request) | &1])
  end

  defp request_fact(request) do
    %{
      scheme: request.url.scheme,
      host: request.url.host,
      port: request.url.port,
      path: request.url.path,
      cookie: cookie_map(Req.Request.get_header(request, "cookie")),
      authorization: request |> Req.Request.get_header("authorization") |> List.first()
    }
  end

  defp requested(hits), do: Agent.get(hits, & &1)

  defp requests(hits, url), do: Enum.filter(requested(hits), &same_request?(&1, url))

  defp requested?(hits, url), do: requests(hits, url) != []

  defp hop(hits, url) do
    case requests(hits, url) do
      [fact | _] -> fact
      [] -> flunk("no request for #{url}\n#{inspect(requested(hits), pretty: true)}")
    end
  end

  defp same_request?(fact, url) do
    uri = URI.parse(url)

    fact.scheme == uri.scheme and fact.host == uri.host and fact.path == uri.path and
      same_port?(uri.scheme, fact.port, uri.port)
  end

  defp same_port?("https", nil, nil), do: true
  defp same_port?("https", 443, nil), do: true
  defp same_port?("https", nil, 443), do: true
  defp same_port?("https", 443, 443), do: true
  defp same_port?("http", nil, nil), do: true
  defp same_port?("http", 80, nil), do: true
  defp same_port?("http", nil, 80), do: true
  defp same_port?("http", 80, 80), do: true
  defp same_port?(_scheme, left, right), do: left == right

  defp assert_cookie(hits, url, expected), do: assert(hop(hits, url).cookie == expected)

  defp assert_caller(hits, url, jar, caller, authorization) do
    fact = hop(hits, url)
    assert fact.cookie == Map.put(jar, caller, "1")
    assert fact.authorization == authorization
  end

  defp assert_blank(hits, url) do
    fact = hop(hits, url)
    refute fact.cookie["extra"]
    assert fact.authorization == nil
  end

  defp cookie_map(values) do
    values
    |> List.wrap()
    |> Enum.flat_map(&String.split(&1, ";"))
    |> Enum.reject(&(&1 == ""))
    |> Map.new(fn piece ->
      [name, value] = piece |> String.trim() |> String.split("=", parts: 2)
      {name, value}
    end)
  end
end
