defmodule Crawler.CrawlIndirectScriptLoadsTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

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
  @secret "Bearer secret"

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
  end

  test "new URL bases use the script, the opened page, or the document base" do
    scope = unique_scope("indirect-bases")
    root = tmp(scope, "archive")
    on_exit(fn -> File.rm_rf(root) end)

    page = "https://example.com/dir/page.html"
    script = "https://example.com/js/app.js"

    {hits, export} =
      crawl_routes(
        page,
        [
          {%{host: "example.com", path: "/dir/page.html"}, html(base_page())},
          {%{host: "example.com", path: "/js/app.js"}, javascript(app_script())}
        ],
        scope: scope,
        save_to: root
      )

    for url <- [
          script,
          "https://example.com/js/from-script.js",
          "https://example.com/dir/from-page.js",
          "https://example.com/dir/self-page.js",
          "https://example.com/assets/from-base.js",
          "https://example.com/dir/shared.js",
          "https://example.com/assets/paint.js",
          "https://example.com/dir/heard.js",
          "https://example.com/assets/inline-base.js",
          "https://example.com/dir/inline-page.js",
          "https://example.com/js/fetched-meta.js",
          "https://example.com/js/bare-meta.js"
        ] do
      assert_one(hits, url)
    end

    for path <- [
          "/js/skip.js",
          "/dir/skip.js",
          "/assets/skip.js",
          "/skip.js",
          "/js/fetched-loc.js",
          "/dir/fetched-loc.js",
          "/js/bare-loc.js",
          "/dir/bare-loc.js",
          "/js/win-loc.js",
          "/dir/win-loc.js",
          "/js/self-page.js",
          "/assets/from-page.js",
          "/js/from-page.js",
          "/dir/from-script.js",
          "/assets/inline-page.js",
          "/dir/inline-base.js"
        ] do
      refute_path(hits, path)
    end

    page_resource = resource_for_url(export, page)
    script_resource = reference_target(export, page_resource, script)

    assert_link_opens(
      export,
      script_resource,
      reference_target(export, script_resource, "https://example.com/js/from-script.js")
    )

    assert_link_opens(
      export,
      script_resource,
      reference_target(export, script_resource, "https://example.com/dir/from-page.js")
    )

    assert_link_opens(
      export,
      page_resource,
      reference_target(export, page_resource, "https://example.com/assets/inline-base.js")
    )

    assert_link_opens(
      export,
      page_resource,
      reference_target(export, page_resource, "https://example.com/dir/inline-page.js")
    )
  end

  test "location is the page that was opened after a redirect" do
    hits =
      crawl_routes("https://example.com/old", [
        {%{host: "example.com", path: "/old"}, redirect("https://example.com/dir/page.html")},
        {%{host: "example.com", path: "/dir/page.html"}, html(redirect_page())}
      ])

    assert_one(hits, "https://example.com/dir/landed.js")
    assert_one(hits, "https://example.com/assets/based.js")
    refute_path(hits, "/landed.js")
    refute_path(hits, "/old/landed.js")
    refute_path(hits, "/assets/landed.js")
    refute_path(hits, "/dir/based.js")
  end

  test "a file named by new URL keeps the page or the worker" do
    scope = unique_scope("indirect-file-context")
    root = tmp(scope, "archive")
    on_exit(fn -> File.rm_rf(root) end)

    page = "https://example.com/dir/page.html"
    chunk = "https://example.com/js/chunk.js"
    side = "https://example.com/js/side.js"

    {hits, export} =
      crawl_routes(
        page,
        [
          {%{host: "example.com", path: "/dir/page.html"}, html(file_page())},
          {%{host: "example.com", path: "/js/app.js"}, javascript(file_script())},
          {%{host: "example.com", path: "/js/chunk.js"}, javascript(chunk_script())},
          {%{host: "example.com", path: "/js/sw.js"}, javascript(side_worker())},
          {%{host: "example.com", path: "/js/side.js"}, javascript(side_script())}
        ],
        scope: scope,
        save_to: root
      )

    assert_one(hits, chunk)
    assert_one(hits, "https://example.com/dir/from-page.js")
    assert_one(hits, "https://example.com/assets/from-base.js")
    assert_one(hits, "https://example.com/js/sw.js")
    assert_one(hits, side)
    assert_one(hits, "https://example.com/js/from-worker.js")
    refute_path(hits, "/js/from-page.js")
    refute_path(hits, "/js/from-base.js")
    refute_path(hits, "/dir/from-worker.js")
    refute_path(hits, "/assets/from-worker.js")
    refute_path(hits, "/abs.js")

    page_resource = resource_for_url(export, page)
    app = reference_target(export, page_resource, "https://example.com/js/app.js")
    chunk_resource = reference_target(export, app, chunk)
    worker = reference_target(export, app, "https://example.com/js/sw.js")
    side_resource = reference_target(export, worker, side)

    assert_link_opens(
      export,
      chunk_resource,
      reference_target(export, chunk_resource, "https://example.com/dir/from-page.js")
    )

    assert_link_opens(
      export,
      chunk_resource,
      reference_target(export, chunk_resource, "https://example.com/assets/from-base.js")
    )

    assert_link_opens(
      export,
      side_resource,
      reference_target(export, side_resource, "https://example.com/js/from-worker.js")
    )
  end

  test "register(new URL) loads a service worker and the scripts it imports" do
    page = "https://example.com/dir/page.html"

    hits =
      crawl_routes(page, [
        {%{host: "example.com", path: "/dir/page.html"}, html(register_page())},
        {%{host: "example.com", path: "/js/app.js"}, javascript(register_script())},
        {%{host: "example.com", path: "/js/sw.js"}, javascript(sw_script())},
        {%{host: "example.com", path: "/js/lib.js"}, javascript(sw_lib())},
        {%{host: "example.com", path: "/dir/other-sw.js"}, javascript(other_sw())}
      ])

    for url <- [
          "https://example.com/js/sw.js",
          "https://example.com/js/lib.js",
          "https://example.com/js/nested.js",
          "https://example.com/dir/other-sw.js",
          "https://example.com/dir/local.js",
          "https://example.com/dir/from-mod.js"
        ] do
      assert_one(hits, url)
    end

    assert_cookie(hits, "https://example.com/js/sw.js", @both)
    assert_cookie(hits, "https://cdn.example.com/sw.js", @none)
    refute_path(hits, "/vue.js")
    refute_path(hits, "/dir/vue.js")
    refute_path(hits, "/js/vue.js")
    refute_path(hits, "/js/from-mod.js")
  end

  test "importScripts(new URL) follows the worker and the scripts it loads" do
    hits =
      crawl_routes("https://example.com/dir/page.html", [
        {%{host: "example.com", path: "/dir/page.html"}, html(import_scripts_page())},
        {%{host: "example.com", path: "/js/sw.js"}, javascript(import_scripts_worker())},
        {%{host: "example.com", path: "/js/lib.js"}, javascript(import_scripts_lib())}
      ])

    for url <- [
          "https://example.com/js/sw.js",
          "https://example.com/js/lib.js",
          "https://example.com/js/plain.js",
          "https://example.com/js/also.js",
          "https://example.com/js/nested.js",
          "https://example.com/js/meta-lib.js",
          "https://example.com/js/dyn.js"
        ] do
      assert_one(hits, url)
    end

    refute_path(hits, "/dir/also.js")
    refute_path(hits, "/dir/lib.js")
    refute_path(hits, "/dir/nested.js")
    refute_path(hits, "/dir/dyn.js")
    refute_path(hits, "/vue.js")
    refute_path(hits, "/js/vue.js")
    refute_path(hits, "/dir/vue.js")
  end

  test "import(new URL) is a module import and keeps the caller's cookies" do
    hits =
      crawl_routes("https://www.example.com/dir/page.html", [
        {%{host: "www.example.com", path: "/dir/page.html"}, html(import_page())},
        {%{host: "www.example.com", path: "/dir/mod.js"}, javascript(mod_script())},
        {%{host: "www.example.com", path: "/js/lib.js"}, javascript(~s|import "vue";|)},
        {%{host: "cdn.example.com", path: "/anon-entry.js"}, javascript(anon_entry())},
        {%{host: "cdn.example.com", path: "/anon-next.js"},
         javascript(~s|import "./anon-child.js";|)},
        {%{host: "cdn.example.com", path: "/cred-entry.js"}, javascript(cred_entry())},
        {%{host: "cdn.example.com", path: "/next.js"}, javascript(cred_next())}
      ])

    for url <- [
          "https://www.example.com/dir/mod.js",
          "https://www.example.com/dir/local.js",
          "https://www.example.com/assets/based.js",
          "https://www.example.com/js/lib.js",
          "https://cdn.example.com/anon-entry.js",
          "https://cdn.example.com/anon-next.js",
          "https://cdn.example.com/anon-child.js",
          "https://cdn.example.com/cred-entry.js",
          "https://cdn.example.com/next.js",
          "https://cdn.example.com/cred-child.js",
          "https://other.test/cred-child.js"
        ] do
      assert_one(hits, url)
    end

    assert [vue, repeated_vue] = requests(hits, "https://www.example.com/vue.js")
    assert vue == repeated_vue
    assert vue.cookie == @both

    assert_cookie(hits, "https://www.example.com/dir/mod.js", @both)
    assert_cookie(hits, "https://cdn.example.com/mod.js", @none)
    assert_cookie(hits, "https://cdn.example.com/anon-next.js", @none)
    assert_cookie(hits, "https://cdn.example.com/anon-child.js", @none)
    assert_cookie(hits, "https://cdn.example.com/next.js", @both)
    assert_cookie(hits, "https://cdn.example.com/cred-child.js", @both)
    assert_cookie(hits, "https://other.test/cred-child.js", @open)

    refute_path(hits, "/mapped.js")
    refute_path(hits, "/assets/classic-meta.js")
    refute_path(hits, "/dir/classic-meta.js")
    refute_path(hits, "/js/classic-meta.js")
  end

  test "module workers, shared workers, and worklets honor include and omit" do
    hits =
      crawl_routes(
        "https://www.example.com/start",
        [
          {%{host: "www.example.com", path: "/start"}, html(credential_page())},
          {%{host: "cdn.example.com", path: "/included.js"}, javascript(~s|import "./more.js";|)}
        ],
        modifier: CallerModifier
      )

    assert_exchange(hits, "https://cdn.example.com/included.js", @both, nil)
    assert_exchange(hits, "https://cdn.example.com/more.js", @both, nil)
    assert_exchange(hits, "https://www.example.com/omitted.js", @none, @secret)
    assert_exchange(hits, "https://cdn.example.com/local.js", @none, nil)
    assert_exchange(hits, "https://cdn.example.com/classic.js", @none, nil)

    assert_exchange(
      hits,
      "https://www.example.com/classic-home.js",
      Map.put(@both, "extra", "1"),
      @secret
    )

    assert_exchange(hits, "https://cdn.example.com/shared.js", @both, nil)
    assert_exchange(hits, "https://cdn.example.com/paint.js", @both, nil)
    assert_exchange(hits, "https://www.example.com/quiet.js", @none, @secret)
    assert_exchange(hits, "https://cdn.example.com/unknown.js", @none, nil)
  end

  test "a link header keeps crossorigin and uses the same cookies as the tag" do
    hits =
      crawl_routes("https://www.example.com/start", [
        {%{host: "www.example.com", path: "/start"}, html(link_page(), [{"link", link_header()}])}
      ])

    assert_cookie(hits, "https://cdn.example.com/app.js", @both)
    assert_cookie(hits, "https://cdn.example.com/anon.js", @none)
    assert_cookie(hits, "https://cdn.example.com/theme.css", @none)
    assert_cookie(hits, "https://cdn.example.com/cred.css", @both)
    assert_cookie(hits, "https://cdn.example.com/plain.css", @both)
    assert_cookie(hits, "https://cdn.example.com/font.woff2", @none)
    assert_cookie(hits, "https://cdn.example.com/header-empty.css", @none)
    assert_cookie(hits, "https://cdn.example.com/header-bogus.css", @none)

    assert_cookie(hits, "https://cdn.example.com/tag-app.js", @both)
    assert_cookie(hits, "https://cdn.example.com/tag-anon.js", @none)
    assert_cookie(hits, "https://cdn.example.com/tag-theme.css", @none)
    assert_cookie(hits, "https://cdn.example.com/tag-cred.css", @both)
    assert_cookie(hits, "https://cdn.example.com/tag-plain.css", @both)
    assert_cookie(hits, "https://cdn.example.com/tag-font.woff2", @none)
    assert_cookie(hits, "https://cdn.example.com/tag-empty.css", @none)
    assert_cookie(hits, "https://cdn.example.com/tag-bogus.css", @none)
  end

  defp base_page do
    """
    <base href="https://example.com/assets/">
    <script type="module" src="/js/app.js"></script>
    <script type="module">
    new Worker(new URL("./inline-base.js", import.meta.url));
    new Worker(new URL("./inline-page.js", location.href));
    </script>
    """
  end

  defp app_script do
    """
    new Worker(new URL("./from-script.js", import.meta.url));
    new Worker(new URL("./from-page.js", location.href));
    new Worker(new URL("./self-page.js", self.location.href));
    new Worker(new URL("./from-base.js", document.baseURI));
    new SharedWorker(new URL("./shared.js", location.href));
    CSS.paintWorklet.addModule(new URL("./paint.js", document.baseURI));
    audio.audioWorklet.addModule(new URL("./heard.js", location.href));
    new Worker("./" + "skip.js");
    new Worker(new URL("./skip.js", base));
    fetch(new URL("./fetched-loc.js", location.href));
    new URL("./bare-loc.js", location.href);
    fetch(new URL("./fetched-meta.js", import.meta.url));
    new URL("./bare-meta.js", import.meta.url);
    new Worker(new URL("./win-loc.js", window.location.href));
    """
  end

  defp file_page do
    """
    <base href="https://example.com/assets/">
    <script type="module" src="/js/app.js"></script>
    """
  end

  defp file_script do
    """
    new URL("./chunk.js", import.meta.url);
    new Worker(new URL("./sw.js", import.meta.url), {type: "module"});
    """
  end

  defp chunk_script do
    """
    new Worker(new URL("./from-page.js", location.href));
    new Worker(new URL("./from-base.js", document.baseURI));
    """
  end

  defp side_worker, do: ~s|new URL("./side.js", import.meta.url);|

  defp side_script do
    """
    new Worker(new URL("./from-worker.js", location.href));
    new Worker(new URL("https://cdn.example.com/abs.js", document.baseURI));
    """
  end

  defp redirect_page do
    """
    <base href="https://example.com/assets/">
    <script type="module">
    new Worker(new URL("./landed.js", location.href));
    new Worker(new URL("./based.js", document.baseURI));
    </script>
    """
  end

  defp register_page do
    """
    <script type="importmap">{"imports":{"vue":"/vue.js"}}</script>
    <script type="module" src="/js/app.js"></script>
    """
  end

  defp register_script do
    """
    navigator.serviceWorker.register(new URL("./sw.js", import.meta.url));
    navigator.serviceWorker.register(new URL("./other-sw.js", location.href), {type: "module"});
    navigator.serviceWorker.register(new URL("https://cdn.example.com/sw.js", import.meta.url));
    """
  end

  defp sw_script, do: ~s|importScripts("./lib.js");|
  defp sw_lib, do: ~s|importScripts("./nested.js");|

  defp other_sw do
    """
    import "vue";
    import "./local.js";
    importScripts(new URL("./from-mod.js", self.location.href));
    """
  end

  defp import_scripts_page do
    """
    <script type="importmap">{"imports":{"vue":"/vue.js"}}</script>
    <script>
    new Worker("/js/sw.js");
    </script>
    """
  end

  defp import_scripts_worker do
    """
    importScripts(new URL("./lib.js", self.location.href));
    importScripts("./plain.js");
    importScripts(new URL("./also.js", location.href));
    """
  end

  defp import_scripts_lib do
    """
    importScripts(new URL("./nested.js", self.location.href));
    importScripts(new URL("./meta-lib.js", import.meta.url));
    import "vue";
    import("./dyn.js");
    import("vue");
    """
  end

  defp import_page do
    """
    <base href="https://www.example.com/assets/">
    <script type="importmap">{"imports":{"vue":"/vue.js","/js/lib.js":"/mapped.js"}}</script>
    <script>
    import(new URL("./mod.js", location.href));
    import(new URL("./based.js", document.baseURI));
    import(new URL("./classic-meta.js", import.meta.url));
    import(new URL("/js/lib.js", location.href));
    </script>
    <script type="module" src="https://cdn.example.com/anon-entry.js" crossorigin="anonymous"></script>
    <script type="module" src="https://cdn.example.com/cred-entry.js" crossorigin="use-credentials"></script>
    """
  end

  defp mod_script do
    """
    import "vue";
    import "./local.js";
    import "https://cdn.example.com/mod.js";
    """
  end

  defp anon_entry, do: ~s|import(new URL("./anon-next.js", import.meta.url));|
  defp cred_entry, do: ~s|import(new URL("./next.js", import.meta.url));|

  defp cred_next do
    """
    import "./cred-child.js";
    import "https://other.test/cred-child.js";
    """
  end

  defp credential_page do
    """
    <script type="module">
    new Worker("https://cdn.example.com/included.js", {type: "module", credentials: "include"});
    new Worker("/omitted.js", {type: "module", credentials: "omit"});
    new Worker("https://cdn.example.com/local.js", {type: "module"});
    new Worker("https://cdn.example.com/classic.js", {credentials: "include"});
    new Worker("/classic-home.js", {credentials: "include"});
    new SharedWorker("https://cdn.example.com/shared.js", {type: "module", credentials: "include"});
    CSS.paintWorklet.addModule("https://cdn.example.com/paint.js", {credentials: "include"});
    audio.audioWorklet.addModule("/quiet.js", {credentials: "omit"});
    new Worker("https://cdn.example.com/unknown.js", {type: "module", credentials: "Include"});
    </script>
    """
  end

  defp link_page do
    """
    <link rel="modulepreload" href="https://cdn.example.com/tag-app.js" crossorigin="use-credentials">
    <link rel="modulepreload" href="https://cdn.example.com/tag-anon.js" crossorigin>
    <link rel="stylesheet" href="https://cdn.example.com/tag-theme.css" crossorigin="anonymous">
    <link rel="stylesheet" href="https://cdn.example.com/tag-cred.css" crossorigin="Use-Credentials">
    <link rel="stylesheet" href="https://cdn.example.com/tag-plain.css">
    <link rel="preload" as="font" href="https://cdn.example.com/tag-font.woff2" crossorigin="use-credentials">
    <link rel="stylesheet" href="https://cdn.example.com/tag-empty.css" crossorigin="">
    <link rel="stylesheet" href="https://cdn.example.com/tag-bogus.css" crossorigin="bogus">
    """
  end

  defp link_header do
    Enum.join(
      [
        ~s|<https://cdn.example.com/app.js>; rel="modulepreload"; crossorigin="use-credentials"|,
        ~s|<https://cdn.example.com/anon.js>; rel="modulepreload"; crossorigin|,
        ~s|<https://cdn.example.com/theme.css>; rel="stylesheet"; crossorigin="anonymous"|,
        ~s|<https://cdn.example.com/cred.css>; rel="stylesheet"; crossorigin="Use-Credentials"|,
        ~s|<https://cdn.example.com/plain.css>; rel="stylesheet"|,
        ~s|<https://cdn.example.com/font.woff2>; rel="preload"; as="font"; crossorigin="use-credentials"|,
        ~s|<https://cdn.example.com/header-empty.css>; rel="stylesheet"; crossorigin=""|,
        ~s|<https://cdn.example.com/header-bogus.css>; rel="stylesheet"; crossorigin="bogus"|
      ],
      ", "
    )
  end

  defp html(body, headers \\ []) do
    Req.Response.new(
      status: 200,
      headers:
        [
          {"content-type", "text/html"},
          {"set-cookie", "session=1; Domain=example.com; Path=/; SameSite=Lax"},
          {"set-cookie", "open=1; Domain=example.com; Path=/; Secure; SameSite=None"}
        ] ++ headers,
      body: body
    )
  end

  defp javascript(body), do: asset("text/javascript", body)

  defp asset(type, body),
    do: Req.Response.new(status: 200, headers: [{"content-type", type}], body: body)

  defp redirect(location) do
    Req.Response.new(status: 302, headers: [{"location", location}], body: "")
  end

  defp crawl_routes(url, routes, extra \\ []) do
    hits = hits()
    opts = crawl(url, serve(hits, routes), extra)
    if extra[:save_to], do: {hits, ready_export(opts)}, else: hits
  end

  defp serve(hits, routes) do
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      request =
        Req.new(
          url: %URI{
            scheme: Atom.to_string(conn.scheme),
            host: conn.host,
            port: conn.port,
            path: conn.request_path,
            query: if(conn.query_string == "", do: nil, else: conn.query_string)
          },
          headers: conn.req_headers
        )

      record(hits, request)
      response = route_response(request, routes)
      conn = %{conn | resp_headers: Req.get_headers_list(response)}
      Plug.Conn.send_resp(conn, response.status, response.body || "")
    end)

    [plug: {Req.Test, name}, retry: false]
  end

  defp route_response(request, routes) do
    Enum.find_value(routes, fn {spec, response} ->
      if route?(request, spec), do: response
    end) || default_response(request)
  end

  defp route?(request, spec) do
    host? = is_nil(spec[:host]) or request.url.host == spec[:host]
    path? = is_nil(spec[:path]) or request.url.path == spec[:path]
    host? and path?
  end

  defp default_response(request) do
    asset(default_type(request.url.path), "")
  end

  defp default_type(path) do
    cond do
      String.ends_with?(path, ".css") -> "text/css"
      String.ends_with?(path, ".woff2") -> "font/woff2"
      true -> "text/javascript"
    end
  end

  defp crawl(url, req_options, extra) do
    scope = extra[:scope] || unique_scope("indirect-scripts")
    seed_foreign_cookies(scope)

    opts =
      Keyword.merge(
        [
          store: Store,
          workers: 1,
          max_body: 1_048_576,
          max_analysis_bytes: 16 * 1024 * 1024,
          max_manifest_bytes: 16 * 1024 * 1024,
          max_css_work: 5_000,
          max_css_pictures: 1_000,
          scope: scope,
          retries: 0,
          max_depths: 4,
          respect_robots: false,
          url_filter: AllowAll,
          assets: ["js", "css", "images"],
          user_agent: "Crawler/1.5.0 (test)",
          req_options: req_options
        ],
        extra
      )

    {:ok, opts} = start_crawl(url, opts)
    await_idle(opts)
    opts
  end

  defp seed_foreign_cookies(scope) do
    Store.save_cookies(scope, "https://other.test/", [
      "session=1; Path=/; SameSite=Lax",
      "open=1; Path=/; Secure; SameSite=None"
    ])
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
  defp paths(hits), do: Enum.map(requested(hits), & &1.path)

  defp assert_one(hits, url), do: assert([_] = requests(hits, url))

  defp assert_cookie(hits, url, expected) do
    assert [fact] = requests(hits, url)
    assert fact.cookie == expected
  end

  defp assert_exchange(hits, url, cookie, authorization) do
    assert [fact] = requests(hits, url)
    assert fact.cookie == cookie
    assert fact.authorization == authorization
  end

  defp refute_path(hits, path), do: refute(path in paths(hits))

  defp same_request?(fact, url) do
    uri = URI.parse(url)
    fact.scheme == uri.scheme and fact.host == uri.host and fact.path == uri.path
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
