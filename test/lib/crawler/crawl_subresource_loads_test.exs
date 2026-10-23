defmodule Crawler.CrawlSubresourceLoadsTest do
  use Crawler.TestCase, async: false

  import Plug.Conn
  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  test "an image submit button is fetched with images and left alone without them", context do
    page = context.url <> "/buttons"

    html = """
    <input type="image" src="/go.png" alt="Go">
    <input type="Image" src="/also.png">
    <input type="text" src="/nope.png">
    <input src="/also-nope.png">
    """

    expect_html(context, "/buttons", html)
    expect_bytes(context, "/go.png", "image/png", "go")
    expect_bytes(context, "/also.png", "image/png", "also")

    {opts, root} = run(page, context, assets: ["images"])

    try do
      saved = read_resource(root, resource_for_url(root, page))

      assert Store.find_processed({context.url <> "/go.png", opts.scope})
      assert Store.find_processed({context.url <> "/also.png", opts.scope})
      refute Store.find({context.url <> "/nope.png", opts.scope})
      refute Store.find({context.url <> "/also-nope.png", opts.scope})
      assert_points(saved, page, context.url <> "/go.png", root)
      assert_points(saved, page, context.url <> "/also.png", root)
      assert saved =~ ~s|src="/nope.png"|
      assert saved =~ ~s|src="/also-nope.png"|
    after
      Crawler.stop(opts)
    end

    quiet = context.url <> "/buttons-off"
    expect_html(context, "/buttons-off", html)
    {quiet_opts, quiet_root} = run(quiet, context, assets: [])
    quiet_saved = read_resource(quiet_root, resource_for_url(quiet_root, quiet))

    for path <- ["/go.png", "/also.png", "/nope.png", "/also-nope.png"] do
      refute Store.find({context.url <> path, quiet_opts.scope})
    end

    assert quiet_saved =~ ~s|src="/go.png"|
    assert quiet_saved =~ ~s|src="/also.png"|
    assert quiet_saved =~ ~s|src="/nope.png"|
    assert quiet_saved =~ ~s|src="/also-nope.png"|
  end

  test "audio and video preloads follow the images switch", context do
    page = context.url <> "/media"

    html = """
    <audio src="/clip.mp3"></audio>
    <video src="/film.mp4" poster="/poster.jpg"></video>
    <link rel="preload" as="audio" href="/preload.mp3">
    <link rel="preload" as="Video" href="/preload.mp4">
    """

    expect_html(context, "/media", html)
    expect_bytes(context, "/clip.mp3", "audio/mpeg", "clip")
    expect_bytes(context, "/film.mp4", "video/mp4", "film")
    expect_bytes(context, "/poster.jpg", "image/jpeg", "poster")
    expect_bytes(context, "/preload.mp3", "audio/mpeg", "preload-audio")
    expect_bytes(context, "/preload.mp4", "video/mp4", "preload-video")

    {opts, root} = run(page, context, assets: ["images"])

    try do
      saved = read_resource(root, resource_for_url(root, page))

      for path <- ["/clip.mp3", "/film.mp4", "/poster.jpg", "/preload.mp3", "/preload.mp4"] do
        assert Store.find_processed({context.url <> path, opts.scope})
        assert_points(saved, page, context.url <> path, root)
      end
    after
      Crawler.stop(opts)
    end

    quiet = context.url <> "/media-off"
    expect_html(context, "/media-off", html)
    {quiet_opts, quiet_root} = run(quiet, context, assets: [])
    quiet_saved = read_resource(quiet_root, resource_for_url(quiet_root, quiet))

    for path <- ["/clip.mp3", "/film.mp4", "/poster.jpg", "/preload.mp3", "/preload.mp4"] do
      refute Store.find({context.url <> path, quiet_opts.scope})
    end

    assert quiet_saved =~ ~s|src="/clip.mp3"|
    assert quiet_saved =~ ~s|src="/film.mp4"|
    assert quiet_saved =~ ~s|poster="/poster.jpg"|
    assert quiet_saved =~ ~s|href="/preload.mp3"|
    assert quiet_saved =~ ~s|href="/preload.mp4"|
  end

  test "a document preload is a page and a fetch preload is not", context do
    page = context.url <> "/documents"

    expect_html(context, "/documents", """
    <link rel="preload" as="document" href="/next">
    <link rel="preload" as="fetch" href="/notes.html">
    <link rel="preload" as="worker" href="/w.js">
    """)

    expect_html(context, "/next", ~s|<a href="/child">Child</a>|)
    expect_html(context, "/child", "child")

    {opts, root} = run(page, context, assets: [])

    assert Store.find_processed({context.url <> "/next", opts.scope})
    assert Store.find_processed({context.url <> "/child", opts.scope})

    for path <- ["/notes.html", "/secret", "/w.js", "/nope.js", "/dyn.js"] do
      refute Store.find({context.url <> path, opts.scope})
    end

    assert_points(
      read_resource(root, resource_for_url(root, page)),
      page,
      context.url <> "/next",
      root
    )

    assert_link_opens(
      root,
      resource_for_url(root, context.url <> "/next"),
      reference_target(
        root,
        resource_for_url(root, context.url <> "/next"),
        context.url <> "/child"
      )
    )
  end

  test "a worker preload is a classic script when scripts are on", context do
    page = context.url <> "/workers"
    script = context.url <> "/w.js"
    notes = context.url <> "/notes.html"

    expect_html(context, "/workers", """
    <link rel="preload" as="document" href="/next">
    <link rel="preload" as="fetch" href="/notes.html">
    <link rel="preload" as="worker" href="/w.js">
    """)

    expect_html(context, "/next", ~s|<a href="/child">Child</a>|)
    expect_html(context, "/child", "child")

    expect_html(context, "/notes.html", ~s|<a href="/secret">Secret</a>|)

    expect_bytes(
      context,
      "/w.js",
      "application/javascript",
      ~s|import "./nope.js";\nimport("./dyn.js");\n|
    )

    expect_bytes(context, "/dyn.js", "application/javascript", "export {}\n")

    {opts, root} = run(page, context, assets: ["js"])
    saved = read_resource(root, resource_for_url(root, page))
    worker = read_resource(root, reference_target(root, resource_for_url(root, page), script))

    for path <- ["/next", "/child", "/notes.html", "/w.js", "/dyn.js"] do
      assert Store.find_processed({context.url <> path, opts.scope})
    end

    refute Store.find({context.url <> "/nope.js", opts.scope})
    refute Store.find({context.url <> "/secret", opts.scope})
    assert_points(saved, page, script, root)

    assert_link_opens(
      root,
      reference_target(root, resource_for_url(root, page), script),
      reference_target(
        root,
        reference_target(root, resource_for_url(root, page), script),
        context.url <> "/dyn.js"
      )
    )

    assert worker =~ ~s|import "./nope.js"|

    assert read_resource(root, reference_target(root, resource_for_url(root, page), notes)) =~
             ~s|href="/secret"|
  end

  test "paint and audio worklets are modules and ignore the page import map", context do
    page = context.url <> "/worklets"
    paint = context.url <> "/paint.js"
    proc = context.url <> "/proc.js"

    expect_html(context, "/worklets", """
    <script type="importmap">{"imports":{"vue":"/vue.js"}}</script>
    <script>
    CSS.paintWorklet.addModule("./paint.js");
    audio.audioWorklet.addModule(new URL("./proc.js", import.meta.url));
    loader.addModule("./nope.js");
    fetch("./nope.png");
    import.meta.resolve("./nope.png");
    </script>
    """)

    expect_bytes(
      context,
      "/paint.js",
      "application/javascript",
      ~s|import "vue";\nimport "./local.js";\n|
    )

    expect_bytes(context, "/proc.js", "application/javascript", ~s|import "./other.js";\n|)
    expect_bytes(context, "/local.js", "application/javascript", "export {}\n")
    expect_bytes(context, "/other.js", "application/javascript", "export {}\n")

    {opts, root} = run(page, context, assets: ["js"])
    saved = read_resource(root, resource_for_url(root, page))
    paint_body = read_resource(root, reference_target(root, resource_for_url(root, page), paint))

    for path <- ["/paint.js", "/local.js", "/proc.js", "/other.js"] do
      assert Store.find_processed({context.url <> path, opts.scope})
    end

    for path <- ["/vue.js", "/nope.js", "/nope.png"] do
      refute Store.find({context.url <> path, opts.scope})
    end

    assert_points(saved, page, paint, root)
    assert_points(saved, page, proc, root)
    assert saved =~ ~s|loader.addModule("./nope.js")|
    assert saved =~ ~s|fetch("./nope.png")|
    assert saved =~ ~s|import.meta.resolve("./nope.png")|
    assert paint_body =~ ~s|import "vue"|

    assert_link_opens(
      root,
      reference_target(root, resource_for_url(root, page), paint),
      reference_target(
        root,
        reference_target(root, resource_for_url(root, page), paint),
        context.url <> "/local.js"
      )
    )

    assert_link_opens(
      root,
      reference_target(root, resource_for_url(root, page), proc),
      reference_target(
        root,
        reference_target(root, resource_for_url(root, page), proc),
        context.url <> "/other.js"
      )
    )
  end

  test "a worklet preload is a module only when scripts are on", context do
    page = context.url <> "/worklet-preload"

    html = """
    <script type="importmap">{"imports":{"vue":"/vue.js"}}</script>
    <link rel="preload" as="paintworklet" href="/paint.js">
    <link rel="preload" as="audioworklet" href="/heard.js">
    """

    expect_html(context, "/worklet-preload", html)

    expect_bytes(
      context,
      "/paint.js",
      "application/javascript",
      ~s|import "vue";\nimport "./local.js";\n|
    )

    expect_bytes(
      context,
      "/heard.js",
      "application/javascript",
      ~s|import "vue";\nimport "./heard-dep.js";\n|
    )

    expect_bytes(context, "/local.js", "application/javascript", "export {}\n")
    expect_bytes(context, "/heard-dep.js", "application/javascript", "export {}\n")

    {opts, root} = run(page, context, assets: ["js"])

    try do
      for path <- ["/paint.js", "/local.js", "/heard.js", "/heard-dep.js"] do
        assert Store.find_processed({context.url <> path, opts.scope})
      end

      refute Store.find({context.url <> "/vue.js", opts.scope})

      assert_link_opens(
        root,
        reference_target(root, resource_for_url(root, page), context.url <> "/paint.js"),
        reference_target(
          root,
          reference_target(root, resource_for_url(root, page), context.url <> "/paint.js"),
          context.url <> "/local.js"
        )
      )

      assert_link_opens(
        root,
        reference_target(root, resource_for_url(root, page), context.url <> "/heard.js"),
        reference_target(
          root,
          reference_target(root, resource_for_url(root, page), context.url <> "/heard.js"),
          context.url <> "/heard-dep.js"
        )
      )

      assert read_resource(
               root,
               reference_target(root, resource_for_url(root, page), context.url <> "/paint.js")
             ) =~
               ~s|import "vue"|
    after
      Crawler.stop(opts)
    end

    quiet = context.url <> "/worklet-preload-off"
    expect_html(context, "/worklet-preload-off", html)
    {quiet_opts, quiet_root} = run(quiet, context, assets: [])
    quiet_saved = read_resource(quiet_root, resource_for_url(quiet_root, quiet))

    for path <- ["/paint.js", "/local.js", "/heard.js", "/heard-dep.js", "/vue.js"] do
      refute Store.find({context.url <> path, quiet_opts.scope})
    end

    assert quiet_saved =~ ~s|href="/paint.js"|
    assert quiet_saved =~ ~s|href="/heard.js"|
  end

  test "css image() fetches quoted files and leaves a colour and a data image", context do
    page = context.url <> "/styled"
    sheet = context.url <> "/app.css"

    css = """
    div { background: image("wide.png"); }
    div { background: image(ltr "left.png", #ccc); }
    div { background: image(url("already.png")); }
    div { background: image("data:image/png,aaa"); }
    div { background: image-set("set.png" 1x); }
    """

    expect_html(context, "/styled", ~s|<link rel="stylesheet" href="/app.css">|)
    expect_bytes(context, "/app.css", "text/css", css)
    expect_bytes(context, "/wide.png", "image/png", "wide")
    expect_bytes(context, "/left.png", "image/png", "left")
    expect_bytes(context, "/already.png", "image/png", "already")
    expect_bytes(context, "/set.png", "image/png", "set")

    {opts, root} = run(page, context, assets: ["css"])
    saved = read_resource(root, reference_target(root, resource_for_url(root, page), sheet))

    for path <- ["/app.css", "/wide.png", "/left.png", "/already.png", "/set.png"] do
      assert Store.find_processed({context.url <> path, opts.scope})
    end

    for path <- ["/wide.png", "/left.png", "/already.png", "/set.png"] do
      assert_points(saved, sheet, context.url <> path, root)
    end

    assert saved =~ "data:image/png,aaa"
    assert saved =~ "#ccc"
  end

  test "older touch icons follow the images switch", context do
    page = context.url <> "/icons"

    html = """
    <link rel="apple-touch-icon" href="/touch.png">
    <link rel="apple-touch-icon-precomposed" href="/precomposed.png">
    <link rel="apple-touch-startup-image" href="/splash.png">
    <link rel="canonical" href="/canon">
    """

    expect_html(context, "/icons", html)
    expect_bytes(context, "/touch.png", "image/png", "touch")
    expect_bytes(context, "/precomposed.png", "image/png", "precomposed")
    expect_bytes(context, "/splash.png", "image/png", "splash")

    {opts, root} = run(page, context, assets: ["images"])

    try do
      saved = read_resource(root, resource_for_url(root, page))

      for path <- ["/touch.png", "/precomposed.png", "/splash.png"] do
        assert Store.find_processed({context.url <> path, opts.scope})
        assert_points(saved, page, context.url <> path, root)
      end

      refute Store.find({context.url <> "/canon", opts.scope})
      assert saved =~ ~s|href="/canon"|
    after
      Crawler.stop(opts)
    end

    quiet = context.url <> "/icons-off"
    expect_html(context, "/icons-off", html)
    {quiet_opts, quiet_root} = run(quiet, context, assets: [])
    quiet_saved = read_resource(quiet_root, resource_for_url(quiet_root, quiet))

    for path <- ["/touch.png", "/precomposed.png", "/splash.png", "/canon"] do
      refute Store.find({context.url <> path, quiet_opts.scope})
    end

    assert quiet_saved =~ ~s|href="/touch.png"|
    assert quiet_saved =~ ~s|href="/precomposed.png"|
    assert quiet_saved =~ ~s|href="/splash.png"|
    assert quiet_saved =~ ~s|href="/canon"|
  end

  test "a fragment css url and a namespace name are not fetched", context do
    page = context.url <> "/dir/page"
    sheet = context.url <> "/dir/app.css"

    html = """
    <link rel="stylesheet" href="/dir/app.css">
    <style>div { filter: url(#blur); background: url("paint.png"); }</style>
    <div style="filter: url(#blur)"></div>
    <style>div { filter: url("#blur"); background: url('#blur'); }</style>
    <div style="filter: url( #blur )"></div>
    <style>div { background: url("sprite.svg#icon"); }</style>
    <svg>
      <style>g { fill: url(#metal); background: url("paint.png"); }</style>
      <rect fill="url(#shine)"></rect>
    </svg>
    """

    css = """
    @namespace svg url("http://www.w3.org/2000/svg");
    @namespace url('http://www.w3.org/2000/svg');
    @namespace url(http://www.w3.org/2000/svg);
    @namespace "http://www.w3.org/1999/xhtml";
    svg|a { filter: url(#blur); background: url("paint.png"); }
    div { filter: url("#blur"); background: url('#blur'); }
    div { filter: url( #blur ); }
    """

    expect_html(context, "/dir/page", html)
    expect_bytes(context, "/dir/app.css", "text/css", css)
    expect_bytes(context, "/dir/paint.png", "image/png", "paint")
    expect_bytes(context, "/dir/sprite.svg", "image/svg+xml", "<svg></svg>")

    {opts, root} = run(page, context, assets: ["css"])
    saved = read_resource(root, resource_for_url(root, page))
    css_saved = read_resource(root, reference_target(root, resource_for_url(root, page), sheet))

    for path <- ["/dir/app.css", "/dir/paint.png", "/dir/sprite.svg"] do
      assert Store.find_processed({context.url <> path, opts.scope})
    end

    assert_points(saved, page, context.url <> "/dir/paint.png", root)
    assert_points(saved, page, context.url <> "/dir/sprite.svg", root, "#icon")
    stylesheet = reference_target(root, resource_for_url(root, page), sheet)
    paint = reference_target(root, stylesheet, context.url <> "/dir/paint.png")
    [_, href] = Regex.run(~r/background: url\("([^"]+)"\)/, css_saved)
    assert_opens(root, stylesheet, paint, href)
    assert read_resource(root, paint) == "paint"

    assert saved =~ "url(#blur)"
    assert saved =~ ~s|style="filter: url(#blur)"|
    assert saved =~ ~s|url("#blur")|
    assert saved =~ "url('#blur')"
    assert saved =~ "url( #blur )"
    assert saved =~ "url(#metal)"
    assert saved =~ ~s|fill="url(#shine)"|
    refute saved =~ ~s|url("paint.png")|
    refute saved =~ ~s|url("sprite.svg#icon")|

    assert css_saved =~ ~s|url("http://www.w3.org/2000/svg")|
    assert css_saved =~ "url('http://www.w3.org/2000/svg')"
    assert css_saved =~ "url(http://www.w3.org/2000/svg)"
    assert css_saved =~ ~s|@namespace "http://www.w3.org/1999/xhtml"|
    assert css_saved =~ "svg|a"
    assert css_saved =~ "url(#blur)"
    assert css_saved =~ ~s|url("#blur")|
    assert css_saved =~ "url('#blur')"
    assert css_saved =~ "url( #blur )"
    refute css_saved =~ ~s|url("paint.png")|
  end

  test "an html image tag is fetched like an img", context do
    page = context.url <> "/dir/page"

    html = """
    <image href="not-a-picture.svg" src="photo.png" srcset="photo-2x.png 2x">
    <img src="real.png">
    <svg><image src="nope.png" href="sprite.svg"/></svg>
    """

    expect_html(context, "/dir/page", html)
    expect_bytes(context, "/dir/photo.png", "image/png", "photo")
    expect_bytes(context, "/dir/photo-2x.png", "image/png", "photo2")
    expect_bytes(context, "/dir/real.png", "image/png", "real")
    expect_bytes(context, "/dir/sprite.svg", "image/svg+xml", "<svg></svg>")

    {opts, root} = run(page, context, assets: ["images"])

    try do
      saved = read_resource(root, resource_for_url(root, page))

      for path <- ["/dir/photo.png", "/dir/photo-2x.png", "/dir/real.png", "/dir/sprite.svg"] do
        assert Store.find_processed({context.url <> path, opts.scope})
        assert_points(saved, page, context.url <> path, root)
      end

      refute Store.find({context.url <> "/dir/nope.png", opts.scope})
      refute Store.find({context.url <> "/dir/not-a-picture.svg", opts.scope})
      assert saved =~ "<image"
      assert saved =~ ~s|href="not-a-picture.svg"|
      assert saved =~ ~s|src="nope.png"|
      refute saved =~ ~s|src="photo.png"|
      refute saved =~ ~s|srcset="photo-2x.png 2x"|
      refute saved =~ ~s|src="real.png"|
      refute saved =~ ~s|href="sprite.svg"|
    after
      Crawler.stop(opts)
    end

    quiet = context.url <> "/dir/pictures-off"
    expect_html(context, "/dir/pictures-off", html)
    {quiet_opts, quiet_root} = run(quiet, context, assets: [])
    quiet_saved = read_resource(quiet_root, resource_for_url(quiet_root, quiet))

    for path <- [
          "/dir/photo.png",
          "/dir/photo-2x.png",
          "/dir/real.png",
          "/dir/sprite.svg",
          "/dir/nope.png"
        ] do
      refute Store.find({context.url <> path, quiet_opts.scope})
    end

    assert quiet_saved =~ ~s|src="photo.png"|
    assert quiet_saved =~ "photo-2x.png"
    assert quiet_saved =~ ~s|src="real.png"|
    assert quiet_saved =~ ~s|href="sprite.svg"|
  end

  test "a legacy background attribute is fetched as an image", context do
    page = context.url <> "/start"
    names = ~w(bg.jpg table.png head.png body.png row.png cell.png heading.png foot.png)

    html = """
    <base href="#{context.url}/blog/">
    <body bgcolor="red" background="bg.jpg" alink="navy">
    <table background="table.png"><thead background="head.png"></thead>
    <tbody background="body.png"><tr background="row.png">
    <td background="cell.png"></td><th background="heading.png"></th>
    </tr></tbody><tfoot background="foot.png"></tfoot></table>
    <div background="nope.png"></div>
    </body>
    """

    expect_html(context, "/start", html)

    for name <- names do
      expect_bytes(context, "/blog/" <> name, "image/png", name)
    end

    {opts, root} = run(page, context, assets: ["images"])

    try do
      saved = read_resource(root, resource_for_url(root, page))

      for name <- names do
        url = context.url <> "/blog/" <> name
        assert Store.find_processed({url, opts.scope})
        assert_points(saved, page, url, root)
        refute saved =~ ~s|background="#{name}"|
      end

      assert saved =~ ~s|bgcolor="red"|
      assert saved =~ ~s|alink="navy"|
      assert saved =~ ~s|background="nope.png"|

      for path <- ["/blog/red", "/blog/navy", "/blog/nope.png", "/red", "/navy", "/nope.png"] do
        refute Store.find({context.url <> path, opts.scope})
      end
    after
      Crawler.stop(opts)
    end

    quiet = context.url <> "/plain"
    expect_html(context, "/plain", html)
    {quiet_opts, quiet_root} = run(quiet, context, assets: [])
    quiet_saved = read_resource(quiet_root, resource_for_url(quiet_root, quiet))

    for name <- names do
      refute Store.find({context.url <> "/blog/" <> name, quiet_opts.scope})
      assert quiet_saved =~ ~s|background="#{name}"|
    end

    assert quiet_saved =~ ~s|bgcolor="red"|
    assert quiet_saved =~ ~s|background="nope.png"|
  end

  defp run(page, context, extra) do
    scope = extra[:scope] || unique_scope("subresource")
    root = Path.join(tmp(), scope <> "-#{Base.encode16(:crypto.strong_rand_bytes(6))}")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, opts} =
      start_crawl(
        page,
        Keyword.merge(
          [
            scope: scope,
            workers: 1,
            max_body: 1_048_576,
            max_analysis_bytes: 16_000_000,
            max_css_work: 5_000,
            max_css_pictures: 1_000,
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
    {opts, ready_export(opts)}
  end

  defp expect_html(context, path, body) do
    ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
      conn
      |> put_resp_header("content-type", "text/html")
      |> resp(200, body)
    end)
  end

  defp expect_bytes(context, path, type, body) do
    ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
      conn
      |> put_resp_header("content-type", type)
      |> resp(200, body)
    end)
  end
end
