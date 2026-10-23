defmodule Crawler.Parser.ScriptReferencesTest do
  use ExUnit.Case, async: true

  alias Crawler.ImportMap
  alias Crawler.Parser
  alias Crawler.Snapper.LinkReplacer

  @page "http://example.com/dir/page"
  @base "http://example.com/assets/"
  @script "http://example.com/js/app.js?v=2"

  test "an inline module uses only the map reached so far" do
    source = """
    <script type="module" src="early.js"></script>
    <link rel="modulepreload" href="preload-early.js">
    <script type=" ImportMap ">{"imports":{"a":"/a1.js","blocked":null}}</script>
    <script type="module">import "a"; import("b"); import "blocked"; import "lodash";</script>
    <script type="importmap">{"imports":{"a":"/a2.js","b":"/b.js","blocked":"/blocked.js"}}</script>
    <script type="module" src="late.js"></script>
    <link rel="preload" as="script" href="preload-late.js">
    <template><script type="importmap">{"imports":{"t":"/t.js"}}</script></template>
    <script type="importmap" src="/map.json">{"imports":{"s":"/s.js"}}</script>
    <script type="importmap">{not json</script>
    <script type="module">import "b"; import "a"; import "blocked"; import "t";</script>
    <a href="next">N</a>
    """

    refs = html_refs(source)
    assert urls(refs, "a") == ["http://example.com/a1.js", "http://example.com/a1.js"]
    assert urls(refs, "b") == ["http://example.com/b.js"]
    assert urls(refs, "blocked") == []
    assert urls(refs, "lodash") == []
    assert urls(refs, "t") == []
    refute Enum.any?(refs, &(&1.url == "http://example.com/map.json"))
    refute Enum.any?(refs, &(&1.url == "http://example.com/a2.js"))

    early = find_spec(refs, "early.js")
    late = find_spec(refs, "late.js")
    assert resolve_carried(early, "a") == :unmapped
    assert resolve_carried(late, "a") == {:ok, "http://example.com/a1.js"}
    assert resolve_carried(late, "b") == {:ok, "http://example.com/b.js"}
    assert resolve_carried(find_spec(refs, "preload-early.js"), "a") == :unmapped

    assert resolve_carried(find_spec(refs, "preload-late.js"), "b") ==
             {:ok, "http://example.com/b.js"}

    assert find_spec(refs, "next").import_map == nil
    assert find_spec(refs, "next").document_base == nil
    assert find_spec(refs, "next").goal == nil
  end

  test "a frame keeps its own map and a shadow map stays out of the document" do
    source = """
    <base href="#{@base}">
    <script type="importmap">{"imports":{"vue":"./vue.js"}}</script>
    <iframe srcdoc='<script type="module">import "vue";</script>'></iframe>
    <iframe srcdoc='<script type="importmap">{"imports":{"vue":"/inner.js"}}</script><script type="module">import "vue";</script>'></iframe>
    <template shadowrootmode="open">
      <script type="importmap">{"imports":{"vue":"/shadow.js","only":"/only.js"}}</script>
      <script type="module">import "vue"; import "only";</script>
    </template>
    <script type="module">import "vue";</script>
    """

    refs = html_refs(source)

    assert urls(refs, "vue") == [
             "http://example.com/inner.js",
             "http://example.com/assets/vue.js",
             "http://example.com/assets/vue.js"
           ]

    assert "http://example.com/shadow.js" not in Enum.map(refs, & &1.url)
    assert "http://example.com/only.js" not in Enum.map(refs, & &1.url)

    assert {:ok, body} = rewrite(source)
    assert body =~ ~s|import "vue"|
    assert body =~ ~s|import "only"|
    assert body =~ "http://example.com/inner.js"
    assert body =~ "http://example.com/assets/vue.js"
    refute body =~ "http://example.com/shadow.js"
    refute body =~ "http://example.com/only.js"
  end

  test "the same absolute address shares one map key" do
    source = """
    <script type="importmap">{"imports":{"/js/lib.js":"/mapped.js"}}</script>
    <script type="module">
    import "/js/lib.js";
    import "./js/lib.js";
    import "./foo/../js/lib.js";
    </script>
    """

    refs =
      html_refs(source, %{
        url: "http://example.com/app.html",
        referrer_url: "http://example.com/app.html"
      })

    assert urls(refs, "/js/lib.js") == ["http://example.com/mapped.js"]
    assert urls(refs, "./js/lib.js") == ["http://example.com/mapped.js"]
    assert urls(refs, "./foo/../js/lib.js") == ["http://example.com/mapped.js"]
  end

  test "a rebased relative specifier stays outside a root map key" do
    source = """
    <base href="#{@base}">
    <script type="importmap">{"imports":{"/js/lib.js":"/mapped.js","vue":"./vue.js"}}</script>
    <script type="module">
    import "/js/lib.js";
    import "./foo/../js/lib.js";
    import "vue";
    </script>
    <script src="vue"></script>
    <script>import "vue"; import("vue");</script>
    """

    refs = html_refs(source)
    assert urls(refs, "/js/lib.js") == ["http://example.com/mapped.js"]
    assert urls(refs, "./foo/../js/lib.js") == ["http://example.com/assets/js/lib.js"]

    assert urls(refs, "vue") == [
             "http://example.com/assets/vue.js",
             "http://example.com/assets/vue",
             "http://example.com/assets/vue.js"
           ]
  end

  test "new URL and workers use the script or document base and skip the page map inside a worker" do
    map = ImportMap.parse(~s|{"imports":{"vue":"/vue.js"}}|, @base)

    refs =
      js_refs(
        """
        new URL("./pic.png", import.meta.url);
        new URL("../up.png", import.meta.url);
        new URL("/root.png", import.meta.url);
        new URL("vue", import.meta.url);
        new URL("data:text/plain,hi", import.meta.url);
        new URL(name, import.meta.url);
        import.meta.url;
        import.meta.resolve("./nope.png");
        fetch("./nope.png");
        const skip = 'new URL("./skip.png", import.meta.url)';
        new Worker("./worker.js");
        new SharedWorker("./shared.js");
        navigator.serviceWorker.register("/sw.js", {scope:"/app/"});
        navigator.serviceWorker.register("./sw-module.js", {type:"module"});
        new Worker(new URL("./mod-worker.js", import.meta.url), {type:"module"});
        new Worker("./last.js", {type:"module", type:"classic"});
        new Worker("./mod.js", {type:"classic", type:"module"});
        new Worker("./scope.js", {scope:"/module/"});
        new Worker("data:text/javascript,1");
        const skipWorker = 'new Worker("./skip.js")';
        importScripts("./page-dep.js");
        import "vue";
        """,
        %{import_map: map, document_base: @base}
      )

    assert find_spec(refs, "./pic.png").url == "http://example.com/js/pic.png"
    assert find_spec(refs, "../up.png").url == "http://example.com/up.png"
    assert find_spec(refs, "/root.png").url == "http://example.com/root.png"
    relative_vue = Enum.find(refs, &(&1.spec == "vue" and &1.goal == nil))
    assert relative_vue.url == "http://example.com/js/vue"
    assert relative_vue.html_tag == "link"
    mapped = Enum.find(refs, &(&1.spec == "vue" and &1.goal == :module))
    assert mapped.url == "http://example.com/vue.js"
    assert find_spec(refs, "./worker.js").url == "http://example.com/assets/worker.js"
    assert find_spec(refs, "./worker.js").goal == :script
    assert find_spec(refs, "./worker.js").worker_base == "http://example.com/assets/worker.js"
    assert find_spec(refs, "./worker.js").import_map == nil
    assert find_spec(refs, "./shared.js").url == "http://example.com/assets/shared.js"
    assert find_spec(refs, "/sw.js").url == "http://example.com/sw.js"
    assert find_spec(refs, "/sw.js").goal == :script
    assert find_spec(refs, "./sw-module.js").goal == :module
    assert find_spec(refs, "./sw-module.js").url == "http://example.com/assets/sw-module.js"
    assert find_spec(refs, "./mod-worker.js").url == "http://example.com/js/mod-worker.js"
    assert find_spec(refs, "./mod-worker.js").goal == :module
    assert find_spec(refs, "./last.js").goal == :script
    assert find_spec(refs, "./mod.js").goal == :module
    assert find_spec(refs, "./scope.js").goal == :script

    refute Enum.any?(
             refs,
             &(&1.spec in [
                 "data:text/plain,hi",
                 "data:text/javascript,1",
                 "./skip.png",
                 "./nope.png",
                 "./skip.js",
                 "./page-dep.js",
                 "/app/"
               ])
           )

    classic =
      js_refs(
        ~s|new URL("./pic.png", import.meta.url); import("./real.js"); import "./nope.js";|,
        %{javascript_goal: :script, document_base: @base}
      )

    assert Enum.map(classic, & &1.spec) == ["./real.js"]
  end

  test "importScripts and nested workers use the worker entry base" do
    entry = "http://example.com/assets/worker.js"

    classic =
      js_refs(
        ~s|importScripts("./dep.js", name, "./other.js"); import("./lib/dyn.js"); import "./nope.js";|,
        %{javascript_goal: :script, worker_base: entry, url: entry, referrer_url: entry}
      )

    assert Enum.map(classic, &{&1.spec, &1.url, &1.goal, &1.worker_base}) == [
             {"./dep.js", "http://example.com/assets/dep.js", :script, entry},
             {"./other.js", "http://example.com/assets/other.js", :script, entry},
             {"./lib/dyn.js", "http://example.com/assets/lib/dyn.js", :module, entry}
           ]

    nested_url = "http://example.com/assets/lib/dyn.js"

    nested =
      js_refs(
        ~s|importScripts("./nested.js"); new Worker("./win.js"); new Worker(new URL("./meta.js", import.meta.url));|,
        %{
          javascript_goal: :module,
          worker_base: entry,
          url: nested_url,
          referrer_url: nested_url,
          import_map: ImportMap.parse(~s|{"imports":{"vue":"/vue.js"}}|, @base)
        }
      )

    assert find_spec(nested, "./nested.js").url == "http://example.com/assets/nested.js"
    assert find_spec(nested, "./win.js").url == "http://example.com/assets/win.js"
    assert find_spec(nested, "./meta.js").url == "http://example.com/assets/lib/meta.js"

    mod = "http://example.com/js/mod-worker.js"

    worker =
      js_refs(~s|import "./inside.js"; import "vue";|, %{
        javascript_goal: :module,
        worker_base: mod,
        url: mod,
        referrer_url: mod,
        import_map: ImportMap.parse(~s|{"imports":{"vue":"/vue.js"}}|, @base)
      })

    assert Enum.map(worker, & &1.spec) == ["./inside.js"]
    assert hd(worker).url == "http://example.com/js/inside.js"
  end

  test "a joined string is not a worker or importScripts address" do
    refs =
      js_refs(
        """
        new Worker("./worker" + ".js");
        new Worker("./real.js" /* ) */ + ".js");
        new Worker("./real.js");
        navigator.serviceWorker.register("./sw" + ".js");
        navigator.serviceWorker.register("./sw.js", {"type":"module"});
        new Worker("./mod.js", {type:"module", extra:{type:"classic"}});
        new Worker("./classic.js", {name: label({type:"module"})});
        new Worker("./later.js", {extra:{type:"module"}, type:"classic"});
        """,
        %{document_base: @base}
      )

    assert Enum.sort(Enum.map(refs, & &1.spec)) == [
             "./classic.js",
             "./later.js",
             "./mod.js",
             "./real.js",
             "./sw.js"
           ]

    assert Enum.count(refs, &(&1.spec == "./real.js")) == 1
    assert find_spec(refs, "./real.js").goal == :script
    assert find_spec(refs, "./sw.js").goal == :module
    assert find_spec(refs, "./mod.js").goal == :module
    assert find_spec(refs, "./classic.js").goal == :script
    assert find_spec(refs, "./later.js").goal == :script

    entry = "http://example.com/assets/worker.js"

    scripts =
      js_refs(~s|importScripts("./dep" + ".js", "./other.js");|, %{
        javascript_goal: :script,
        worker_base: entry,
        url: entry,
        referrer_url: entry
      })

    assert Enum.map(scripts, & &1.spec) == ["./other.js"]
    assert hd(scripts).url == "http://example.com/assets/other.js"
  end

  test "a quote inside a literal stays part of the worker or new URL address" do
    refs =
      js_refs(
        ~S"""
        new Worker("./worker's.js");
        new Worker("./worker's.js" + ".js");
        new URL("./a\"b.png", import.meta.url);
        navigator.serviceWorker.register('./o"reilly.js');
        new SharedWorker("./shared's.js");
        """,
        %{document_base: @base}
      )

    assert Enum.sort(Enum.map(refs, & &1.spec)) == [
             "./a\"b.png",
             "./o\"reilly.js",
             "./shared's.js",
             "./worker's.js"
           ]

    assert Enum.count(refs, &(&1.spec == "./worker's.js")) == 1

    for spec <- ["./worker's.js", "./shared's.js", "./o\"reilly.js"] do
      assert {:ok, url} = Crawler.URL.resolve(spec, @base)
      assert find_spec(refs, spec).url == url
    end

    assert {:ok, picture} = Crawler.URL.resolve("./a\"b.png", @script)
    assert find_spec(refs, "./a\"b.png").url == picture
  end

  test "a worker type or new URL argument must be one whole literal" do
    refs =
      js_refs(
        """
        new Worker("./prefix.js", {type: "module" + "no"});
        new Worker("./index.js", {type: "module"[0]});
        new Worker("./concat.js", {type: "mod" + "ule"});
        new Worker("./still.js", {type: "module"});
        new Worker(new URL("./joined.js", import.meta.url) + "/extra");
        new Worker(new URL("./whole.js", import.meta.url));
        new Worker(new URL("./typed.js", import.meta.url), {type:"module"});
        """,
        %{document_base: @base}
      )

    assert find_spec(refs, "./prefix.js").goal == :script
    assert find_spec(refs, "./index.js").goal == :script
    assert find_spec(refs, "./concat.js").goal == :script
    assert find_spec(refs, "./still.js").goal == :module
    assert find_spec(refs, "./whole.js").goal == :script
    assert find_spec(refs, "./whole.js").worker_base == "http://example.com/js/whole.js"
    assert find_spec(refs, "./typed.js").goal == :module
    assert find_spec(refs, "./typed.js").worker_base == "http://example.com/js/typed.js"

    joined = Enum.find(refs, &(&1.spec == "./joined.js"))
    assert joined.goal == nil
    assert joined.worker_base == nil
  end

  test "a non-ascii name is not a call, and scanner whitespace still separates one" do
    entry = "http://example.com/assets/worker.js"

    opts = %{
      worker_base: entry,
      url: entry,
      referrer_url: entry,
      document_base: @base
    }

    assert js_refs(~s|énavigator.serviceWorker.register("./sw.js");|, opts) == []
    assert js_refs(~s|éimportScripts("./dep.js", "./ok.js");|, opts) == []
    assert js_refs(~s|énew Worker("./worker.js");|, opts) == []
    assert js_refs(~s|énew URL("./pic.png", import.meta.url);|, opts) == []
    assert js_refs(~s|e\u0301new Worker("./worker.js");|, opts) == []
    assert js_refs(~s|mynew Worker("./no.js");|, opts) == []
    assert js_refs(~s|new Worker2("./no.js"); new URL2("./no.png", import.meta.url);|, opts) == []
    assert js_refs(~s|importScripts2("./no.js");|, opts) == []

    typed =
      js_refs(
        ~s|new Worker("./keep.js", {type:"module", étype:"classic"}); new Worker("./drop.js", {étype:"module"});|,
        opts
      )

    assert find_spec(typed, "./keep.js").goal == :module
    assert find_spec(typed, "./drop.js").goal == :script

    spaced =
      js_refs(
        """
        new\u00A0Worker("./nbsp.js");
        new\uFEFFWorker("./feff.js");
        new\u2028Worker("./line.js");
        navigator.serviceWorker.register\u00A0("./sw.js");
        new\u00A0URL("./pic.png",\u00A0import.meta.url);
        importScripts\u00A0("./dep.js");
        """,
        opts
      )

    assert find_spec(spaced, "./nbsp.js").url == "http://example.com/assets/nbsp.js"
    assert find_spec(spaced, "./feff.js").url == "http://example.com/assets/feff.js"
    assert find_spec(spaced, "./line.js").url == "http://example.com/assets/line.js"
    assert find_spec(spaced, "./sw.js").url == "http://example.com/assets/sw.js"
    assert find_spec(spaced, "./dep.js").url == "http://example.com/assets/dep.js"
    assert {:ok, picture} = Crawler.URL.resolve("./pic.png", entry)
    assert find_spec(spaced, "./pic.png").url == picture
  end

  test "importScripts keeps a later literal after a non-literal argument" do
    entry = "http://example.com/assets/worker.js"

    opts = %{javascript_goal: :script, worker_base: entry, url: entry, referrer_url: entry}

    template =
      js_refs(~s|importScripts(`${base}/dep.js`, "./other.js");|, opts)

    assert Enum.map(template, & &1.spec) == ["./other.js"]
    assert hd(template).url == "http://example.com/assets/other.js"

    surrogate = js_refs(~S|importScripts("\uD800", "./ok.js");|, opts)

    assert Enum.map(surrogate, & &1.spec) == ["./ok.js"]
    assert hd(surrogate).url == "http://example.com/assets/ok.js"
  end

  test "strings inside an array, index, or object are not importScripts arguments" do
    entry = "http://example.com/assets/worker.js"
    opts = %{javascript_goal: :script, worker_base: entry, url: entry, referrer_url: entry}

    listed = js_refs(~s|importScripts([1, "./yes.js", "./no.js"], "./ok.js");|, opts)
    assert Enum.map(listed, & &1.spec) == ["./ok.js"]
    assert hd(listed).url == "http://example.com/assets/ok.js"

    assert js_refs(~s|importScripts(["./a.js", "./b.js", "./c.js"]);|, opts) == []

    indexed = js_refs(~s|importScripts(obj["./a.js", "./b.js", "./c.js"], "./ok.js");|, opts)
    assert Enum.map(indexed, & &1.spec) == ["./ok.js"]

    nested = js_refs(~s|importScripts(foo("./no.js", "./no2.js"), "./ok.js");|, opts)
    assert Enum.map(nested, & &1.spec) == ["./ok.js"]

    object = js_refs(~s|importScripts({a: "./no.js"}, "./ok.js");|, opts)
    assert Enum.map(object, & &1.spec) == ["./ok.js"]

    both =
      js_refs(~s|importScripts("./keep.js", ["./no.js"], "./also.js");|, opts)

    assert Enum.map(both, & &1.spec) == ["./keep.js", "./also.js"]
  end

  test "one module rewrites a mapped name and import.meta.url to different files" do
    map = ImportMap.parse(~s|{"imports":{"vue":"/vue.js"}}|, @base)

    source =
      ~s|import "vue";\nnew URL("vue", import.meta.url);\nnew URL("./pic.png", import.meta.url);|

    assert {:ok, body} =
             LinkReplacer.replace_links(source, %{
               url: @script,
               referrer_url: @script,
               content_type: "application/javascript",
               html_tag: "link",
               javascript_goal: :module,
               document_base: @base,
               import_map: map
             })

    vue = "http://example.com/vue.js"
    relative = "http://example.com/js/vue"
    pic = "http://example.com/js/pic.png"

    assert body ==
             ~s|import "#{vue}";\nnew URL("#{relative}", import.meta.url);\nnew URL("#{pic}", import.meta.url);|
  end

  test "saved inline modules use the document base and leave classic static imports" do
    source = """
    <base href="#{@base}">
    <script type="importmap">{"imports":{"vue":"./vue.js"}}</script>
    <script type="module">import "vue"; new URL("./pic.png", import.meta.url);</script>
    <script>import "vue"; import("./app.js");</script>
    """

    assert {:ok, body} = rewrite(source)
    assert body =~ ~s|import "http://example.com/assets/vue.js"|
    assert body =~ "http://example.com/assets/pic.png"
    assert body =~ "http://example.com/assets/app.js"
    assert body =~ ~s|import "vue"|
  end

  test "new URL uses the script, the opened page, or the document base" do
    page = "https://example.com/dir/page.html"
    base = "https://example.com/assets/"
    script = "https://example.com/js/app.js"

    refs =
      js_refs(
        """
        new Worker(new URL("./from-script.js", import.meta.url));
        new Worker(new URL("./from-page.js", location.href));
        new Worker(new URL("./from-base.js", document.baseURI));
        new SharedWorker(new URL("./shared.js", location.href));
        CSS.paintWorklet.addModule(new URL("./paint.js", document.baseURI));
        audio.audioWorklet.addModule(new URL("./heard.js", location.href));
        new Worker(new URL("./self-page.js", self.location.href));
        new Worker("./" + "skip.js");
        new Worker(new URL("./skip.js", base));
        fetch(new URL("./fetched-loc.js", location.href));
        new URL("./bare-loc.js", location.href);
        fetch(new URL("./fetched-meta.js", import.meta.url));
        new URL("./bare-meta.js", import.meta.url);
        new Worker(new URL("./win-loc.js", window.location.href));
        """,
        %{url: script, referrer_url: script, document_base: base, document_url: page}
      )

    assert find_spec(refs, "./from-script.js").url == "https://example.com/js/from-script.js"
    assert find_spec(refs, "./from-page.js").url == "https://example.com/dir/from-page.js"
    assert find_spec(refs, "./from-base.js").url == "https://example.com/assets/from-base.js"
    assert find_spec(refs, "./shared.js").url == "https://example.com/dir/shared.js"
    assert find_spec(refs, "./paint.js").url == "https://example.com/assets/paint.js"
    assert find_spec(refs, "./heard.js").url == "https://example.com/dir/heard.js"
    assert find_spec(refs, "./self-page.js").url == "https://example.com/dir/self-page.js"
    assert find_spec(refs, "./fetched-meta.js").goal == nil
    assert find_spec(refs, "./bare-meta.js").goal == nil

    refute Enum.any?(
             refs,
             &(&1.spec in [
                 "./skip.js",
                 "./fetched-loc.js",
                 "./bare-loc.js",
                 "./win-loc.js"
               ])
           )

    classic =
      js_refs(
        """
        new Worker(new URL("./from-script.js", import.meta.url));
        new Worker(new URL("./from-page.js", location.href));
        navigator.serviceWorker.register(new URL("./sw.js", import.meta.url));
        audio.audioWorklet.addModule(new URL("./proc.js", import.meta.url));
        """,
        %{
          javascript_goal: :script,
          url: script,
          referrer_url: script,
          document_base: base,
          document_url: page
        }
      )

    assert Enum.map(classic, & &1.spec) == ["./from-page.js", "./proc.js"]
    assert find_spec(classic, "./from-page.js").url == "https://example.com/dir/from-page.js"
    assert find_spec(classic, "./proc.js").goal == :module

    entry = "https://example.com/js/sw.js"

    inside =
      js_refs(
        """
        importScripts(new URL("./ok.js", self.location.href));
        importScripts(new URL("./also.js", location.href));
        new Worker(new URL("./no-doc.js", document.baseURI));
        importScripts(new URL("https://cdn.example.com/abs.js", document.baseURI));
        """,
        %{
          javascript_goal: :script,
          worker_base: entry,
          url: "https://example.com/js/lib.js",
          referrer_url: "https://example.com/js/lib.js",
          document_base: base,
          document_url: page
        }
      )

    assert find_spec(inside, "./ok.js").url == "https://example.com/js/ok.js"
    assert find_spec(inside, "./also.js").url == "https://example.com/js/also.js"
    refute Enum.any?(inside, &(&1.spec in ["./no-doc.js", "https://cdn.example.com/abs.js"]))
  end

  test "a bare new URL file keeps the page or the worker" do
    page = "https://example.com/dir/page.html"
    base = "https://example.com/assets/"
    script = "https://example.com/js/app.js"
    chunk = "https://example.com/js/chunk.js"

    parent =
      js_refs(~s|new URL("./chunk.js", import.meta.url);|, %{
        url: script,
        referrer_url: script,
        document_base: base,
        document_url: page
      })

    file = find_spec(parent, "./chunk.js")
    assert file.goal == nil
    assert file.document_url == page
    assert file.document_base == base
    assert file.worker_base == nil

    child =
      js_refs(
        """
        new Worker(new URL("./from-page.js", location.href));
        new Worker(new URL("./from-base.js", document.baseURI));
        """,
        %{
          url: chunk,
          referrer_url: chunk,
          document_url: file.document_url,
          document_base: file.document_base,
          worker_base: file.worker_base
        }
      )

    assert find_spec(child, "./from-page.js").url == "https://example.com/dir/from-page.js"
    assert find_spec(child, "./from-base.js").url == "https://example.com/assets/from-base.js"

    entry = "https://example.com/js/sw.js"

    worker_file =
      js_refs(~s|new URL("./chunk.js", import.meta.url);|, %{
        javascript_goal: :module,
        worker_base: entry,
        url: entry,
        referrer_url: entry,
        document_url: page,
        document_base: base
      })

    carried = find_spec(worker_file, "./chunk.js")
    assert carried.worker_base == entry
    assert carried.document_url == nil
    assert carried.document_base == nil

    inside =
      js_refs(
        """
        new Worker(new URL("./from-worker.js", location.href));
        new Worker(new URL("https://cdn.example.com/abs.js", document.baseURI));
        """,
        %{
          url: chunk,
          referrer_url: chunk,
          document_url: carried.document_url,
          document_base: carried.document_base,
          worker_base: carried.worker_base
        }
      )

    assert find_spec(inside, "./from-worker.js").url == "https://example.com/js/from-worker.js"
    refute Enum.any?(inside, &(&1.spec == "https://cdn.example.com/abs.js"))
  end

  test "an inline module keeps import.meta.url on the base and location on the page" do
    page = "https://example.com/dir/page.html"
    base = "https://example.com/assets/"

    source = """
    <base href="#{base}">
    <script type="module">
    new Worker(new URL("./inline-base.js", import.meta.url));
    new Worker(new URL("./inline-page.js", location.href));
    new Worker(new URL("./inline-self.js", self.location.href));
    </script>
    """

    refs =
      html_refs(source, %{url: "https://example.com/old", referrer_url: page})

    assert find_spec(refs, "./inline-base.js").url == "https://example.com/assets/inline-base.js"
    assert find_spec(refs, "./inline-page.js").url == "https://example.com/dir/inline-page.js"
    assert find_spec(refs, "./inline-self.js").url == "https://example.com/dir/inline-self.js"

    old = "https://example.com/old"

    assert {:ok, body} = rewrite(source, %{url: old, referrer_url: page})
    assert body =~ "https://example.com/assets/inline-base.js"
    assert body =~ "https://example.com/dir/inline-page.js"
  end

  test "a saved module points page and script addresses at different files" do
    page = "https://example.com/dir/page.html"
    base = "https://example.com/assets/"
    script = "https://example.com/js/app.js"

    source = """
    new Worker(new URL("./from-script.js", import.meta.url));
    new Worker(new URL("./from-page.js", location.href));
    """

    assert {:ok, body} =
             LinkReplacer.replace_links(source, %{
               url: script,
               referrer_url: script,
               document_url: page,
               document_base: base,
               content_type: "application/javascript",
               html_tag: "link",
               javascript_goal: :module
             })

    from_script = "https://example.com/js/from-script.js"
    from_page = "https://example.com/dir/from-page.js"
    assert from_script != from_page
    assert body =~ from_script
    assert body =~ from_page
  end

  test "worker and worklet credentials follow the kind of call" do
    refs =
      js_refs(
        """
        new Worker("https://cdn.example.com/included.js", {type: "module", credentials: "include"});
        new Worker("/omitted.js", {type: "module", credentials: "omit"});
        new Worker("https://cdn.example.com/local.js", {type: "module"});
        new Worker("https://cdn.example.com/classic.js", {credentials: "include"});
        new Worker("/classic-home.js", {credentials: "include"});
        new SharedWorker("https://cdn.example.com/shared.js", {type: "module", credentials: "include"});
        CSS.paintWorklet.addModule("https://cdn.example.com/paint.js", {credentials: "include"});
        audio.audioWorklet.addModule("/quiet.js", {credentials: "omit"});
        navigator.serviceWorker.register("./sw.js", {type: "module", credentials: "include"});
        new Worker("https://cdn.example.com/unknown.js", {type: "module", credentials: "Include"});
        new Worker("https://cdn.example.com/explicit.js", {type: "module", credentials: "same-origin"});
        new Worker("./later.js", {credentials: "omit", type: "module"});
        """,
        %{document_base: @base}
      )

    assert_entry(refs, "https://cdn.example.com/included.js", :module, :include)
    assert_entry(refs, "/omitted.js", :module, :omit)
    assert_entry(refs, "https://cdn.example.com/local.js", :module, :same_origin)
    assert_entry(refs, "https://cdn.example.com/classic.js", :script, :same_origin)
    assert_entry(refs, "/classic-home.js", :script, :same_origin)
    assert_entry(refs, "https://cdn.example.com/shared.js", :module, :include)
    assert_entry(refs, "https://cdn.example.com/paint.js", :module, :include)
    assert_entry(refs, "/quiet.js", :module, :omit)
    assert_entry(refs, "./sw.js", :module, :same_origin)
    assert_entry(refs, "https://cdn.example.com/unknown.js", :module, :same_origin)
    assert_entry(refs, "https://cdn.example.com/explicit.js", :module, :same_origin)
    assert_entry(refs, "./later.js", :module, :omit)
  end

  test "importScripts(new URL) is a classic script and keeps the worker location" do
    page = "https://example.com/dir/page.html"
    entry = "https://example.com/js/sw.js"
    lib = "https://example.com/js/lib.js"
    map = ImportMap.parse(~s|{"imports":{"vue":"/vue.js"}}|, @base)

    refs =
      js_refs(
        """
        importScripts(new URL("./lib.js", self.location.href));
        importScripts("./plain.js");
        importScripts(new URL("./also.js", location.href));
        importScripts(new URL("./meta.js", import.meta.url));
        """,
        %{
          javascript_goal: :script,
          worker_base: entry,
          url: entry,
          referrer_url: entry,
          document_url: page,
          document_base: "https://example.com/assets/",
          import_map: map
        }
      )

    assert find_spec(refs, "./lib.js").url == lib
    assert find_spec(refs, "./plain.js").url == "https://example.com/js/plain.js"
    assert find_spec(refs, "./also.js").url == "https://example.com/js/also.js"
    assert find_spec(refs, "./meta.js").url == "https://example.com/js/meta.js"
    assert Enum.all?(refs, &(&1.goal == :script and &1.credentials == :same_origin))

    inner = "https://example.com/js/lib/inner.js"

    nested =
      js_refs(
        """
        importScripts(new URL("./nested.js", self.location.href));
        importScripts(new URL("./meta.js", import.meta.url));
        import "vue";
        import("./dyn.js");
        import("vue");
        """,
        %{
          javascript_goal: :script,
          worker_base: entry,
          url: inner,
          referrer_url: inner,
          document_url: page,
          document_base: "https://example.com/assets/",
          import_map: map
        }
      )

    assert Enum.map(nested, & &1.spec) == ["./nested.js", "./meta.js", "./dyn.js"]
    assert find_spec(nested, "./nested.js").url == "https://example.com/js/nested.js"
    assert find_spec(nested, "./meta.js").url == "https://example.com/js/lib/meta.js"
    assert find_spec(nested, "./dyn.js").url == "https://example.com/js/lib/dyn.js"
    assert find_spec(nested, "./dyn.js").goal == :module
    assert find_spec(nested, "./dyn.js").credentials == :same_origin
    assert find_spec(nested, "./dyn.js").import_map == nil
  end

  test "import(new URL) is a module import and keeps the caller's cookies" do
    page = "https://www.example.com/dir/page.html"
    base = "https://www.example.com/assets/"
    map = ImportMap.parse(~s|{"imports":{"vue":"/vue.js","/js/lib.js":"/mapped.js"}}|, base)

    refs =
      js_refs(
        """
        import(new URL("./mod.js", location.href));
        import(new URL("./based.js", document.baseURI));
        import(new URL("./classic-meta.js", import.meta.url));
        import(new URL("/js/lib.js", location.href));
        """,
        %{
          javascript_goal: :script,
          url: page,
          referrer_url: page,
          document_url: page,
          document_base: base,
          import_map: map
        }
      )

    assert find_spec(refs, "./mod.js").url == "https://www.example.com/dir/mod.js"
    assert find_spec(refs, "./based.js").url == "https://www.example.com/assets/based.js"
    assert find_spec(refs, "/js/lib.js").url == "https://www.example.com/js/lib.js"
    refute Enum.any?(refs, &(&1.url == "https://www.example.com/mapped.js"))
    refute Enum.any?(refs, &(&1.spec == "./classic-meta.js"))

    for spec <- ["./mod.js", "./based.js", "/js/lib.js"] do
      ref = find_spec(refs, spec)
      assert ref.goal == :module
      assert ref.credentials == :same_origin
      assert resolve_carried(ref, "vue") == {:ok, "https://www.example.com/vue.js"}
    end

    script = "https://cdn.example.com/anon-entry.js"

    included =
      js_refs(~s|import(new URL("./next.js", import.meta.url));|, %{
        url: script,
        referrer_url: script,
        document_url: page,
        document_base: base,
        credentials: :include
      })

    assert find_spec(included, "./next.js").url == "https://cdn.example.com/next.js"
    assert find_spec(included, "./next.js").credentials == :include
    assert find_spec(included, "./next.js").goal == :module

    worker =
      js_refs(~s|import(new URL("./next.js", location.href));|, %{
        javascript_goal: :module,
        worker_base: script,
        url: script,
        referrer_url: script,
        document_url: page,
        document_base: base,
        import_map: map,
        credentials: :include
      })

    assert find_spec(worker, "./next.js").url == "https://cdn.example.com/next.js"
    assert find_spec(worker, "./next.js").import_map == nil
    assert find_spec(worker, "./next.js").credentials == :include
  end

  defp html_refs(source, opts \\ %{}) do
    opts =
      Map.merge(
        %{
          url: @page,
          referrer_url: @page,
          content_type: "text/html",
          html_tag: "a",
          assets: ["js"]
        },
        opts
      )

    references(source, opts)
  end

  defp js_refs(source, opts) do
    opts =
      Map.merge(
        %{
          url: @script,
          referrer_url: @script,
          content_type: "application/javascript",
          html_tag: "link",
          javascript_goal: :module,
          document_base: @base
        },
        opts
      )

    references(source, opts)
  end

  defp references(source, opts) do
    source
    |> Parser.parse_links(opts, fn element, link_opts ->
      {spec, url} = spec_url(element)

      %{
        spec: spec,
        url: url,
        html_tag: link_opts.html_tag,
        goal: link_opts[:javascript_goal],
        reference_tag: link_opts.reference_tag,
        import_map: link_opts[:import_map],
        document_base: link_opts[:document_base],
        document_url: link_opts[:document_url],
        worker_base: link_opts[:worker_base],
        credentials: link_opts[:credentials]
      }
    end)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp spec_url({_tag, spec, _attr, url}), do: {spec, url}
  defp spec_url({_attr, url}), do: {url, url}

  defp urls(refs, spec) do
    refs |> Enum.filter(&(&1.spec == spec)) |> Enum.map(& &1.url)
  end

  defp find_spec(refs, spec) do
    Enum.find(refs, &(&1.spec == spec)) || flunk("missing #{spec}")
  end

  defp assert_entry(refs, spec, goal, credentials) do
    ref = find_spec(refs, spec)
    assert ref.goal == goal
    assert ref.credentials == credentials
  end

  defp resolve_carried(ref, spec) do
    ImportMap.resolve(spec, ref.import_map || ImportMap.empty(), ref.document_base || @page)
  end

  defp rewrite(source, opts \\ %{}) do
    LinkReplacer.replace_links(
      source,
      Map.merge(
        %{
          url: @page,
          referrer_url: @page,
          content_type: "text/html",
          html_tag: "a",
          assets: ["js"]
        },
        opts
      )
    )
  end
end
