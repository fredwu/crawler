defmodule Crawler.CrawlScriptReferencesTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  @leaf "export {};"

  @mapped_module Enum.join(
                   [
                     ~s|import vue from "vue";|,
                     ~s|import "react";|,
                     ~s|import "lodash";|,
                     ~s|export { x } from "vue";|,
                     ~s|import "/js/lib.js";|,
                     ~s|import "./foo/../js/lib.js";|,
                     ~s|import "./app.js";|,
                     ~s|import("vue");|,
                     ~s|import "blocked";|,
                     ~s|import "gone";|,
                     ~s|import(name);|
                   ],
                   "\n"
                 )

  @classic Enum.join(
             [
               ~s|import("react");|,
               ~s|import "vue";|
             ],
             "\n"
           )

  @worker_js Enum.join(
               [
                 ~s|importScripts("./dep.js", name, "./other.js");|,
                 ~s|import("./lib/dyn.js");|,
                 ~s|import "./nope.js";|
               ],
               "\n"
             )

  @dyn_js Enum.join(
            [
              ~s|importScripts("./nested.js");|,
              ~s|new Worker("./win.js");|,
              ~s|new Worker(new URL("./meta.js", import.meta.url));|
            ],
            "\n"
          )

  @mod_worker_js Enum.join(
                   [
                     ~s|import "./inside.js";|,
                     ~s|import "vue";|,
                     ~s|new Worker("./from-entry.js");|
                   ],
                   "\n"
                 )

  setup do
    scope = unique_scope("script-files")
    root = tmp(scope, "archive")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, scope: scope, root: root}
  end

  test "an import map fetches mapped modules and leaves classic static imports", context do
    url = context.url
    page = url <> "/dir/page"
    react = context.url2 <> "/react.js"
    html = mapped_page(url, react)

    html(context.site, "/dir/page", html)
    leaf(context.site, "/assets/vue.js")
    leaf(context.site, "/assets/app.js")
    leaf(context.site, "/assets/js/lib.js")
    leaf(context.site, "/assets/vue")
    leaf(context.site, "/mapped.js")
    leaf(context.site2, "/react.js")

    export = crawl(page, context)

    vue = url <> "/assets/vue.js"
    app = url <> "/assets/app.js"
    lib = url <> "/assets/js/lib.js"
    bare = url <> "/assets/vue"
    mapped = url <> "/mapped.js"

    expected =
      html
      |> String.replace(~s|from "vue"|, ~s|from "#{offline(export, page, vue)}"|)
      |> String.replace(~s|import("vue")|, ~s|import("#{offline(export, page, vue)}")|,
        global: false
      )
      |> String.replace(~s|import "react"|, ~s|import "#{offline(export, page, react)}"|,
        global: false
      )
      |> String.replace(~s|import("react")|, ~s|import("#{offline(export, page, react)}")|,
        global: false
      )
      |> String.replace(~s|import "/js/lib.js"|, ~s|import "#{offline(export, page, mapped)}"|,
        global: false
      )
      |> String.replace(
        ~s|import "./foo/../js/lib.js"|,
        ~s|import "#{offline(export, page, lib)}"|,
        global: false
      )
      |> String.replace(~s|import "./app.js"|, ~s|import "#{offline(export, page, app)}"|,
        global: false
      )
      |> String.replace(~s|src="vue"|, ~s|src="#{offline(export, page, bare)}"|, global: false)
      |> String.replace(~s|<base href="#{url}/assets/">|, "<base>")

    assert read_resource(export, resource_for_url(export, page)) ==
             <<0xEF, 0xBB, 0xBF>> <> expected

    assert Store.find_processed({page, context.scope}).body == html

    assert_link_opens(
      export,
      resource_for_url(export, page),
      reference_target(export, resource_for_url(export, page), vue)
    )

    assert_link_opens(
      export,
      resource_for_url(export, page),
      reference_target(export, resource_for_url(export, page), app)
    )

    assert_link_opens(
      export,
      resource_for_url(export, page),
      reference_target(export, resource_for_url(export, page), bare)
    )

    assert_goal(context, vue, :module)
    assert_goal(context, app, :module)
    assert_goal(context, lib, :module)
    assert_goal(context, mapped, :module)
    assert_goal(context, react, :module)
    assert_goal(context, bare, :script)
    assert_raw(context, export, vue, @leaf)

    refute_stored(context, [
      url <> "/assets/unused.js",
      url <> "/empty.js",
      url <> "/assets/lodash",
      url <> "/lodash",
      url <> "/assets/gone",
      url <> "/not-dir"
    ])
  end

  test "a page with no import map does not fetch bare specifiers", context do
    url = context.url
    page = url <> "/plain.html"

    html(context.site, "/plain.html", """
    <script type="module">import "react"; import "lodash/get"; import "./ok.js";</script>
    <script>import "react"; import("./also.js");</script>
    """)

    leaf(context.site, "/ok.js")
    leaf(context.site, "/also.js")

    export = crawl(page, context)
    source = resource_for_url(export, page)
    assert_link_opens(export, source, reference_target(export, source, url <> "/ok.js"))
    assert_link_opens(export, source, reference_target(export, source, url <> "/also.js"))

    assert_goal(context, url <> "/ok.js", :module)
    assert_goal(context, url <> "/also.js", :module)

    refute_stored(context, [
      url <> "/react",
      url <> "/lodash/get",
      context.url2 <> "/react.js"
    ])
  end

  test "one absolute map key covers the same address spelled three ways", context do
    url = context.url
    page = url <> "/app.html"
    mapped = url <> "/mapped.js"

    html(context.site, "/app.html", """
    <script type="importmap">{"imports":{"/js/lib.js":"/mapped.js"}}</script>
    <script type="module">
    import "/js/lib.js";
    import "./js/lib.js";
    import "./foo/../js/lib.js";
    </script>
    """)

    leaf(context.site, "/mapped.js")
    export = crawl(page, context)

    href = offline(export, page, mapped)
    assert occurrences(read_resource(export, resource_for_url(export, page)), href) == 3

    assert_link_opens(
      export,
      resource_for_url(export, page),
      reference_target(export, resource_for_url(export, page), mapped)
    )

    assert_raw(context, export, mapped, @leaf)
    refute_stored(context, [url <> "/js/lib.js"])
  end

  test "the first import map wins and frames do not inherit it", context do
    url = context.url
    page = url <> "/page"
    a1 = url <> "/a1.js"
    b = url <> "/b.js"
    inner = url <> "/inner.js"
    vue = url <> "/doc-vue.js"

    html(context.site, "/page", """
    <script type="importmap">{"imports":{"a":"/a1.js","blocked":null,"vue":"/doc-vue.js"}}</script>
    <script type="module">import "a"; import("b");</script>
    <script type="importmap" src="/map.json"></script>
    <script type="importmap">{not json</script>
    <script type="importmap">{"imports":{"a":"/a2.js","b":"/b.js","blocked":"/blocked.js"}}</script>
    <template><script type="importmap">{"imports":{"t":"/t.js"}}</script><script type="module">import "t";</script></template>
    <iframe srcdoc='<script type="module">import "a";</script>'></iframe>
    <iframe srcdoc='<script type="importmap">{"imports":{"vue":"/inner.js"}}</script><script type="module">import "vue";</script>'></iframe>
    <script type="module">import "b"; import "a"; import "blocked"; import "vue";</script>
    <template shadowrootmode="open"><script type="importmap">{"imports":{"vue":"/shadow.js","only":"/only.js"}}</script><script type="module">import "vue"; import "only";</script></template>
    """)

    leaf(context.site, "/a1.js")
    leaf(context.site, "/b.js")
    leaf(context.site, "/inner.js")
    leaf(context.site, "/doc-vue.js")

    export = crawl(page, context)

    body = read_resource(export, resource_for_url(export, page))
    assert occurrences(body, ~s|import "a"|) == 1
    assert body =~ ~s|import("b")|
    assert body =~ ~s|import "blocked"|
    assert body =~ ~s|import "t"|
    assert body =~ ~s|import "only"|
    refute body =~ ~s|import "vue"|
    refute body =~ ~s|import "b"|

    assert_link_opens(
      export,
      resource_for_url(export, page),
      reference_target(export, resource_for_url(export, page), b)
    )

    assert_link_opens(
      export,
      resource_for_url(export, page),
      reference_target(export, resource_for_url(export, page), inner)
    )

    source = resource_for_url(export, page)

    for url <- [a1, vue] do
      edges =
        Enum.filter(
          export.manifest["references"],
          &(&1["from"] == source["id"] and &1["url"] == url)
        )

      assert length(edges) == 2
      targets = Enum.map(edges, &edge_target(export, source, &1["edge"]))
      hrefs = targets |> Enum.map(&relative_reference(source, &1)) |> Enum.uniq()
      assert Enum.sum(Enum.map(hrefs, &occurrences(body, &1))) == 2

      for target <- targets do
        assert_link_opens(export, source, target)
        assert read_resource(export, target) == @leaf
      end
    end

    assert_goal(context, a1, :module)
    assert_goal(context, inner, :module)

    refute_stored(context, [
      url <> "/a2.js",
      url <> "/blocked.js",
      url <> "/t.js",
      url <> "/map.json",
      url <> "/shadow.js",
      url <> "/only.js",
      url <> "/vue"
    ])
  end

  test "scopes follow the script URL and addresses use the document base", context do
    url = context.url
    page = url <> "/dir/page"
    main = url <> "/js/app/main.js"
    scoped = url <> "/js/other.js"
    exact = url <> "/js"
    top = url <> "/other.js"

    html(context.site, "/dir/page", """
    <base href="#{url}/assets/">
    <script type="importmap">{
      "imports": {
        "vue": "./vue.js",
        "react": "/react.js",
        "lib/": "/lib/",
        "lib/extra/": "/extra/",
        "lib/a.js": "/exact-a.js"
      },
      "scopes": {
        "/js": {"vue": "/exact-scope.js"},
        "/js/": {"vue": "./js-vue.js", "react": null},
        "/js/app/": {"vue": "/js/app/vue.js"}
      }
    }</script>
    <script type="module" src="/js/app/main.js"></script>
    <script type="module" src="/js/other.js"></script>
    <script type="module" src="/js"></script>
    <script type="module" src="/other.js"></script>
    """)

    js(context.site, "/js/app/main.js", ~s|import "vue";|)
    js(context.site, "/js/other.js", ~s|import "vue";\nimport "react";|)

    top_source =
      Enum.join(
        [
          ~s|import "vue";|,
          ~s|import "react";|,
          ~s|import "lib/a.js";|,
          ~s|import "lib/extra/b.js";|,
          ~s|import "lib/b.js";|,
          ~s|import "lib";|,
          ~s|import "lib/../secret.js";|
        ],
        "\n"
      )

    js(context.site, "/js", ~s|import "vue";|)
    js(context.site, "/other.js", top_source)
    leaf(context.site, "/js/app/vue.js")
    leaf(context.site, "/assets/js-vue.js")
    leaf(context.site, "/exact-scope.js")
    leaf(context.site, "/assets/vue.js")
    leaf(context.site, "/react.js")
    leaf(context.site, "/exact-a.js")
    leaf(context.site, "/extra/b.js")
    leaf(context.site, "/lib/b.js")

    export = crawl(page, context)

    assert read_js(export, main) ==
             ~s|import "#{offline(export, main, url <> "/js/app/vue.js")}";|

    assert read_js(export, scoped) ==
             ~s|import "#{offline(export, scoped, url <> "/assets/js-vue.js")}";\nimport "react";|

    assert read_js(export, exact) ==
             ~s|import "#{offline(export, exact, url <> "/exact-scope.js")}";|

    assert read_js(export, top) ==
             top_source
             |> String.replace(
               ~s|import "vue";|,
               ~s|import "#{offline(export, top, url <> "/assets/vue.js")}";|,
               global: false
             )
             |> String.replace(
               ~s|import "react";|,
               ~s|import "#{offline(export, top, url <> "/react.js")}";|,
               global: false
             )
             |> String.replace(
               ~s|import "lib/a.js";|,
               ~s|import "#{offline(export, top, url <> "/exact-a.js")}";|,
               global: false
             )
             |> String.replace(
               ~s|import "lib/extra/b.js";|,
               ~s|import "#{offline(export, top, url <> "/extra/b.js")}";|,
               global: false
             )
             |> String.replace(
               ~s|import "lib/b.js";|,
               ~s|import "#{offline(export, top, url <> "/lib/b.js")}";|,
               global: false
             )

    assert_goal(context, main, :module)
    assert_goal(context, scoped, :module)
    assert_goal(context, exact, :module)
    assert_goal(context, top, :module)

    assert_link_opens(
      export,
      resource_for_url(export, scoped),
      reference_target(export, resource_for_url(export, scoped), url <> "/assets/js-vue.js")
    )

    assert_link_opens(
      export,
      resource_for_url(export, top),
      reference_target(export, resource_for_url(export, top), url <> "/lib/b.js")
    )

    refute_stored(context, [
      url <> "/js/js-vue.js",
      url <> "/secret.js",
      url <> "/assets/secret.js",
      url <> "/lib",
      url <> "/assets/lib"
    ])
  end

  test "modules, workers, and import.meta.url keep separate bases", context do
    url = context.url
    page = url <> "/dir/page"
    script = url <> "/js/app.js?v=2"
    vue = url <> "/vue.js"
    relative_vue = url <> "/js/vue"
    inline_pic = url <> "/assets/pic.png"
    script_pic = url <> "/js/pic.png"
    up = url <> "/up.png"
    root = url <> "/root.png"
    cross = context.url2 <> "/x.png"
    worker = url <> "/assets/worker.js"
    shared = url <> "/assets/shared.js"
    sw = url <> "/sw.js"
    sw_module = url <> "/assets/sw-module.js"
    mod_worker = url <> "/js/mod-worker.js"
    dep = url <> "/assets/dep.js"
    other = url <> "/assets/other.js"
    dyn = url <> "/assets/lib/dyn.js"
    nested = url <> "/assets/nested.js"
    win = url <> "/assets/win.js"
    meta = url <> "/assets/lib/meta.js"
    inside = url <> "/js/inside.js"
    from_entry = url <> "/js/from-entry.js"
    inline = Enum.join([~s|import "vue";|, ~s|new URL("./pic.png", import.meta.url);|], "\n")
    source = app_source(context.url2)

    html =
      Enum.join(
        [
          ~s|<base href="#{url}/assets/">|,
          ~s|<script type="importmap">{"imports":{"vue":"/vue.js"}}</script>|,
          ~s|<script type="module">#{inline}</script>|,
          ~s|<script type="module" src="/js/app.js?v=2"></script>|
        ],
        "\n"
      )

    html(context.site, "/dir/page", html)
    js(context.site, "/js/app.js", source)
    js(context.site, "/assets/worker.js", @worker_js)
    js(context.site, "/assets/lib/dyn.js", @dyn_js)
    js(context.site, "/js/mod-worker.js", @mod_worker_js)
    leaf(context.site, "/vue.js")
    leaf(context.site, "/js/vue")
    leaf(context.site, "/assets/shared.js")
    leaf(context.site, "/sw.js")
    leaf(context.site, "/assets/sw-module.js")
    leaf(context.site, "/assets/dep.js")
    leaf(context.site, "/assets/other.js")
    leaf(context.site, "/assets/nested.js")
    leaf(context.site, "/assets/win.js")
    leaf(context.site, "/assets/lib/meta.js")
    leaf(context.site, "/js/inside.js")
    leaf(context.site, "/js/from-entry.js")
    png(context.site, "/assets/pic.png", "inline-pic")
    png(context.site, "/js/pic.png", "script-pic")
    png(context.site, "/up.png", "up")
    png(context.site, "/root.png", "root")
    png(context.site2, "/x.png", "x")

    export = crawl(page, context)

    assert read_resource(export, resource_for_url(export, page)) ==
             <<0xEF, 0xBB, 0xBF>> <>
               (html
                |> String.replace(~s|import "vue"|, ~s|import "#{offline(export, page, vue)}"|,
                  global: false
                )
                |> String.replace(
                  ~s|new URL("./pic.png"|,
                  ~s|new URL("#{offline(export, page, inline_pic)}"|,
                  global: false
                )
                |> String.replace(
                  ~s|src="/js/app.js?v=2"|,
                  ~s|src="#{offline(export, page, script)}"|,
                  global: false
                )
                |> String.replace(~s|<base href="#{url}/assets/">|, "<base>"))

    assert read_js(export, script) ==
             source
             |> String.replace(~s|import "vue";|, ~s|import "#{offline(export, script, vue)}";|,
               global: false
             )
             |> String.replace(
               ~s|new URL("./pic.png"|,
               ~s|new URL("#{offline(export, script, script_pic)}"|,
               global: false
             )
             |> String.replace(
               ~s|new URL("../up.png"|,
               ~s|new URL("#{offline(export, script, up)}"|,
               global: false
             )
             |> String.replace(
               ~s|new URL("/root.png"|,
               ~s|new URL("#{offline(export, script, root)}"|,
               global: false
             )
             |> String.replace(
               ~s|new URL("#{cross}"|,
               ~s|new URL("#{offline(export, script, cross)}"|,
               global: false
             )
             |> String.replace(
               ~s|new URL("vue"|,
               ~s|new URL("#{offline(export, script, relative_vue)}"|,
               global: false
             )
             |> String.replace(
               ~s|new Worker("./worker.js"|,
               ~s|new Worker("#{offline(export, script, worker)}"|,
               global: false
             )
             |> String.replace(
               ~s|new SharedWorker("./shared.js"|,
               ~s|new SharedWorker("#{offline(export, script, shared)}"|,
               global: false
             )
             |> String.replace(
               ~s|register("/sw.js"|,
               ~s|register("#{offline(export, script, sw)}"|,
               global: false
             )
             |> String.replace(
               ~s|register("./sw-module.js"|,
               ~s|register("#{offline(export, script, sw_module)}"|,
               global: false
             )
             |> String.replace(
               ~s|new URL("./mod-worker.js"|,
               ~s|new URL("#{offline(export, script, mod_worker)}"|,
               global: false
             )

    assert read_js(export, worker) ==
             @worker_js
             |> String.replace(~s|"./dep.js"|, ~s|"#{offline(export, worker, dep)}"|,
               global: false
             )
             |> String.replace(~s|"./other.js"|, ~s|"#{offline(export, worker, other)}"|,
               global: false
             )
             |> String.replace(~s|"./lib/dyn.js"|, ~s|"#{offline(export, worker, dyn)}"|,
               global: false
             )

    assert read_js(export, dyn) ==
             @dyn_js
             |> String.replace(~s|"./nested.js"|, ~s|"#{offline(export, dyn, nested)}"|,
               global: false
             )
             |> String.replace(~s|"./win.js"|, ~s|"#{offline(export, dyn, win)}"|, global: false)
             |> String.replace(~s|"./meta.js"|, ~s|"#{offline(export, dyn, meta)}"|,
               global: false
             )

    assert read_js(export, mod_worker) ==
             @mod_worker_js
             |> String.replace(~s|"./inside.js"|, ~s|"#{offline(export, mod_worker, inside)}"|,
               global: false
             )
             |> String.replace(
               ~s|"./from-entry.js"|,
               ~s|"#{offline(export, mod_worker, from_entry)}"|,
               global: false
             )

    assert_link_opens(
      export,
      resource_for_url(export, page),
      reference_target(export, resource_for_url(export, page), vue)
    )

    assert_link_opens(
      export,
      resource_for_url(export, page),
      reference_target(export, resource_for_url(export, page), inline_pic)
    )

    assert_link_opens(
      export,
      resource_for_url(export, script),
      reference_target(export, resource_for_url(export, script), script_pic)
    )

    assert_link_opens(
      export,
      resource_for_url(export, script),
      reference_target(export, resource_for_url(export, script), worker)
    )

    assert_link_opens(
      export,
      resource_for_url(export, script),
      reference_target(export, resource_for_url(export, script), relative_vue)
    )

    assert_link_opens(
      export,
      resource_for_url(export, worker),
      reference_target(export, resource_for_url(export, worker), dep)
    )

    assert_link_opens(
      export,
      resource_for_url(export, dyn),
      reference_target(export, resource_for_url(export, dyn), nested)
    )

    assert_link_opens(
      export,
      resource_for_url(export, dyn),
      reference_target(export, resource_for_url(export, dyn), win)
    )

    assert_link_opens(
      export,
      resource_for_url(export, dyn),
      reference_target(export, resource_for_url(export, dyn), meta)
    )

    assert_link_opens(
      export,
      resource_for_url(export, mod_worker),
      reference_target(export, resource_for_url(export, mod_worker), inside)
    )

    assert_link_opens(
      export,
      resource_for_url(export, mod_worker),
      reference_target(export, resource_for_url(export, mod_worker), from_entry)
    )

    assert_raw(context, export, inline_pic, "inline-pic")
    assert_raw(context, export, script_pic, "script-pic")
    assert_raw(context, export, cross, "x")
    assert_goal(context, script, :module)
    assert_goal(context, worker, :script)
    assert_goal(context, shared, :script)
    assert_goal(context, sw, :script)
    assert_goal(context, sw_module, :module)
    assert_goal(context, mod_worker, :module)
    assert_goal(context, dep, :script)
    assert_goal(context, dyn, :module)
    assert_goal(context, nested, :script)
    assert_goal(context, win, :script)
    assert_goal(context, meta, :script)
    assert_goal(context, inside, :module)
    assert_goal(context, from_entry, :script)

    refute_stored(context, [
      url <> "/js/skip.png",
      url <> "/js/nope.png",
      url <> "/assets/skip.js",
      url <> "/js/skip.js",
      url <> "/assets/page-dep.js",
      url <> "/js/page-dep.js",
      url <> "/app/",
      url <> "/app",
      url <> "/assets/nope.js",
      url <> "/assets/lib/nested.js",
      url <> "/assets/from-entry.js",
      url <> "/js/worker.js"
    ])
  end

  test "an external module keeps the map reached when its tag was seen", context do
    url = context.url
    page = url <> "/order.html"
    early = url <> "/early.js"
    before = url <> "/preload-before.js"
    late = url <> "/late.js"
    after_preload = url <> "/preload-after.js"
    classic = url <> "/preload-classic.js"
    after_js = url <> "/after.js"
    added = url <> "/added.js"
    nested = url <> "/nested.js"
    fresh = url <> "/fresh.js"

    html(context.site, "/order.html", """
    <script type="module" src="/early.js"></script>
    <link rel="modulepreload" href="/preload-before.js">
    <script type="importmap">{"imports":{"added":"/added.js","nested":"/nested.js"}}</script>
    <script type="module" src="/late.js"></script>
    <link rel="modulepreload" href="/preload-after.js">
    <link rel="preload" as="script" href="/preload-classic.js">
    <script type="importmap">{"imports":{"added":"/replaced.js","fresh":"/fresh.js"}}</script>
    <script type="module" src="/after.js"></script>
    """)

    js(context.site, "/early.js", ~s|import "added";|)
    js(context.site, "/preload-before.js", ~s|import "added";|)
    js(context.site, "/late.js", ~s|import "added";|)
    js(context.site, "/preload-after.js", ~s|import "added";|)
    js(context.site, "/preload-classic.js", ~s|import("added");\nimport "stays";|)
    js(context.site, "/after.js", ~s|import "added";\nimport "fresh";|)
    js(context.site, "/added.js", ~s|import "nested";|)
    leaf(context.site, "/nested.js")
    leaf(context.site, "/fresh.js")

    export = crawl(page, context)

    assert read_js(export, early) == ~s|import "added";|
    assert read_js(export, before) == ~s|import "added";|
    assert read_js(export, late) == ~s|import "#{offline(export, late, added)}";|

    assert read_js(export, after_preload) ==
             ~s|import "#{offline(export, after_preload, added)}";|

    assert read_js(export, classic) ==
             ~s|import("#{offline(export, classic, added)}");\nimport "stays";|

    assert read_js(export, after_js) ==
             ~s|import "#{offline(export, after_js, added)}";\nimport "#{offline(export, after_js, fresh)}";|

    added_resource = reference_target(export, resource_for_url(export, late), added)
    nested_resource = reference_target(export, added_resource, nested)

    assert read_resource(export, added_resource) ==
             ~s|import "#{relative_reference(added_resource, nested_resource)}";|

    assert_goal(context, early, :module)
    assert_goal(context, before, :module)
    assert_goal(context, late, :module)
    assert_goal(context, after_preload, :module)
    assert_goal(context, classic, :script)
    assert_goal(context, added, :module)
    assert_goal(context, nested, :module)
    assert_goal(context, fresh, :module)

    assert_link_opens(
      export,
      resource_for_url(export, page),
      reference_target(export, resource_for_url(export, page), early)
    )

    assert_link_opens(
      export,
      resource_for_url(export, page),
      reference_target(export, resource_for_url(export, page), late)
    )

    assert_link_opens(
      export,
      resource_for_url(export, late),
      reference_target(export, resource_for_url(export, late), added)
    )

    assert_link_opens(
      export,
      added_resource,
      nested_resource
    )

    assert_link_opens(
      export,
      resource_for_url(export, after_js),
      reference_target(export, resource_for_url(export, after_js), fresh)
    )

    refute_stored(context, [url <> "/replaced.js", url <> "/stays"])
  end

  test "a redirected worker uses the landed url for importScripts and nested workers", context do
    url = context.url
    page = url <> "/worker-redirect/page"
    requested = url <> "/worker-redirect/worker.js"
    landed = url <> "/cdn/worker.js"
    dep = url <> "/cdn/lib/dep.js"
    more = url <> "/cdn/more.js"
    next = url <> "/cdn/next.js"

    html(context.site, "/worker-redirect/page", ~s|<script>new Worker("./worker.js");</script>|)

    redirect(context.site, "/worker-redirect/worker.js", landed)

    js(context.site, "/cdn/worker.js", """
    importScripts("./lib/dep.js");
    new Worker("./next.js");
    """)

    js(context.site, "/cdn/lib/dep.js", ~s|importScripts("./more.js");|)
    leaf(context.site, "/cdn/more.js")
    leaf(context.site, "/cdn/next.js")

    export = crawl(page, context)
    worker_resource = reference_target(export, resource_for_url(export, page), requested)

    assert_link_opens(
      export,
      resource_for_url(export, page),
      reference_target(export, resource_for_url(export, page), requested)
    )

    assert_link_opens(export, worker_resource, reference_target(export, worker_resource, dep))
    assert_link_opens(export, worker_resource, reference_target(export, worker_resource, next))

    assert_link_opens(
      export,
      resource_for_url(export, dep),
      reference_target(export, resource_for_url(export, dep), more)
    )

    assert Store.find_processed({requested, context.scope}).opts.worker_base == landed
    assert Store.find_processed({requested, context.scope}).opts.referrer_url == landed
    assert Store.find_processed({dep, context.scope}).opts.worker_base == landed
    assert_goal(context, requested, :script)
    assert_goal(context, dep, :script)
    assert_goal(context, more, :script)
    assert_goal(context, next, :script)

    refute_stored(context, [
      url <> "/worker-redirect/lib/dep.js",
      url <> "/worker-redirect/next.js",
      url <> "/worker-redirect/more.js",
      url <> "/cdn/lib/more.js"
    ])
  end

  test "script files are left alone unless assets contains js", context do
    url = context.url
    page = url <> "/quiet.html"

    html(context.site, "/quiet.html", """
    <script type="module" src="/kept.js"></script>
    <script type="module">import "./inline.js";</script>
    """)

    export = crawl(page, context, assets: ["css"])

    refute Enum.any?(
             export.manifest["resources"],
             &(&1["url"] in [url <> "/kept.js", url <> "/inline.js"])
           )

    refute_stored(context, [url <> "/kept.js", url <> "/inline.js"])
  end

  defp mapped_page(url, react) do
    map =
      ~s|{"integrity":{"vue":"sha256-abc"},"imports":{"vue":"./vue.js","react":"#{react}","/js/lib.js":"/mapped.js","blocked":null,"gone":"data:text/javascript,1","":"/empty.js","bad":1,"unused":"./unused.js","pre/":"/not-dir"}}|

    Enum.join(
      [
        ~s|<base href="#{url}/assets/">|,
        ~s|<script type="importmap">#{map}</script>|,
        ~s|<script type="module">#{@mapped_module}</script>|,
        ~s|<script>#{@classic}</script>|,
        ~s|<script src="vue"></script>|
      ],
      "\n"
    )
  end

  defp app_source(origin) do
    Enum.join(
      [
        ~s|import "vue";|,
        ~s|new URL("./pic.png", import.meta.url);|,
        ~s|new URL("../up.png", import.meta.url);|,
        ~s|new URL("/root.png", import.meta.url);|,
        ~s|new URL("#{origin}/x.png", import.meta.url);|,
        ~s|new URL("vue", import.meta.url);|,
        ~s|new URL("data:text/plain,hi", import.meta.url);|,
        ~s|import.meta.url;|,
        ~s|import.meta.resolve("./nope.png");|,
        ~s|fetch("./nope.png");|,
        ~s|const skip = 'new URL("./skip.png", import.meta.url)';|,
        ~s|new URL(name, import.meta.url);|,
        ~s|new Worker("./worker.js");|,
        ~s|new SharedWorker("./shared.js");|,
        ~s|navigator.serviceWorker.register("/sw.js", {scope:"/app/"});|,
        ~s|navigator.serviceWorker.register("./sw-module.js", {type:"module"});|,
        ~s|new Worker(new URL("./mod-worker.js", import.meta.url), {type:"module"});|,
        ~s|const skipWorker = 'new Worker("./skip.js")';|,
        ~s|new Worker("data:text/javascript,1");|,
        ~s|importScripts("./page-dep.js");|
      ],
      "\n"
    )
  end

  defp crawl(url, context, extra \\ []) do
    {:ok, opts} =
      start_crawl(
        url,
        Keyword.merge(
          [
            scope: context.scope,
            workers: 1,
            max_body: 1_048_576,
            max_analysis_bytes: 16_000_000,
            max_manifest_bytes: 16 * 1024 * 1024,
            max_depths: 4,
            retries: 0,
            assets: ["js"],
            store: Store,
            save_to: context.root,
            req_options: context.req_options
          ],
          extra
        )
      )

    ready_export(opts)
  end

  defp html(site, path, body), do: respond(site, path, "text/html", body)
  defp js(site, path, body), do: respond(site, path, "application/javascript", body)
  defp png(site, path, body), do: respond(site, path, "image/png", body)
  defp leaf(site, path), do: js(site, path, @leaf)

  defp respond(site, path, type, body) do
    ReqTestSite.expect_once(site, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", type)
      |> Plug.Conn.resp(200, body)
    end)
  end

  defp redirect(site, path, location) do
    ReqTestSite.expect_once(site, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", location)
      |> Plug.Conn.resp(302, "")
    end)
  end

  defp offline(export, from, to) do
    source = resource_for_url(export, from)
    relative_reference(source, reference_target(export, source, to))
  end

  defp read_js(export, url) do
    body = read_resource(export, resource_for_url(export, url))
    refute String.starts_with?(body, <<0xEF, 0xBB, 0xBF>>)
    body
  end

  defp assert_raw(context, export, url, body) do
    assert Store.find_processed({url, context.scope}).body == body
    assert read_resource(export, resource_for_url(export, url)) == body
  end

  defp assert_goal(context, url, goal) do
    assert Store.find_processed({url, context.scope}).opts.javascript_goal == goal
  end

  defp refute_stored(context, urls) do
    Enum.each(urls, fn url ->
      refute Store.find({url, context.scope})
    end)
  end

  defp occurrences(body, text) do
    body |> String.split(text) |> length() |> Kernel.-(1)
  end
end
