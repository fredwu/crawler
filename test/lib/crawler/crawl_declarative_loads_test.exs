defmodule Crawler.CrawlDeclarativeLoadsTest do
  use Crawler.TestCase, async: false

  import Plug.Conn
  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store
  alias Crawler.Store.Page

  test "prefetch, prerender, and next links stay on the site", context do
    page = context.url <> "/nav"
    base = context.url <> "/blog/"

    html = """
    <base href="#{base}">
    <link rel="prefetch" href="next-chunk">
    <link rel="prerender" href="/app">
    <link rel="next" href="page/2">
    <link rel="prev" href="/blog">
    <link rel="previous" href="/blog/old">
    <link rel="prefetch" href="https://other.test/out">
    """

    headers = [
      {"link",
       ~s|</blog/from-header>; rel="prefetch", </manifest.webmanifest>; rel="manifest", <https://other.test/page>; rel="next"|}
    ]

    expect_html(context, "/nav", html, headers)

    for path <- ["/blog/next-chunk", "/app", "/blog/page/2", "/blog", "/blog/old"] do
      expect_html(context, path, "page")
    end

    {opts, root} = run(page, context)
    saved = read_resource(root, resource_for_url(root, page))

    for path <- ["/blog/next-chunk", "/app", "/blog/page/2", "/blog", "/blog/old"] do
      assert Store.find_processed({context.url <> path, opts.scope})
    end

    for url <- [
          context.url <> "/blog/from-header",
          context.url <> "/manifest.webmanifest",
          "https://other.test/out",
          "https://other.test/page"
        ] do
      refute Store.find({url, opts.scope})
    end

    target = assert_points(saved, page, context.url <> "/blog/next-chunk", root)
    assert read_resource(root, target) == <<0xEF, 0xBB, 0xBF>> <> "page"
  end

  test "nofollow skips next and still fetches prefetch and stylesheets", context do
    page = context.url <> "/quiet"

    html = """
    <link rel="next" href="/secret">
    <link rel="prefetch" href="/still">
    <link rel="stylesheet" href="/stay.css">
    """

    expect_html(context, "/quiet", html, [{"x-robots-tag", "nofollow"}])
    expect_html(context, "/still", "still")
    expect_css(context, "/stay.css")

    {opts, root} = run(page, context, assets: ["css"])
    saved = read_resource(root, resource_for_url(root, page))

    refute Store.find({context.url <> "/secret", opts.scope})
    assert Store.find_processed({context.url <> "/still", opts.scope})
    assert Store.find_processed({context.url <> "/stay.css", opts.scope})
    target = assert_points(saved, page, context.url <> "/still", root)
    assert read_resource(root, target) == <<0xEF, 0xBB, 0xBF>> <> "still"
  end

  test "nofollow on a next link skips that link only", context do
    page = context.url <> "/marked"

    html = """
    <link rel="next nofollow" href="/skipped">
    <link rel="next" href="/kept">
    """

    expect_html(context, "/marked", html)
    expect_html(context, "/kept", "kept")

    {opts, _root} = run(page, context)

    refute Store.find({context.url <> "/skipped", opts.scope})
    assert Store.find_processed({context.url <> "/kept", opts.scope})
  end

  test "respect_robots false still follows next", context do
    page = context.url <> "/open"

    html = """
    <meta name="robots" content="nofollow">
    <link rel="next" href="/followed">
    """

    expect_html(context, "/open", html)
    expect_html(context, "/followed", "followed")

    {opts, _root} = run(page, context, respect_robots: false)

    assert Store.find_processed({context.url <> "/followed", opts.scope})
  end

  test "a same-site next link header is fetched", context do
    page = context.url <> "/header-next"

    expect_html(context, "/header-next", "<p>Hi</p>", [
      {"link", ~s|</header-next-page>; rel="next"|}
    ])

    expect_html(context, "/header-next-page", "next")

    {opts, _root} = run(page, context)

    assert Store.find_processed({context.url <> "/header-next-page", opts.scope})
  end

  test "preload fetch, track, and audio follow the asset channels", context do
    page = context.url <> "/preloads"
    preload = preload_document()

    expect_html(context, "/preloads", preload, [
      {"link",
       ~s|</header.json>; rel="preload"; as="fetch", </header.vtt>; rel="preload"; as="track"|}
    ])

    for path <- ["/data.json", "/header.json"] do
      expect_bytes(context, path, "application/json", "{}")
    end

    for path <- ["/a.vtt", "/b.vtt", "/header.vtt", "/from-track.vtt"] do
      expect_bytes(context, path, "text/vtt", "WEBVTT")
    end

    expect_bytes(context, "/preload-audio.mp3", "audio/mpeg", "audio")

    {opts, root} = run(page, context, assets: ["css", "images"])
    saved = read_resource(root, resource_for_url(root, page))

    for path <- [
          "/data.json",
          "/header.json",
          "/a.vtt",
          "/b.vtt",
          "/header.vtt",
          "/from-track.vtt",
          "/preload-audio.mp3"
        ] do
      assert Store.find_processed({context.url <> path, opts.scope})
    end

    for path <- ["/c.vtt", "/spaced.json"] do
      refute Store.find({context.url <> path, opts.scope})
    end

    target = assert_points(saved, page, context.url <> "/data.json", root)
    assert read_resource(root, target) == "{}"
    target = assert_points(saved, page, context.url <> "/preload-audio.mp3", root)
    assert read_resource(root, target) == "audio"
    assert saved =~ ~s|href="/spaced.json"|
    assert saved =~ ~s|href="/c.vtt"|
  end

  test "preload fetch does not require images and track does", context do
    page = context.url <> "/preloads-css"

    expect_html(context, "/preloads-css", preload_document(), [
      {"link",
       ~s|</header.json>; rel="preload"; as="fetch", </header.vtt>; rel="preload"; as="track"|}
    ])

    for path <- ["/data.json", "/header.json"] do
      expect_bytes(context, path, "application/json", "{}")
    end

    {opts, root} = run(page, context, assets: ["css"])
    saved = read_resource(root, resource_for_url(root, page))

    assert Store.find_processed({context.url <> "/data.json", opts.scope})
    assert Store.find_processed({context.url <> "/header.json", opts.scope})

    for path <- ["/a.vtt", "/b.vtt", "/header.vtt", "/from-track.vtt", "/preload-audio.mp3"] do
      refute Store.find({context.url <> path, opts.scope})
    end

    assert saved =~ ~s|href="/preload-audio.mp3"|
  end

  test "preload as=fetch does not crawl links inside the response", context do
    page = context.url <> "/fetch-preload"
    notes = context.url <> "/notes.html"

    expect_html(context, "/fetch-preload", """
    <link rel="preload" as="fetch" href="/notes.html">
    <link rel="preload" as="fetch" href="/notes.js">
    """)

    expect_html(context, "/notes.html", """
    <base href="#{context.url}/notes/">
    <a href="/secret">secret</a>
    <link rel="stylesheet" href="/note.css">
    <script type="speculationrules">{"prefetch":[{"urls":["/soon"]}]}</script>
    """)

    expect_bytes(context, "/notes.js", "application/javascript", ~s|import("./dep.js");|)

    {opts, root} = run(page, context, assets: ["css"])
    saved = read_resource(root, resource_for_url(root, notes))

    for path <- ["/notes.html", "/notes.js"] do
      assert Store.find_processed({context.url <> path, opts.scope})
    end

    for path <- ["/secret", "/note.css", "/dep.js", "/soon"] do
      refute Store.find({context.url <> path, opts.scope})
    end

    assert saved =~ ~s|href="#{context.url}/notes/"|
    assert saved =~ ~s|href="/secret"|
    assert saved =~ ~s|href="/note.css"|
    assert saved =~ ~s|"/soon"|
  end

  test "an iframe crawls a document that a fetch preload already recorded", context do
    page = context.url <> "/fetch-shared"
    article = context.url <> "/shared-article"
    nxt = context.url <> "/shared-next"

    expect_html(
      context,
      "/fetch-shared",
      """
      <iframe title="Article" src="/shared-article"></iframe>
      <iframe title="Next" src="/shared-next"></iframe>
      """,
      [
        {"link",
         ~s|</shared-article>; rel="preload"; as="fetch", </shared-next>; rel="preload"; as="fetch"|}
      ]
    )

    expect_html(context, "/shared-article", """
    <a href="/shared-section">Section</a>
    <link rel="stylesheet" href="/shared-article.css">
    <script type="speculationrules">{"prefetch":[{"urls":["/shared-soon"]}]}</script>
    """)

    expect_html(context, "/shared-next", """
    <a href="/shared-after">After</a>
    """)

    expect_html(context, "/shared-section", "section")
    expect_html(context, "/shared-after", "after")
    expect_html(context, "/shared-soon", "soon")
    expect_css(context, "/shared-article.css")

    {opts, root} = run(page, context, assets: ["css"])

    for path <- [
          "/shared-article",
          "/shared-next",
          "/shared-section",
          "/shared-after",
          "/shared-soon",
          "/shared-article.css"
        ] do
      assert Store.find_processed({context.url <> path, opts.scope})
    end

    seed = resource_for_url(root, page)
    source = linked_resource(root, seed, "iframe[title=Article]", "src", article)
    target = reference_target(root, source, context.url <> "/shared-section")
    assert_link_opens(root, source, target)
    target = reference_target(root, source, context.url <> "/shared-article.css")
    assert_link_opens(root, source, target)
    target = reference_target(root, source, context.url <> "/shared-soon")
    assert_link_opens(root, source, target)
    source = linked_resource(root, seed, "iframe[title=Next]", "src", nxt)
    target = reference_target(root, source, context.url <> "/shared-after")
    assert_link_opens(root, source, target)
  end

  test "a script tag crawls a script that a fetch preload already recorded", context do
    page = context.url <> "/fetch-script"
    script = context.url <> "/shared-app.js"

    expect_html(
      context,
      "/fetch-script",
      """
      <script src="/shared-app.js"></script>
      """,
      [
        {"link", ~s|</shared-app.js>; rel="preload"; as="fetch"|}
      ]
    )

    expect_bytes(
      context,
      "/shared-app.js",
      "application/javascript",
      ~s|import("./shared-dep.js");|
    )

    expect_bytes(context, "/shared-dep.js", "application/javascript", "export default 1\n")

    {opts, root} = run(page, context, assets: ["js"])

    assert Store.find_processed({script, opts.scope})
    assert Store.find_processed({context.url <> "/shared-dep.js", opts.scope})
    seed = resource_for_url(root, page)
    source = linked_resource(root, seed, "script", "src", script)
    target = reference_target(root, source, context.url <> "/shared-dep.js")
    assert_link_opens(root, source, target)
    assert [_, href] = Regex.run(~r/import\("([^"]+)"\)/, read_resource(root, source))
    assert_opens(root, source, target, href)
    assert read_resource(root, target) == "export default 1\n"
  end

  test "an iframe opens a fetch document when page storage is off", context do
    page = context.url <> "/fetch-unstored"
    article = context.url <> "/unstored-article"
    script = context.url <> "/unstored-app.js"
    data = context.url <> "/unstored-data.json"

    expect_html(
      context,
      "/fetch-unstored",
      """
      <iframe title="Article" src="/unstored-article"></iframe>
      <script src="/unstored-app.js"></script>
      <iframe title="Data" src="/unstored-data.json"></iframe>
      """,
      [
        {"link",
         ~s|</unstored-article>; rel="preload"; as="fetch", </unstored-app.js>; rel="preload"; as="fetch", </unstored-data.json>; rel="preload"; as="fetch"|}
      ]
    )

    expect_html(context, "/unstored-article", """
    <base href="#{context.url}/unstored/">
    <a href="child">Child</a>
    """)

    expect_html(context, "/unstored/child", "child")

    expect_bytes(
      context,
      "/unstored-app.js",
      "application/javascript",
      ~s|import("./unstored-dep.js");|
    )

    expect_bytes(context, "/unstored-dep.js", "application/javascript", "export default 1\n")

    expect_bytes(
      context,
      "/unstored-data.json",
      "application/json",
      ~s|{"note":"<a href='/from-unstored-json'>y</a>"}|
    )

    {opts, root} = run(page, context, assets: ["js"], store: nil)

    for path <- ["/unstored-article", "/unstored/child", "/unstored-app.js", "/unstored-dep.js"] do
      assert Store.find_processed({context.url <> path, opts.scope})
    end

    assert Store.find_processed({data, opts.scope})
    refute Store.find({context.url <> "/from-unstored-json", opts.scope})

    for url <- [article, script, data] do
      assert %Page{
               url: ^url,
               processed: true,
               body: nil,
               opts: nil,
               analysis: nil,
               interpretation: nil,
               source_revision: nil,
               credit: nil,
               target_handle: target
             } =
               Store.find({url, opts.scope})

      assert is_reference(target)
    end

    seed = resource_for_url(root, page)
    source = linked_resource(root, seed, "iframe[title=Article]", "src", article)
    target = reference_target(root, source, context.url <> "/unstored/child")
    assert_link_opens(root, source, target)
    seed = resource_for_url(root, page)
    source = linked_resource(root, seed, "script", "src", script)
    target = reference_target(root, source, context.url <> "/unstored-dep.js")
    assert_link_opens(root, source, target)
    target = linked_resource(root, seed, "iframe[title=Data]", "src", data)
    assert read_resource(root, target) =~ "from-unstored-json"
  end

  test "an iframe leaves a non-document fetch preload closed", context do
    page = context.url <> "/fetch-closed"

    expect_html(
      context,
      "/fetch-closed",
      """
      <iframe title="Captions" src="/closed-clip.vtt"></iframe>
      <iframe title="Data" src="/closed-data.json"></iframe>
      """,
      [
        {"link",
         ~s|</closed-clip.vtt>; rel="preload"; as="track", </closed-data.json>; rel="preload"; as="fetch"|}
      ]
    )

    expect_bytes(
      context,
      "/closed-clip.vtt",
      "text/vtt",
      ~s|WEBVTT\n\n<a href="/from-closed-track">x</a>|
    )

    expect_bytes(
      context,
      "/closed-data.json",
      "application/json",
      ~s|{"note":"<a href='/from-closed-json'>y</a>"}|
    )

    {opts, root} = run(page, context, assets: ["images"])

    assert Store.find_processed({context.url <> "/closed-clip.vtt", opts.scope})
    assert Store.find_processed({context.url <> "/closed-data.json", opts.scope})
    refute Store.find({context.url <> "/from-closed-track", opts.scope})
    refute Store.find({context.url <> "/from-closed-json", opts.scope})

    seed = resource_for_url(root, page)

    captions =
      linked_resource(
        root,
        seed,
        "iframe[title=Captions]",
        "src",
        context.url <> "/closed-clip.vtt"
      )

    data =
      linked_resource(root, seed, "iframe[title=Data]", "src", context.url <> "/closed-data.json")

    assert read_resource(root, captions) =~ ~s|href="/from-closed-track"|
    assert read_resource(root, data) =~ ~s|href='/from-closed-json'|
  end

  test "an iframe waits for an in-flight fetch preload of a document", context do
    page = context.url <> "/fetch-wait"
    article = context.url <> "/wait-article"
    scope = unique_scope("fetch-wait")
    parent_root = tmp(scope)
    root = Path.join(parent_root, "archive")
    on_exit(fn -> File.rm_rf(parent_root) end)
    seed_key = make_ref()
    fetch_key = make_ref()
    document_key = make_ref()

    expect_html(context, "/fetch-wait", "<p>seed</p>")
    expect_html(context, "/from-fetch-wait", "child")
    body = ~s|<a href="/from-fetch-wait">Child</a>|
    expect_html(context, "/wait-article", body)

    assert {:ok, opts} =
             start_crawl(page,
               scope: scope,
               workers: 3,
               max_body: 1_048_576,
               max_analysis_bytes: 16_777_216,
               max_manifest_bytes: 16_777_216,
               retries: 0,
               max_depths: 4,
               assets: ["css"],
               store: Store,
               save_to: root,
               req_options: context.req_options,
               parser: Crawler.ManagedSnapshotHelpers.GateParser,
               managed_test_gates: [
                 {page, "a", self(), seed_key},
                 {article, "fetch", self(), fetch_key},
                 {article, "a", self(), document_key}
               ]
             )

    on_exit(fn -> Crawler.stop(opts) end)
    assert_receive {:managed_parser_held, ^seed_key, seed, _, _, _}, 2_000
    on_exit(fn -> send(seed, {:managed_parser_release, seed_key}) end)

    assert {:ok, _} =
             Crawler.crawl(
               article,
               Map.merge(opts, %{html_tag: "fetch", reference_tag: "fetch", depth: 1})
             )

    assert_receive {:managed_parser_held, ^fetch_key, fetch, "text/html", revision, fetch_target},
                   2_000

    assert is_reference(revision) and is_reference(fetch_target)
    on_exit(fn -> send(fetch, {:managed_parser_release, fetch_key}) end)

    assert {:ok, _} =
             Crawler.crawl(
               article,
               Map.merge(opts, %{
                 html_tag: "a",
                 reference_tag: "iframe",
                 page_open: false,
                 depth: 1
               })
             )

    refute_receive {:managed_parser_held, ^document_key, _, _, _, _}, 200
    refute Store.find_processed({context.url <> "/from-fetch-wait", scope})
    assert {:ok, %{ready?: false}} = Crawler.export_status(opts)
    send(fetch, {:managed_parser_release, fetch_key})

    assert_receive {:managed_parser_held, ^document_key, document, "text/html", ^revision,
                    document_target},
                   2_000

    refute document_target == fetch_target
    send(document, {:managed_parser_release, document_key})
    send(seed, {:managed_parser_release, seed_key})
    export = ready_root(opts)
    assert Store.find_processed({context.url <> "/from-fetch-wait", scope})
    resources = Enum.filter(export.manifest["resources"], &(&1["url"] == article))

    assert [source] =
             Enum.filter(resources, fn resource ->
               Enum.any?(export.manifest["references"], &(&1["from"] == resource["id"]))
             end)

    assert source
    target = reference_target(export, source, context.url <> "/from-fetch-wait")
    assert_link_opens(export, source, target)
    assert read_resource(export, target) == <<0xEF, 0xBB, 0xBF>> <> "child"
  end

  test "preload fetch and track are skipped when no asset channel is on", context do
    page = context.url <> "/preloads-none"

    expect_html(context, "/preloads-none", preload_document(), [
      {"link",
       ~s|</header.json>; rel="preload"; as="fetch", </header.vtt>; rel="preload"; as="track"|}
    ])

    {opts, _root} = run(page, context, assets: [])

    for path <- [
          "/data.json",
          "/header.json",
          "/a.vtt",
          "/b.vtt",
          "/header.vtt",
          "/from-track.vtt",
          "/c.vtt",
          "/preload-audio.mp3",
          "/spaced.json"
        ] do
      refute Store.find({context.url <> path, opts.scope})
    end
  end

  test "a disabled stylesheet is left in place", context do
    page = context.url <> "/sheets"

    html = """
    <link rel="stylesheet" href="/on.css">
    <link rel="stylesheet" href="/off.css" disabled>
    <link rel="stylesheet" href="/blank.css" disabled="">
    <link rel="alternate stylesheet" title="Dark" href="/dark.css">
    <link rel="alternate stylesheet" title="Dim" href="/dim.css" disabled="false">
    """

    expect_html(context, "/sheets", html, [
      {"link", ~s|</header.css>; rel="stylesheet"|},
      {"refresh", "0; url=/next"}
    ])

    for path <- ["/on.css", "/dark.css", "/header.css"] do
      expect_css(context, path)
    end

    expect_html(context, "/next", "next")

    {opts, root} = run(page, context, assets: ["css"])
    saved = read_resource(root, resource_for_url(root, page))

    for path <- ["/on.css", "/dark.css", "/header.css", "/next"] do
      assert Store.find_processed({context.url <> path, opts.scope})
    end

    for path <- ["/off.css", "/blank.css", "/dim.css"] do
      refute Store.find({context.url <> path, opts.scope})
    end

    target = assert_points(saved, page, context.url <> "/on.css", root)
    assert read_resource(root, target) == "body{}"
    assert saved =~ ~s|href="/off.css"|
    assert saved =~ ~s|href="/blank.css"|
    assert saved =~ ~s|href="/dim.css"|
  end

  test "the first manifest is fetched and its urls are saved", context do
    page = context.url <> "/manifest-page"
    manifest = context.url <> "/blog/app.webmanifest"

    expect_html(context, "/manifest-page", manifest_document(context), [
      {"link", ~s|</header.webmanifest>; rel="manifest"|}
    ])

    expect_bytes(context, "/blog/app.webmanifest", "application/manifest+json", manifest_json())
    expect_html(context, "/blog/home", "home")
    expect_html(context, "/new", "new")
    expect_bytes(context, "/blog/icon.png", "image/png", "png")
    expect_bytes(context, "/shot.png", "image/png", "png")
    expect_bytes(context, "/short.png", "image/png", "png")
    expect_foreign(context, "cdn.test", "/cdn.png", &png/1)

    {opts, root} = run(page, context, assets: ["images"])
    saved = read_resource(root, resource_for_url(root, page))
    manifest_body = read_resource(root, resource_for_url(root, manifest))

    for url <- [manifest, context.url <> "/blog/home", context.url <> "/new"] do
      assert Store.find_processed({url, opts.scope})
    end

    for url <- [
          context.url <> "/blog/icon.png",
          "https://cdn.test/cdn.png",
          context.url <> "/shot.png",
          context.url <> "/short.png"
        ] do
      assert Store.find_processed({url, opts.scope})
    end

    for url <- [
          context.url <> "/second.webmanifest",
          context.url <> "/templated.webmanifest",
          context.url <> "/header.webmanifest",
          context.url <> "/scoped/",
          "https://other.test/away"
        ] do
      refute Store.find({url, opts.scope})
    end

    assert_points(saved, page, manifest, root)
    assert saved =~ ~s|href="/second.webmanifest"|
    assert saved =~ ~s|href="/templated.webmanifest"|
    assert manifest_body =~ ~s|"name": "Demo"|
    assert_points(manifest_body, manifest, context.url <> "/blog/home", root)
    assert_points(manifest_body, manifest, context.url <> "/blog/icon.png", root)
    assert manifest_body =~ ~s|"scope": "/scoped/"|
  end

  test "a manifest is fetched without its images when images are off", context do
    page = context.url <> "/manifest-plain"
    manifest = context.url <> "/blog/app.webmanifest"

    expect_html(context, "/manifest-plain", manifest_document(context))
    expect_bytes(context, "/blog/app.webmanifest", "application/manifest+json", manifest_json())
    expect_html(context, "/blog/home", "home")
    expect_html(context, "/new", "new")

    {opts, _root} = run(page, context, assets: [])

    for url <- [manifest, context.url <> "/blog/home", context.url <> "/new"] do
      assert Store.find_processed({url, opts.scope})
    end

    for url <- [
          context.url <> "/blog/icon.png",
          "https://cdn.test/cdn.png",
          context.url <> "/shot.png",
          context.url <> "/short.png"
        ] do
      refute Store.find({url, opts.scope})
    end
  end

  test "speculation rules are read without javascript assets", context do
    page = context.url <> "/rules-page"
    rules = context.url <> "/rules/rules.json"
    ext = context.url <> "/rules/ext.json"

    expect_html(context, "/rules-page", rules_document(context), [
      {"speculation-rules", ~s|"/rules/rules.json"|}
    ])

    expect_bytes(context, "/rules/rules.json", "application/speculationrules+json", rules_json())
    expect_bytes(context, "/rules/ext.json", "application/speculationrules+json", ext_json())

    for path <- [
          "/blog/inline-next",
          "/blog/skip-ruleset",
          "/rules/ext-next",
          "/rules/file-next",
          "/blog/doc-next",
          "/secret"
        ] do
      expect_html(context, path, "page")
    end

    {opts, root} = run(page, context, assets: [])
    saved = read_resource(root, resource_for_url(root, page))
    rules_body = read_resource(root, resource_for_url(root, rules))
    ext_body = read_resource(root, resource_for_url(root, ext))

    for path <- [
          "/blog/inline-next",
          "/blog/skip-ruleset",
          "/rules/ext.json",
          "/rules/ext-next",
          "/rules/rules.json",
          "/rules/file-next",
          "/blog/doc-next",
          "/secret"
        ] do
      assert Store.find_processed({context.url <> path, opts.scope})
    end

    refute Store.find({"https://other.test/nope", opts.scope})

    for path <- ["/blog/skip-document", "/star"] do
      refute Store.find({context.url <> path, opts.scope})
    end

    assert_points(saved, page, context.url <> "/blog/inline-next", root)
    assert_points(saved, page, context.url <> "/blog/skip-ruleset", root)
    refute saved =~ ~s("skip-ruleset")
    assert_points(saved, page, ext, root)
    assert_points(rules_body, rules, context.url <> "/rules/file-next", root)
    assert_points(rules_body, rules, context.url <> "/blog/doc-next", root)
    assert_points(ext_body, ext, context.url <> "/rules/ext-next", root)
    assert rules_body =~ ~s|"eagerness": "eager"|
  end

  test "manifest and rules pages follow the same depth as links on the page", context do
    page = context.url <> "/depth"

    expect_html(context, "/depth", """
    <a href="/section">section</a>
    <link rel="manifest" href="/app.webmanifest">
    """)

    expect_bytes(
      context,
      "/app.webmanifest",
      "application/manifest+json",
      ~s|{"start_url":"/from-seed"}|
    )

    expect_html(context, "/section", """
    <a href="/sibling">sibling</a>
    <link rel="manifest" href="/section.webmanifest">
    <script type="speculationrules" src="/rules.json"></script>
    """)

    expect_bytes(
      context,
      "/section.webmanifest",
      "application/manifest+json",
      ~s|{"start_url":"/from-section"}|
    )

    expect_bytes(
      context,
      "/rules.json",
      "application/speculationrules+json",
      ~s|{"prefetch":[{"urls":["/from-rules"]}]}|
    )

    expect_html(context, "/from-section", ~s|<a href="/from-section-child">child</a>|)

    expect_html(context, "/sibling", """
    <a href="/too-deep">deep</a>
    <script type="speculationrules">{"prefetch":[{"urls":["/too-inline"]}]}</script>
    <link rel="manifest" href="/deep.webmanifest">
    """)

    expect_bytes(
      context,
      "/deep.webmanifest",
      "application/manifest+json",
      ~s|{"start_url":"/too-manifest"}|
    )

    for path <- ["/from-seed", "/from-rules"] do
      expect_html(context, path, "page")
    end

    {opts, _root} = run(page, context, max_depths: 3)

    for path <- [
          "/section",
          "/app.webmanifest",
          "/from-seed",
          "/sibling",
          "/section.webmanifest",
          "/from-section",
          "/rules.json",
          "/from-rules",
          "/deep.webmanifest"
        ] do
      assert Store.find_processed({context.url <> path, opts.scope})
    end

    for path <- ["/too-deep", "/too-inline", "/too-manifest", "/from-section-child"] do
      refute Store.find({context.url <> path, opts.scope})
    end
  end

  test "a shallow crawl still follows a manifest page from the entry page", context do
    page = context.url <> "/shallow"

    expect_html(context, "/shallow", """
    <a href="/plain">plain</a>
    <link rel="manifest" href="/app.webmanifest">
    """)

    expect_bytes(
      context,
      "/app.webmanifest",
      "application/manifest+json",
      ~s|{"start_url":"/home"}|
    )

    expect_html(context, "/plain", ~s|<a href="/plain-child">child</a>|)
    expect_html(context, "/home", "home")

    {opts, _root} = run(page, context, max_depths: 2)

    for path <- ["/plain", "/app.webmanifest", "/home"] do
      assert Store.find_processed({context.url <> path, opts.scope})
    end

    refute Store.find({context.url <> "/plain-child", opts.scope})
  end

  test "inert templates hide links and declarative shadow roots do not", context do
    page = context.url <> "/scope"

    html = """
    <template><link rel="prefetch" href="/hidden"></template>
    <template shadowrootmode="open"><link rel="prefetch" href="/inside"></template>
    <template shadowrootmode="closed"><link rel="prefetch" href="/closed-in"></template>
    <link rel="dns-prefetch" href="https://cdn.test/dns">
    <link rel="preconnect" href="https://cdn.test/connect">
    <link rel="canonical" href="/canon">
    <link rel="alternate" hreflang="de" href="/de">
    """

    expect_html(context, "/scope", html)
    expect_html(context, "/inside", "inside")
    expect_html(context, "/closed-in", "closed")

    {opts, root} = run(page, context)
    saved = read_resource(root, resource_for_url(root, page))

    assert Store.find_processed({context.url <> "/inside", opts.scope})
    assert Store.find_processed({context.url <> "/closed-in", opts.scope})

    for url <- [
          context.url <> "/hidden",
          context.url <> "/canon",
          context.url <> "/de",
          "https://cdn.test/dns",
          "https://cdn.test/connect"
        ] do
      refute Store.find({url, opts.scope})
    end

    target = assert_points(saved, page, context.url <> "/inside", root)
    assert read_resource(root, target) == <<0xEF, 0xBB, 0xBF>> <> "inside"
    assert saved =~ ~s|href="/hidden"|
    assert saved =~ ~s|href="/canon"|
    assert saved =~ ~s|href="https://cdn.test/dns"|
  end

  defp linked_resource(export, source, selector, attribute, expected_url) do
    assert [href] =
             export
             |> read_resource(source)
             |> Floki.parse_document!()
             |> Floki.attribute(selector, attribute)

    uri = URI.parse(href)
    path = Path.expand(URI.decode(uri.path), Path.dirname(artifact_path(export, source)))

    assert [target] =
             Enum.filter(
               export.manifest["resources"],
               &(Path.expand(&1["path"], export.root) == path)
             )

    assert target["url"] == expected_url

    assert Enum.any?(
             export.manifest["references"],
             &(&1["from"] == source["id"] and &1["target"] == target["id"] and
                 &1["outcome"] == "succeeded")
           )

    assert_opens(export, source, target, href)
  end

  defp preload_document do
    """
    <link rel="preload" as="fetch" href="/data.json">
    <link rel="preload" as="track" href="/a.vtt">
    <link rel="preload" as="track" type="text/vtt; charset=utf-8" href="/b.vtt">
    <link rel="preload" as="track" type="text/plain" href="/c.vtt">
    <link rel="preload" as="audio" href="/preload-audio.mp3">
    <link rel="preload" as=" fetch " href="/spaced.json">
    <track src="/from-track.vtt">
    """
  end

  defp manifest_document(context) do
    """
    <base href="#{context.url}/blog/">
    <template><link rel="manifest" href="/templated.webmanifest"></template>
    <template shadowrootmode="open"><link rel="manifest" href="app.webmanifest"></template>
    <link rel="manifest" href="/second.webmanifest">
    """
  end

  defp manifest_json do
    """
    {
      "name": "Demo",
      "scope": "/scoped/",
      "start_url": "home",
      "icons": [{"src": "icon.png"}, {"src": "https://cdn.test/cdn.png"}],
      "screenshots": [{"src": "/shot.png"}],
      "shortcuts": [
        {"url": "/new", "icons": [{"src": "/short.png"}]},
        {"url": "https://other.test/away"}
      ]
    }
    """
  end

  defp rules_document(context) do
    """
    <base href="#{context.url}/blog/">
    <script type="speculationrules">
    {
      "prefetch": [
        {"urls": ["inline-next", "https://other.test/nope"]},
        {"urls": ["skip-ruleset"], "relative_to": "ruleset"},
        {"source": "document", "urls": ["skip-document"]}
      ],
      "prerender": [{"where": {"href_matches": "/*"}, "eagerness": "eager"}]
    }
    </script>
    <script type="speculationrules" src="/rules/ext.json"></script>
    <a href="/secret">Secret</a>
    """
  end

  defp rules_json do
    """
    {
      "prefetch": [
        {
          "source": "list",
          "urls": ["file-next"],
          "eagerness": "eager",
          "requires": ["anonymous-client-ip-when-cross-origin"]
        },
        {"urls": ["doc-next"], "relative_to": "document"}
      ]
    }
    """
  end

  defp ext_json do
    """
    {"prefetch": [{"urls": ["ext-next"]}]}
    """
  end

  defp run(page, context, extra \\ []) do
    scope = extra[:scope] || unique_scope("declarative")
    parent_root = tmp(scope)
    root = Path.join(parent_root, "archive")
    on_exit(fn -> File.rm_rf(parent_root) end)

    {:ok, opts} =
      start_crawl(
        page,
        Keyword.merge(
          [
            scope: scope,
            workers: 1,
            max_body: 1_048_576,
            max_analysis_bytes: 16_777_216,
            max_manifest_bytes: 16_777_216,
            retries: 0,
            max_depths: 4,
            store: Store,
            save_to: root,
            req_options: context.req_options
          ],
          extra
        )
      )

    on_exit(fn -> Crawler.stop(opts) end)
    export = ready_root(opts)
    {opts, export}
  end

  defp ready_root(opts) do
    result = Store.await_direct(opts.target_handle, Crawler.Deadline.after_ms(5_000))

    assert {:terminal, %Crawler.Job.Outcome{status: :succeeded}, _} = result,
           "root canonical outcome: #{inspect(result)}"

    export = ready_export(opts)

    assert Enum.any?(export.manifest["resources"], &(&1["url"] == opts.url)),
           "ready export omitted its root; canonical outcome: #{inspect(result)}"

    export
  end

  defp expect_html(context, path, body, headers \\ []) do
    ReqTestSite.expect_once(context.site, "GET", path, &html(&1, body, headers))
  end

  defp expect_css(context, path) do
    expect_bytes(context, path, "text/css", "body{}")
  end

  defp expect_bytes(context, path, type, body) do
    ReqTestSite.expect_once(context.site, "GET", path, &typed(&1, type, body))
  end

  defp expect_foreign(context, host, path, fun) do
    key = {"GET", host, 443, path}

    Agent.update(context.site.agent, fn state ->
      put_in(state, [:routes, key], %{type: :once, fun: fun, count: 0})
    end)
  end

  defp html(conn, body, headers) do
    conn
    |> typed_headers("text/html", headers)
    |> resp(200, body)
  end

  defp typed(conn, type, body) do
    conn
    |> put_resp_header("content-type", type)
    |> resp(200, body)
  end

  defp typed_headers(conn, type, headers) do
    conn = put_resp_header(conn, "content-type", type)

    Enum.reduce(headers, conn, fn {name, value}, conn ->
      put_resp_header(conn, name, value)
    end)
  end

  defp png(conn) do
    conn
    |> put_resp_header("content-type", "image/png")
    |> resp(200, "png")
  end
end
