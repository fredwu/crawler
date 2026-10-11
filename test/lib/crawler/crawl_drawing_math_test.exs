defmodule Crawler.CrawlDrawingMathTest do
  use Crawler.TestCase, async: false

  import Plug.Conn
  import Crawler.SnapshotHelpers

  alias Crawler.Linker
  alias Crawler.Snapper
  alias Crawler.Store
  alias Crawler.Store.Page

  defmodule CustomStore do
    def add_page_data({url, _scope}, body, opts) do
      send(opts[:storage_owner], {:stored, url, body})
      :ok
    end
  end

  @svg """
  <svg>
    <image href="icon.png"/>
    <script href="draw.js"></script>
    <style>g { fill: url(paint.png); }</style>
  </svg>
  """

  @svg_document """
  <svg>
    <image href="icon.png"/>
    <script href="draw.js"></script>
    <style>g { fill: url(paint.png); }</style>
    <a href="next.html">Next</a>
  </svg>
  """

  test "linked svg documents are crawled and picture svgs stay closed", context do
    page = context.url <> "/dir/page"
    scope = unique_scope("svg-document")
    root = tmp(scope)

    html = """
    <a href="/diagram.svg">Diagram</a>
    <img src="/images/picture.svg">
    <style>body { background: url(/css/background.svg); }</style>
    <iframe src="/frames/frame.svg"></iframe>
    <object data="/objects/object.svg"></object>
    <embed src="/embeds/embed.svg">
    """

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, html))
    expect_svg(context, "/diagram.svg", @svg, "image/svg+xml; charset=utf-8")
    expect_svg(context, "/images/picture.svg", @svg, "image/svg+xml")
    expect_svg(context, "/css/background.svg", @svg, "image/svg+xml")

    for path <- ["/frames/frame.svg", "/objects/object.svg", "/embeds/embed.svg"] do
      expect_svg(context, path, @svg, "image/svg+xml")
    end

    for directory <- ["", "/frames", "/objects", "/embeds"] do
      expect_bytes(context, directory <> "/icon.png", "image/png", "png")
      expect_bytes(context, directory <> "/draw.js", "text/javascript", "js")
      expect_bytes(context, directory <> "/paint.png", "image/png", "png")
    end

    opts = crawl(page, context, root, scope, ["css", "js", "images"])

    for directory <- ["", "/frames", "/objects", "/embeds"] do
      assert Store.find_processed({context.url <> directory <> "/icon.png", scope})
      assert Store.find_processed({context.url <> directory <> "/draw.js", scope})
      assert Store.find_processed({context.url <> directory <> "/paint.png", scope})
    end

    refute Store.find({context.url <> "/images/icon.png", scope})
    refute Store.find({context.url <> "/images/draw.js", scope})
    refute Store.find({context.url <> "/images/paint.png", scope})
    refute Store.find({context.url <> "/css/icon.png", scope})
    refute Store.find({context.url <> "/css/draw.js", scope})
    refute Store.find({context.url <> "/css/paint.png", scope})
    refute Store.find({context.url <> "/dir/icon.png", scope})

    diagram = File.read!(saved(root, context.url <> "/diagram.svg"))
    refute String.starts_with?(diagram, <<0xEF, 0xBB, 0xBF>>)
    refute diagram =~ ~s|href="icon.png"|
    refute diagram =~ ~s|href="draw.js"|
    refute diagram =~ "url(paint.png)"

    assert File.read!(saved(root, context.url <> "/images/picture.svg")) == @svg
    assert File.read!(saved(root, context.url <> "/css/background.svg")) == @svg
    assert_link_opens(root, context.url <> "/diagram.svg", context.url <> "/icon.png")
    refute Crawler.running?(opts)
  end

  test "assetless crawls follow svg anchors and math links only", context do
    page = context.url <> "/dir/page"
    scope = unique_scope("svg-anchors")
    root = tmp(scope)

    html = ~s|<a href="/diagram.svg">D</a><math><mrow href="/math-next.html">M</mrow></math>|

    diagram = """
    <svg>
      <a href="next.html">N</a>
      <image href="icon.png"/>
      <script href="draw.js"></script>
      <style>g { fill: url(paint.png); }</style>
      <feImage href="tex.png"/>
    </svg>
    """

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, html))
    expect_svg(context, "/diagram.svg", diagram, "image/svg+xml")
    expect_html(context, "/next.html", "next")
    expect_html(context, "/math-next.html", "math")

    opts = crawl(page, context, root, scope, [])
    assert Store.find_processed({context.url <> "/next.html", scope})
    assert Store.find_processed({context.url <> "/math-next.html", scope})
    refute Store.find({context.url <> "/icon.png", scope})
    refute Store.find({context.url <> "/draw.js", scope})
    refute Store.find({context.url <> "/paint.png", scope})
    refute Store.find({context.url <> "/tex.png", scope})
    refute Crawler.running?(opts)
  end

  test "svg paint files honour the base url and the image channel", context do
    page = context.url <> "/dir/page"
    scope = unique_scope("svg-paint")
    root = tmp(scope)

    html = """
    <base href="/assets/">
    <svg>
      <image href="icon.png"/>
      <use href="sprite.svg#mark"/>
      <feImage href="tex.png" xlink:href="ignored.png"/>
      <feImage xlink:href="legacy.png"/>
      <linearGradient href="paints.svg#metal"/>
      <pattern href="#local"/>
      <a href="next.html">Next</a>
    </svg>
    """

    paints = ~s|<svg><image href="secret.png"/><script href="secret.js"></script></svg>|

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, html))

    for path <- ["/assets/icon.png", "/assets/tex.png", "/assets/legacy.png"] do
      expect_bytes(context, path, "image/png", "png")
    end

    expect_svg(context, "/assets/sprite.svg", "<svg/>", "image/svg+xml")
    expect_svg(context, "/assets/paints.svg", paints, "image/svg+xml")
    expect_html(context, "/assets/next.html", "next")

    opts = crawl(page, context, root, scope, ["images"])
    saved = File.read!(saved(root, page))
    refute saved =~ ~s|href="tex.png"|
    refute saved =~ ~s|xlink:href="legacy.png"|
    assert saved =~ ~s|href="#local"|
    refute Store.find({context.url <> "/assets/ignored.png", scope})
    refute Store.find({context.url <> "/assets/secret.png", scope})
    refute Store.find({context.url <> "/assets/secret.js", scope})
    refute Store.find({context.url <> "/assets", scope})
    refute Crawler.running?(opts)
  end

  test "image assets off still follows the svg anchor", context do
    page = context.url <> "/dir/page"
    scope = unique_scope("svg-paint-off")
    root = tmp(scope)

    html = """
    <svg>
      <image href="icon.png"/>
      <feImage href="tex.png"/>
      <a href="next.html">Next</a>
    </svg>
    """

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, html))
    expect_html(context, "/dir/next.html", "next")

    opts = crawl(page, context, root, scope, ["css", "js"])
    assert Store.find_processed({context.url <> "/dir/next.html", scope})
    refute Store.find({context.url <> "/dir/icon.png", scope})
    refute Store.find({context.url <> "/dir/tex.png", scope})
    assert File.read!(saved(root, page)) =~ ~s|href="tex.png"|
    refute Crawler.running?(opts)
  end

  test "css assets off leaves drawing style urls untouched", context do
    page = context.url <> "/dir/page"
    scope = unique_scope("svg-css-off")
    root = tmp(scope)

    html = """
    <base href="/assets/">
    <svg>
      <style>g { fill: url("paint.png"); } /* url(hidden.png) */</style>
      <rect style="fill: url(attr.png)"/>
    </svg>
    """

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, html))
    opts = crawl(page, context, root, scope, ["images", "js"])
    saved = File.read!(saved(root, page))
    assert saved =~ ~s|url("paint.png")|
    assert saved =~ "url(attr.png)"
    assert saved =~ "url(hidden.png)"
    refute Crawler.running?(opts)
  end

  test "math links stay on the site and nofollow skips them without skipping scripts", context do
    page = context.url <> "/start"
    scope = unique_scope("math-links")
    root = tmp(scope)

    html = """
    <math>
      <mrow href="/next">Next</mrow>
      <a href="/also.html">Also</a>
      <mo href="https://other.test/out">Out</mo>
    </math>
    <template><math><mrow href="/inert.html">Inert</mrow></math></template>
    <math><svg><image href="not-svg.png"/></svg></math>
    <math>
      <annotation-xml encoding="text/html"><a href="/from-math.html">In</a></annotation-xml>
    </math>
    <a href="/next">Page</a>
    <a href="https://other.test/out">Page out</a>
    """

    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, html))
    expect_html(context, "/next", "next")
    expect_html(context, "/also.html", "also")
    expect_html(context, "/from-math.html", "from-math")

    opts = crawl(page, context, root, scope, ["images", "js"])
    saved = File.read!(saved(root, page))
    next_href = Linker.offline_link(page, context.url <> "/next")
    out_href = Linker.offline_link(page, "https://other.test/out")
    assert saved =~ ~s|<mrow href="#{next_href}">|
    assert saved =~ ~s|<a href="#{next_href}">Page</a>|
    assert saved =~ ~s|<mo href="#{out_href}">|
    assert saved =~ ~s|<a href="#{out_href}">Page out</a>|
    assert saved =~ ~s|href="/inert.html"|
    assert saved =~ ~s|href="not-svg.png"|
    refute Store.find({"https://other.test/out", scope})
    refute Store.find({context.url <> "/inert.html", scope})
    refute Store.find({context.url <> "/not-svg.png", scope})
    refute Crawler.running?(opts)
  end

  test "page nofollow skips math links and still fetches a script", context do
    page = context.url <> "/quiet"
    scope = unique_scope("math-nofollow")
    root = tmp(scope)

    html = """
    <meta name="robots" content="nofollow">
    <math>
      <mrow href="/next">Next</mrow>
      <a href="/also.html">Also</a>
    </math>
    <math>
      <annotation-xml encoding="text/html"><a href="/from-math.html">In</a></annotation-xml>
    </math>
    <script src="/still.js"></script>
    """

    ReqTestSite.expect_once(context.site, "GET", "/quiet", &html(&1, html))
    expect_bytes(context, "/still.js", "text/javascript", "js")

    opts = crawl(page, context, root, scope, ["js"])
    assert Store.find_processed({context.url <> "/still.js", scope})
    refute Store.find({context.url <> "/next", scope})
    refute Store.find({context.url <> "/also.html", scope})
    refute Store.find({context.url <> "/from-math.html", scope})
    refute Crawler.running?(opts)
  end

  test "a saved drawing rewrites fetched resources and keeps ignored bytes", context do
    page = context.url <> "/dir/page"
    scope = unique_scope("drawing-saved")
    root = tmp(scope)

    html = """
    <svg>
      <style>g { fill: url(paint.png); } /* url(hidden.png) */</style>
      <script href="draw.js" src="ignored.js"></script>
      <feImage href="tex.png"/>
      <image href="icon.png"/>
    </svg>
    <template><svg><feImage href="inert.png"/></svg></template>
    <math><mrow href="https://other.test/out">Out</mrow></math>
    <a href="https://other.test/out">Out</a>
    """

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, html))
    expect_bytes(context, "/dir/paint.png", "image/png", "png")
    expect_bytes(context, "/dir/draw.js", "text/javascript", "js")
    expect_bytes(context, "/dir/tex.png", "image/png", "png")
    expect_bytes(context, "/dir/icon.png", "image/png", "png")

    opts = crawl(page, context, root, scope, ["css", "js", "images"])
    saved = File.read!(saved(root, page))
    out = Linker.offline_link(page, "https://other.test/out")

    assert saved =~ "url(hidden.png)"
    assert saved =~ ~s|src="ignored.js"|
    assert saved =~ ~s|href="inert.png"|
    refute saved =~ "url(paint.png)"
    refute saved =~ ~s|href="draw.js"|
    refute saved =~ ~s|href="tex.png"|
    refute saved =~ ~s|href="icon.png"|
    assert saved =~ ~s|<mrow href="#{out}">|
    assert saved =~ ~s|<a href="#{out}">|
    refute Store.find({"https://other.test/out", scope})
    refute Store.find({context.url <> "/dir/hidden.png", scope})
    refute Store.find({context.url <> "/dir/ignored.js", scope})
    refute Store.find({context.url <> "/dir/inert.png", scope})
    refute Crawler.running?(opts)
  end

  test "svg paint may come from another host while a math link may not", context do
    page = context.url <> "/dir/page"
    scope = unique_scope("svg-cross-site")
    root = tmp(scope)
    paint = context.url2 <> "/tex.png"
    away = context.url2 <> "/math.html"

    html = ~s|<svg><feImage href="#{paint}"/></svg><math><mrow href="#{away}">M</mrow></math>|

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, html))
    expect_bytes(context.site2, "/tex.png", "image/png", "png")

    opts = crawl(page, context, root, scope, ["images"])
    assert Store.find_processed({paint, scope})
    refute Store.find({away, scope})
    refute Crawler.running?(opts)
  end

  test "a shared svg is a document when the picture is seen first", context do
    assert_shared_document(context, "picture-first", """
    <img src="/diagram.svg">
    <a href="/diagram.svg">Diagram</a>
    """)
  end

  test "a shared svg is a document when the picture is seen first without a user store",
       context do
    assert_shared_document(
      context,
      "picture-first-default-store",
      """
      <img src="/diagram.svg">
      <a href="/diagram.svg">Diagram</a>
      """,
      store: nil
    )
  end

  test "a shared svg is a document when the page link is seen first", context do
    assert_shared_document(context, "link-first", """
    <a href="/diagram.svg">Diagram</a>
    <img src="/diagram.svg">
    """)
  end

  test "a cross-site anchor does not open an svg fetched as a picture", context do
    page = context.url <> "/dir/page"
    scope = unique_scope("svg-picture-cross-site")
    root = tmp(scope)
    picture = context.url2 <> "/pic.svg"
    html = ~s|<img src="#{picture}"><a href="#{picture}">D</a>|

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, html))
    expect_bytes(context.site2, "/pic.svg", "image/svg+xml", @svg)

    opts = crawl(page, context, root, scope, ["css", "js", "images"])
    assert Store.find_processed({picture, scope})
    refute Store.find({context.url2 <> "/icon.png", scope})
    assert File.read!(saved(root, picture)) == @svg
    refute Crawler.running?(opts)
  end

  test "an upgraded svg document uses the final response url", context do
    assert_redirected_document(context, "svg-redirect-document", store: Store)
  end

  test "an upgraded svg document uses the final response url without a user store", context do
    assert_redirected_document(context, "svg-redirect-default-store", store: nil)
  end

  test "a custom store is not written again when a document link opens its svg", context do
    page = context.url <> "/dir/page"
    scope = unique_scope("svg-custom-store")
    root = tmp(scope)
    svg = context.url <> "/diagram.svg"

    html = ~s|<img src="/diagram.svg"><a href="/diagram.svg">Diagram</a>|

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, html))
    expect_svg(context, "/diagram.svg", @svg_document, "image/svg+xml")
    expect_bytes(context, "/icon.png", "image/png", "png")
    expect_bytes(context, "/draw.js", "text/javascript", "js")
    expect_bytes(context, "/paint.png", "image/png", "png")
    expect_html(context, "/next.html", "next")

    opts =
      crawl(page, context, root, scope, ["css", "js", "images"],
        store: CustomStore,
        storage_owner: self()
      )

    stored = flush_stored()
    assert Enum.count(stored, &match?({^svg, _}, &1)) == 1

    for path <- ["/icon.png", "/draw.js", "/paint.png", "/next.html"] do
      url = context.url <> path
      assert Store.find_processed({url, scope})
      assert Enum.count(stored, &match?({^url, _}, &1)) == 1
    end

    diagram = File.read!(saved(root, svg))
    refute diagram =~ ~s|href="icon.png"|
    refute diagram =~ "url(paint.png)"
    refute Crawler.running?(opts)
  end

  test "a document link does not wait for a picture that is not svg", context do
    page = context.url <> "/dir/page"
    picture = context.url <> "/photo.jpg"
    scope = unique_scope("svg-picture-jpeg")
    root = tmp(scope)
    on_exit(fn -> File.rm_rf(root) end)

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, "<p>seed</p>"))

    {:ok, opts} =
      start_crawl(page,
        scope: scope,
        workers: 1,
        retries: 0,
        max_depths: 3,
        assets: ["images"],
        save_to: root,
        req_options: context.req_options
      )

    on_exit(fn -> Crawler.stop(opts) end)
    wait(5_000, fn -> refute Crawler.running?(opts) end)

    assert {:ok, _} = Store.add({picture, scope}, opts.generation, opts.queue, "img")

    assert :ok ==
             Store.note_picture_type(
               {picture, scope},
               "image/jpeg",
               opts.generation,
               opts.queue
             )

    {:ok, claim} =
      Store.start_work(%{
        url: picture,
        scope: scope,
        generation: opts.generation,
        queue: opts.queue,
        max_pages: :infinity
      })

    on_exit(fn -> Store.finish_claim(claim) end)

    assert {:ok, _} = Crawler.crawl(picture, Map.merge(opts, %{html_tag: "a", depth: 1}))

    wait(2_000, fn ->
      assert Store.pending_count(scope) == 0
      assert Store.inflight_count(scope) == 1
    end)

    held = System.monotonic_time(:millisecond)

    wait(1_000, fn ->
      assert Store.pending_count(scope) == 0
      assert Store.inflight_count(scope) == 1
      assert System.monotonic_time(:millisecond) - held >= 200
    end)

    refute Store.find_processed({picture, scope})
  end

  test "a document link waits until the picture fetch finishes", context do
    page = context.url <> "/dir/page"
    svg = context.url <> "/diagram.svg"
    scope = unique_scope("svg-picture-inflight")
    root = tmp(scope)
    on_exit(fn -> File.rm_rf(root) end)

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, "<p>seed</p>"))
    expect_bytes(context, "/icon.png", "image/png", "png")
    expect_bytes(context, "/draw.js", "text/javascript", "js")
    expect_bytes(context, "/paint.png", "image/png", "png")
    expect_html(context, "/next.html", "next")

    {:ok, opts} =
      start_crawl(page,
        scope: scope,
        workers: 1,
        retries: 0,
        max_depths: 3,
        assets: ["css", "js", "images"],
        store: Store,
        save_to: root,
        req_options: context.req_options
      )

    on_exit(fn -> Crawler.stop(opts) end)
    wait(5_000, fn -> refute Crawler.running?(opts) end)

    assert {:ok, _} = Store.add({svg, scope}, opts.generation, opts.queue, "img")

    {:ok, claim} =
      Store.start_work(%{
        url: svg,
        scope: scope,
        generation: opts.generation,
        queue: opts.queue,
        max_pages: :infinity
      })

    on_exit(fn -> Store.finish_claim(claim) end)

    stored = %{
      url: svg,
      scope: scope,
      generation: opts.generation,
      queue: opts.queue,
      html_tag: "img",
      content_type: "image/svg+xml",
      referrer_url: svg,
      store: Store,
      save_to: root
    }

    assert {_new, %Page{}} = Store.add_page_data({svg, scope}, @svg_document, stored)

    assert {:ok, _document} = Crawler.crawl(svg, Map.merge(opts, %{html_tag: "a", depth: 1}))

    # The picture claim is already one in-flight slot. A document worker that does not
    # wait returns immediately and the count falls back to one. It has to stay at two.
    wait(1_000, fn -> assert Store.inflight_count(scope) >= 2 end)
    held = System.monotonic_time(:millisecond)

    wait(1_000, fn ->
      assert Store.inflight_count(scope) >= 2
      assert System.monotonic_time(:millisecond) - held >= 200
    end)

    assert {:ok, _} = Snapper.snap(@svg_document, Map.put(stored, :html_tag, "img"))
    assert :ok = Store.complete_page({svg, scope}, opts.generation, opts.queue)
    Store.finish_claim(claim)

    wait(5_000, fn -> refute Crawler.running?(opts) end)

    for path <- ["/icon.png", "/draw.js", "/paint.png", "/next.html"] do
      assert Store.find_processed({context.url <> path, scope})
    end

    diagram = File.read!(saved(root, svg))
    refute diagram == @svg_document
    refute diagram =~ ~s|href="icon.png"|
    refute diagram =~ ~s|href="draw.js"|
    refute diagram =~ "url(paint.png)"
  end

  defp assert_shared_document(context, label, html, extra \\ []) do
    page = context.url <> "/dir/page"
    scope = unique_scope(label)
    root = tmp(scope)
    svg = context.url <> "/diagram.svg"

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, html))
    expect_svg(context, "/diagram.svg", @svg_document, "image/svg+xml")
    expect_bytes(context, "/icon.png", "image/png", "png")
    expect_bytes(context, "/draw.js", "text/javascript", "js")
    expect_bytes(context, "/paint.png", "image/png", "png")
    expect_html(context, "/next.html", "next")

    opts = crawl(page, context, root, scope, ["css", "js", "images"], extra)

    for path <- ["/icon.png", "/draw.js", "/paint.png", "/next.html"] do
      assert Store.find_processed({context.url <> path, scope})
    end

    diagram = File.read!(saved(root, svg))
    refute diagram =~ ~s|href="icon.png"|
    refute diagram =~ ~s|href="draw.js"|
    refute diagram =~ "url(paint.png)"

    if Keyword.get(extra, :store, Store) == nil do
      assert %Page{body: body, opts: stored, picture_type: "image/svg+xml"} =
               Store.find({svg, scope})

      assert is_binary(body)
      assert stored[:content_type] == "image/svg+xml"
      assert stored[:html_tag] == "a"
      assert stored[:referrer_url] == svg

      assert %Page{processed: true, body: nil, opts: nil, picture_type: nil} =
               Store.find({page, scope})

      assert %Page{processed: true, body: nil, opts: nil, picture_type: "image/png"} =
               Store.find({context.url <> "/icon.png", scope})
    end

    refute Crawler.running?(opts)
  end

  defp assert_redirected_document(context, label, extra) do
    page = context.url <> "/dir/page"
    scope = unique_scope(label)
    root = tmp(scope)
    old = context.url <> "/old/diagram.svg"
    new = context.url <> "/new/diagram.svg"
    icon = context.url <> "/new/icon.png"
    html = ~s|<img src="/old/diagram.svg"><a href="/old/diagram.svg">Diagram</a>|

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, html))

    ReqTestSite.expect_once(context.site, "GET", "/old/diagram.svg", fn conn ->
      conn
      |> put_resp_header("location", new)
      |> resp(302, "")
    end)

    expect_svg(context, "/new/diagram.svg", @svg_document, "image/svg+xml")
    expect_bytes(context, "/new/icon.png", "image/png", "png")
    expect_bytes(context, "/new/draw.js", "text/javascript", "js")
    expect_bytes(context, "/new/paint.png", "image/png", "png")
    expect_html(context, "/new/next.html", "next")

    opts = crawl(page, context, root, scope, ["css", "js", "images"], extra)

    for path <- ["/new/icon.png", "/new/draw.js", "/new/paint.png", "/new/next.html"] do
      assert Store.find_processed({context.url <> path, scope})
    end

    refute Store.find({context.url <> "/old/icon.png", scope})
    refute Store.find({context.url <> "/old/next.html", scope})
    assert_link_opens(root, old, icon)
    assert_link_opens(root, new, icon)

    if Keyword.get(extra, :store, Store) == nil do
      assert %Page{body: body, opts: stored, picture_type: "image/svg+xml"} =
               Store.find({old, scope})

      assert is_binary(body)
      assert stored[:referrer_url] == new
      assert stored[:alias_url] == new
      assert stored[:content_type] == "image/svg+xml"
      assert %Page{body: nil, opts: nil} = Store.find({new, scope})
    end

    refute Crawler.running?(opts)
  end

  defp crawl(page, context, root, scope, assets, extra \\ []) do
    on_exit(fn -> File.rm_rf(root) end)

    settings =
      Map.merge(
        %{
          scope: scope,
          workers: 1,
          retries: 0,
          max_depths: 3,
          assets: assets,
          store: Store,
          save_to: root,
          req_options: context.req_options
        },
        Map.new(extra)
      )

    {:ok, opts} = start_crawl(page, settings)

    on_exit(fn -> Crawler.stop(opts) end)
    wait(5_000, fn -> refute Crawler.running?(opts) end)
    opts
  end

  defp flush_stored(acc \\ []) do
    receive do
      {:stored, url, body} -> flush_stored([{url, body} | acc])
    after
      0 -> acc
    end
  end

  defp expect_svg(context, path, body, content_type) do
    ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
      conn
      |> put_resp_header("content-type", content_type)
      |> resp(200, body)
    end)
  end

  defp expect_bytes(%Crawler.ReqTestSite{} = site, path, content_type, body) do
    ReqTestSite.expect_once(site, "GET", path, fn conn ->
      conn
      |> put_resp_header("content-type", content_type)
      |> resp(200, body)
    end)
  end

  defp expect_bytes(%{site: site}, path, content_type, body) do
    expect_bytes(site, path, content_type, body)
  end

  defp expect_html(context, path, body) do
    ReqTestSite.expect_once(context.site, "GET", path, &html(&1, body))
  end

  defp html(conn, body) do
    conn
    |> put_resp_header("content-type", "text/html")
    |> resp(200, body)
  end
end
