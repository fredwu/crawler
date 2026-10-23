defmodule Crawler.CrawlDrawingMathTest do
  use Crawler.TestCase, async: false

  import Plug.Conn
  import Crawler.ManagedSnapshotHelpers

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
    root = Path.join(tmp(scope), "archive")

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
    export = ready_export(opts)
    assert length(export.manifest["resources"]) == 19

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

    diagram = read_resource(export, resource_for_url(export, context.url <> "/diagram.svg"))
    refute String.starts_with?(diagram, <<0xEF, 0xBB, 0xBF>>)
    refute diagram =~ ~s|href="icon.png"|
    refute diagram =~ ~s|href="draw.js"|
    refute diagram =~ "url(paint.png)"

    assert read_resource(export, resource_for_url(export, context.url <> "/images/picture.svg")) ==
             @svg

    assert read_resource(export, resource_for_url(export, context.url <> "/css/background.svg")) ==
             @svg

    source = resource_for_url(export, context.url <> "/diagram.svg")
    target = reference_target(export, source, context.url <> "/icon.png")
    assert_link_opens(export, source, target)
    assert read_resource(export, target) == "png"
    refute Crawler.running?(opts)
  end

  test "assetless crawls follow svg anchors and math links only", context do
    page = context.url <> "/dir/page"
    scope = unique_scope("svg-anchors")
    root = Path.join(tmp(scope), "archive")

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
    root = Path.join(tmp(scope), "archive")

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
    export = ready_export(opts)
    saved = read_resource(export, resource_for_url(export, page))
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
    root = Path.join(tmp(scope), "archive")

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
    export = ready_export(opts)
    assert Store.find_processed({context.url <> "/dir/next.html", scope})
    refute Store.find({context.url <> "/dir/icon.png", scope})
    refute Store.find({context.url <> "/dir/tex.png", scope})
    assert read_resource(export, resource_for_url(export, page)) =~ ~s|href="tex.png"|
    refute Crawler.running?(opts)
  end

  test "css assets off leaves drawing style urls untouched", context do
    page = context.url <> "/dir/page"
    scope = unique_scope("svg-css-off")
    root = Path.join(tmp(scope), "archive")

    html = """
    <base href="/assets/">
    <svg>
      <style>g { fill: url("paint.png"); } /* url(hidden.png) */</style>
      <rect style="fill: url(attr.png)"/>
    </svg>
    """

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, html))
    opts = crawl(page, context, root, scope, ["images", "js"])
    export = ready_export(opts)
    saved = read_resource(export, resource_for_url(export, page))
    assert saved =~ ~s|url("paint.png")|
    assert saved =~ "url(attr.png)"
    assert saved =~ "url(hidden.png)"
    refute Crawler.running?(opts)
  end

  test "math links stay on the site and nofollow skips them without skipping scripts", context do
    page = context.url <> "/start"
    scope = unique_scope("math-links")
    root = Path.join(tmp(scope), "archive")

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
    export = ready_export(opts)
    saved = read_resource(export, resource_for_url(export, page))
    source = resource_for_url(export, page)
    target = reference_target(export, source, context.url <> "/next")
    next_href = relative_reference(source, target)
    out_href = "https://other.test/out"
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
    root = Path.join(tmp(scope), "archive")

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
    root = Path.join(tmp(scope), "archive")

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
    export = ready_export(opts)
    saved = read_resource(export, resource_for_url(export, page))
    out = "https://other.test/out"

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
    root = Path.join(tmp(scope), "archive")
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
    <iframe src="/diagram.svg"></iframe>
    """)
  end

  test "a shared svg is a document when the picture is seen first without a user store",
       context do
    assert_shared_document(
      context,
      "picture-first-default-store",
      """
      <img src="/diagram.svg">
      <iframe src="/diagram.svg"></iframe>
      """,
      store: nil
    )
  end

  test "a shared svg is a document when the iframe is seen first", context do
    assert_shared_document(context, "link-first", """
    <iframe src="/diagram.svg"></iframe>
    <img src="/diagram.svg">
    """)
  end

  test "a cross-site anchor does not open an svg fetched as a picture", context do
    page = context.url <> "/dir/page"
    scope = unique_scope("svg-picture-cross-site")
    root = Path.join(tmp(scope), "archive")
    picture = context.url2 <> "/pic.svg"
    html = ~s|<img src="#{picture}"><a href="#{picture}">D</a>|

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, html))
    expect_bytes(context.site2, "/pic.svg", "image/svg+xml", @svg)

    opts = crawl(page, context, root, scope, ["css", "js", "images"])
    export = ready_export(opts)
    assert Store.find_processed({picture, scope})
    refute Store.find({context.url2 <> "/icon.png", scope})
    assert read_resource(export, resource_for_url(export, picture)) == @svg
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
    root = Path.join(tmp(scope), "archive")
    svg = context.url <> "/diagram.svg"

    html = ~s|<img src="/diagram.svg"><iframe src="/diagram.svg"></iframe>|

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

    export = ready_export(opts)

    stored = flush_stored()
    assert Enum.count(stored, &match?({^svg, _}, &1)) == 1

    for path <- ["/icon.png", "/draw.js", "/paint.png", "/next.html"] do
      url = context.url <> path
      assert Store.find_processed({url, scope})
      assert Enum.count(stored, &match?({^url, _}, &1)) == 1
    end

    seed = resource_for_url(export, page)
    document = linked_resource(export, seed, "iframe", "src", svg)
    diagram = read_resource(export, document)
    refute diagram =~ ~s|href="icon.png"|
    refute diagram =~ "url(paint.png)"
    refute Crawler.running?(opts)
  end

  test "a document link does not wait for a picture that is not svg", context do
    {opts, scope, picture, seed, seed_key, fetch, fetch_key, picture_target} =
      held_picture(context, "photo.jpg", "image/jpeg", "JPEG")

    assert {:ok, document} =
             Crawler.crawl(
               picture,
               Map.merge(opts, %{
                 html_tag: "a",
                 reference_tag: "iframe",
                 page_open: false,
                 depth: 1
               })
             )

    document_target = document.target_handle
    refute document_target == picture_target

    assert {:terminal, %Crawler.Job.Outcome{status: :succeeded},
            %{target_handle: ^document_target}} =
             Store.await_direct(document_target, Crawler.Deadline.after_ms(2_000))

    assert Process.alive?(fetch)
    assert Store.target_outcome(picture_target) == nil
    assert %Crawler.Job.Outcome{status: :succeeded} = Store.target_outcome(document_target)

    assert %Page{processed: true, body: "JPEG", target_handle: ^document_target} =
             Store.find_processed({picture, scope})

    assert {:ok, %{ready?: false}} = Crawler.export_status(opts)
    send(fetch, {:managed_parser_release, fetch_key})
    send(seed, {:managed_parser_release, seed_key})
    export = ready_root(opts)
    resources = Enum.filter(export.manifest["resources"], &(&1["url"] == picture))
    assert resources != []
    for resource <- resources, do: assert(read_resource(export, resource) == "JPEG")
  end

  test "a document link waits until the picture fetch finishes", context do
    for path <- ["/icon.png", "/draw.js", "/paint.png"] do
      type = if path == "/draw.js", do: "text/javascript", else: "image/png"
      body = if path == "/draw.js", do: "js", else: "png"
      expect_bytes(context, path, type, body)
    end

    expect_html(context, "/next.html", "next")

    {opts, scope, svg, seed, seed_key, fetch, fetch_key, picture_target} =
      held_picture(context, "diagram.svg", "image/svg+xml", @svg_document)

    assert {:ok, document_admission} =
             Crawler.crawl(
               svg,
               Map.merge(opts, %{
                 html_tag: "a",
                 reference_tag: "iframe",
                 page_open: false,
                 depth: 1
               })
             )

    refute document_admission.target_handle == picture_target
    assert Store.target_outcome(picture_target) == nil
    assert Store.target_outcome(document_admission.target_handle) == nil
    refute_receive {:managed_parser_held, :document, _, _, _, _}, 200
    refute Store.find_processed({context.url <> "/next.html", scope})
    assert {:ok, %{ready?: false}} = Crawler.export_status(opts)
    send(fetch, {:managed_parser_release, fetch_key})

    assert_receive {:managed_parser_held, :document, document, "image/svg+xml", revision, target},
                   2_000

    assert is_reference(revision)
    assert target == document_admission.target_handle
    send(document, {:managed_parser_release, :document})
    send(seed, {:managed_parser_release, seed_key})
    export = ready_root(opts)

    for path <- ["/icon.png", "/draw.js", "/paint.png", "/next.html"] do
      assert Store.find_processed({context.url <> path, scope})
    end

    [resource] =
      Enum.filter(export.manifest["resources"], fn resource ->
        resource["url"] == svg and
          Enum.any?(export.manifest["references"], &(&1["from"] == resource["id"]))
      end)

    diagram = read_resource(export, resource)
    refute diagram == @svg_document
    refute diagram =~ ~s|href="icon.png"|
    refute diagram =~ ~s|href="draw.js"|
    refute diagram =~ "url(paint.png)"
    image = linked_resource(export, resource, "image", "href", context.url <> "/icon.png")
    assert read_resource(export, image) == "png"
  end

  defp held_picture(context, name, type, body) do
    scope = unique_scope("picture-held")
    root = Path.join(tmp(scope), "archive")
    on_exit(fn -> File.rm_rf(Path.dirname(root)) end)
    page = context.url <> "/dir/page"
    picture = context.url <> "/" <> name
    expect_html(context, "/dir/page", "<p>seed</p>")
    seed_key = make_ref()
    fetch_key = make_ref()
    observer = self()

    picture_gates =
      if type == "image/svg+xml" do
        ReqTestSite.expect_once(context.site, "GET", "/" <> name, fn conn ->
          send(observer, {:managed_picture_response_held, fetch_key, self()})

          receive do
            {:managed_parser_release, ^fetch_key} -> :ok
          end

          conn |> put_resp_header("content-type", type) |> resp(200, body)
        end)

        [{picture, "a", self(), :document}]
      else
        expect_bytes(context, "/" <> name, type, body)
        [{picture, "img", self(), fetch_key}]
      end

    assert {:ok, opts} =
             start_crawl(page,
               scope: scope,
               workers: 3,
               max_body: 1_048_576,
               max_analysis_bytes: 16_777_216,
               max_manifest_bytes: 4_194_304,
               retries: 0,
               max_depths: 3,
               assets: ["css", "js", "images"],
               store: Store,
               save_to: root,
               req_options: context.req_options,
               parser: Crawler.ManagedSnapshotHelpers.GateParser,
               managed_test_gates: [{page, "a", self(), seed_key}] ++ picture_gates
             )

    on_exit(fn -> Crawler.stop(opts) end)
    assert_receive {:managed_parser_held, ^seed_key, seed, _, _, _}, 2_000
    on_exit(fn -> send(seed, {:managed_parser_release, seed_key}) end)

    assert {:ok, picture_admission} =
             Crawler.crawl(
               picture,
               Map.merge(opts, %{html_tag: "img", reference_tag: "img", depth: 1})
             )

    picture_target = picture_admission.target_handle

    fetch =
      if type == "image/svg+xml" do
        assert_receive {:managed_picture_response_held, ^fetch_key, responder}, 2_000
        responder
      else
        assert_receive {:managed_parser_held, ^fetch_key, producer, ^type, _, ^picture_target},
                       2_000

        producer
      end

    on_exit(fn -> send(fetch, {:managed_parser_release, fetch_key}) end)
    {opts, scope, picture, seed, seed_key, fetch, fetch_key, picture_target}
  end

  defp linked_resource(export, source, selector, attribute, expected_url) do
    assert [href] =
             source
             |> then(&read_resource(export, &1))
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

  defp assert_registry_projection(page, url) do
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
           } = page

    assert is_reference(target)
  end

  defp assert_bounded_sources(opts) do
    state = :sys.get_state(Store)
    assert state.resources.used + state.source_cache_bytes <= opts.max_retained_bytes
  end

  defp assert_shared_document(context, label, html, extra \\ []) do
    page = context.url <> "/dir/page"
    scope = unique_scope(label)
    root = Path.join(tmp(scope), "archive")
    svg = context.url <> "/diagram.svg"

    ReqTestSite.expect_once(context.site, "GET", "/dir/page", &html(&1, html))
    expect_svg(context, "/diagram.svg", @svg_document, "image/svg+xml")
    expect_bytes(context, "/icon.png", "image/png", "png")
    expect_bytes(context, "/draw.js", "text/javascript", "js")
    expect_bytes(context, "/paint.png", "image/png", "png")
    expect_html(context, "/next.html", "next")

    opts =
      crawl(
        page,
        context,
        root,
        scope,
        ["css", "js", "images"],
        extra
      )

    for path <- ["/icon.png", "/draw.js", "/paint.png", "/next.html"] do
      assert Store.find_processed({context.url <> path, scope})
    end

    export = ready_export(opts)
    seed = resource_for_url(export, page)
    document = linked_resource(export, seed, "iframe", "src", svg)
    picture = linked_resource(export, seed, "img", "src", svg)
    diagram = read_resource(export, document)
    assert read_resource(export, picture) == @svg_document
    refute document["id"] == picture["id"]
    refute diagram =~ ~s|href="icon.png"|
    refute diagram =~ ~s|href="draw.js"|
    refute diagram =~ "url(paint.png)"

    for {selector, attribute, url, body} <- [
          {"image", "href", context.url <> "/icon.png", "png"},
          {"script", "href", context.url <> "/draw.js", "js"},
          {"a", "href", context.url <> "/next.html", <<0xEF, 0xBB, 0xBF>> <> "next"}
        ] do
      target = linked_resource(export, document, selector, attribute, url)
      assert read_resource(export, target) == body
    end

    if Keyword.get(extra, :store, Store) == nil do
      assert_registry_projection(Store.find({svg, scope}), svg)
      assert_registry_projection(Store.find({page, scope}), page)

      assert %Page{processed: true, body: nil, opts: nil, picture_type: "image/png"} =
               Store.find({context.url <> "/icon.png", scope})

      assert_bounded_sources(opts)
    end

    refute Crawler.running?(opts)
  end

  defp assert_redirected_document(context, label, extra) do
    page = context.url <> "/dir/page"
    scope = unique_scope(label)
    root = Path.join(tmp(scope), "archive")
    old = context.url <> "/old/diagram.svg"
    new = context.url <> "/new/diagram.svg"
    icon = context.url <> "/new/icon.png"
    html = ~s|<img src="/old/diagram.svg"><iframe src="/old/diagram.svg"></iframe>|

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

    opts =
      crawl(
        page,
        context,
        root,
        scope,
        ["css", "js", "images"],
        extra
      )

    for path <- ["/new/icon.png", "/new/draw.js", "/new/paint.png", "/new/next.html"] do
      assert Store.find_processed({context.url <> path, scope})
    end

    refute Store.find({context.url <> "/old/icon.png", scope})
    refute Store.find({context.url <> "/old/next.html", scope})
    export = ready_export(opts)
    seed = resource_for_url(export, page)
    document = linked_resource(export, seed, "iframe", "src", new)
    assert document["content_type"] == "image/svg+xml"
    target = linked_resource(export, document, "image", "href", icon)
    assert read_resource(export, target) == "png"

    assert Enum.any?(
             export.manifest["references"],
             &(&1["from"] == seed["id"] and &1["url"] == old and &1["target"] == document["id"])
           )

    if Keyword.get(extra, :store, Store) == nil do
      assert_registry_projection(Store.find({old, scope}), old)

      assert %Page{
               url: ^new,
               processed: true,
               body: nil,
               opts: nil,
               analysis: nil,
               interpretation: nil,
               source_revision: nil,
               credit: nil,
               target_handle: alias_target
             } = Store.find({new, scope})

      assert is_reference(alias_target)
      assert %Crawler.Job.Outcome{status: :succeeded} = Store.target_outcome(alias_target)
      authority = {scope, opts.generation, opts.queue}

      assert %{
               job: %Crawler.Job{id: ^alias_target, authority: ^authority, logical_key: ^old},
               outcome: %Crawler.Job.Outcome{status: :succeeded}
             } = :sys.get_state(Store).scheduler.frontier.jobs[alias_target]

      assert_bounded_sources(opts)
    end

    refute Crawler.running?(opts)
  end

  defp crawl(page, context, root, scope, assets, extra \\ []) do
    on_exit(fn -> File.rm_rf(Path.dirname(root)) end)

    settings =
      Map.merge(
        %{
          scope: scope,
          workers: 1,
          max_body: 1_048_576,
          max_analysis_bytes: 16_777_216,
          max_manifest_bytes: 16_777_216,
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
    ready_root(opts)
    opts
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
