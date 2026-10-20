defmodule Crawler.CrawlSubresourceLoadsTest do
  use Crawler.TestCase, async: false

  import Plug.Conn
  import Crawler.SnapshotHelpers

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
    saved = File.read!(saved(root, page))

    assert Store.find_processed({context.url <> "/go.png", opts.scope})
    assert Store.find_processed({context.url <> "/also.png", opts.scope})
    refute Store.find({context.url <> "/nope.png", opts.scope})
    refute Store.find({context.url <> "/also-nope.png", opts.scope})
    assert_points(saved, page, context.url <> "/go.png", root)
    assert_points(saved, page, context.url <> "/also.png", root)
    assert saved =~ ~s|src="/nope.png"|
    assert saved =~ ~s|src="/also-nope.png"|

    quiet = context.url <> "/buttons-off"
    expect_html(context, "/buttons-off", html)
    {quiet_opts, quiet_root} = run(quiet, context, assets: [])
    quiet_saved = File.read!(saved(quiet_root, quiet))

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
    saved = File.read!(saved(root, page))

    for path <- ["/clip.mp3", "/film.mp4", "/poster.jpg", "/preload.mp3", "/preload.mp4"] do
      assert Store.find_processed({context.url <> path, opts.scope})
      assert_points(saved, page, context.url <> path, root)
    end

    quiet = context.url <> "/media-off"
    expect_html(context, "/media-off", html)
    {quiet_opts, quiet_root} = run(quiet, context, assets: [])
    quiet_saved = File.read!(saved(quiet_root, quiet))

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

    assert_points(File.read!(saved(root, page)), page, context.url <> "/next", root)
    assert_link_opens(root, context.url <> "/next", context.url <> "/child")
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
    saved = File.read!(saved(root, page))
    worker = File.read!(saved(root, script))

    for path <- ["/next", "/child", "/notes.html", "/w.js", "/dyn.js"] do
      assert Store.find_processed({context.url <> path, opts.scope})
    end

    refute Store.find({context.url <> "/nope.js", opts.scope})
    refute Store.find({context.url <> "/secret", opts.scope})
    assert_points(saved, page, script, root)
    assert_link_opens(root, script, context.url <> "/dyn.js")
    assert worker =~ ~s|import "./nope.js"|
    assert File.read!(saved(root, notes)) =~ ~s|href="/secret"|
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
    saved = File.read!(saved(root, page))
    paint_body = File.read!(saved(root, paint))

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
    assert_link_opens(root, paint, context.url <> "/local.js")
    assert_link_opens(root, proc, context.url <> "/other.js")
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

    for path <- ["/paint.js", "/local.js", "/heard.js", "/heard-dep.js"] do
      assert Store.find_processed({context.url <> path, opts.scope})
    end

    refute Store.find({context.url <> "/vue.js", opts.scope})
    assert_link_opens(root, context.url <> "/paint.js", context.url <> "/local.js")
    assert_link_opens(root, context.url <> "/heard.js", context.url <> "/heard-dep.js")
    assert File.read!(saved(root, context.url <> "/paint.js")) =~ ~s|import "vue"|

    quiet = context.url <> "/worklet-preload-off"
    expect_html(context, "/worklet-preload-off", html)
    {quiet_opts, quiet_root} = run(quiet, context, assets: [])
    quiet_saved = File.read!(saved(quiet_root, quiet))

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
    saved = File.read!(saved(root, sheet))

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
    saved = File.read!(saved(root, page))

    for path <- ["/touch.png", "/precomposed.png", "/splash.png"] do
      assert Store.find_processed({context.url <> path, opts.scope})
      assert_points(saved, page, context.url <> path, root)
    end

    refute Store.find({context.url <> "/canon", opts.scope})
    assert saved =~ ~s|href="/canon"|

    quiet = context.url <> "/icons-off"
    expect_html(context, "/icons-off", html)
    {quiet_opts, quiet_root} = run(quiet, context, assets: [])
    quiet_saved = File.read!(saved(quiet_root, quiet))

    for path <- ["/touch.png", "/precomposed.png", "/splash.png", "/canon"] do
      refute Store.find({context.url <> path, quiet_opts.scope})
    end

    assert quiet_saved =~ ~s|href="/touch.png"|
    assert quiet_saved =~ ~s|href="/precomposed.png"|
    assert quiet_saved =~ ~s|href="/splash.png"|
    assert quiet_saved =~ ~s|href="/canon"|
  end

  defp run(page, context, extra) do
    scope = extra[:scope] || unique_scope("subresource")
    root = tmp(scope)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, opts} =
      start_crawl(
        page,
        Keyword.merge(
          [
            scope: scope,
            workers: 1,
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
    wait(5_000, fn -> refute Crawler.running?(opts) end)
    {opts, root}
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
