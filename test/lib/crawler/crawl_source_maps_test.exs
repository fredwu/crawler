defmodule Crawler.CrawlSourceMapsTest do
  use Crawler.TestCase, async: false

  import Crawler.SnapshotHelpers

  alias Crawler.Linker
  alias Crawler.Store

  @decoy_js ~S"""
  var s = "//# sourceMappingURL=fake.js.map";
  var t = `//# sourceMappingURL=fake.js.map`;
  var r = /\/\/# sourceMappingURL=fake.js.map/;
  /* note //# sourceMappingURL=fake.js.map */
  //@ sourceMappingURL=legacy.js.map
  /*# sourceMappingURL=real.js.map */
  """

  @decoy_css ~S"""
  content: "/*# sourceMappingURL=fake.css.map */";
  //# sourceMappingURL=nope.css.map
  /*@ sourceMappingURL=old.css.map */
  /*# sourceMappingURL=real.css.map */
  """

  setup do
    scope = unique_scope("source-maps")
    root = tmp(scope)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, scope: scope, root: root}
  end

  test "the last real JavaScript note wins after a redirect", context do
    url = context.url
    page = url <> "/page"
    script = url <> "/base/app.js"
    landed = url <> "/cdn/app.js"
    map = url <> "/cdn/real.js.map"

    html(context.site, "/page", """
    <base href="/base/">
    <script src="app.js"></script>
    """)

    redirect(context.site, "/base/app.js", landed)
    js(context.site, "/cdn/app.js", @decoy_js)
    map(context.site, "/cdn/real.js.map", ~s|{"version":3,"mappings":""}|)

    crawl(page, context, ["js"])

    saved = File.read!(saved(context.root, script))
    href = offline(script, map)
    assert occurrences(saved, "fake.js.map") == 4
    assert occurrences(saved, "legacy.js.map") == 1
    assert String.contains?(saved, "/*# sourceMappingURL=#{href} */")
    assert_link_opens(context.root, script, map)
    refute_stored(context, [url <> "/base/real.js.map", url <> "/cdn/legacy.js.map"])
  end

  test "an inline sourceURL is only a base for its map", context do
    url = context.url
    page = url <> "/page"
    generated = url <> "/assets/generated/app.js.map"
    plain = url <> "/assets/plain.js.map"

    html(context.site, "/page", """
    <base href="/assets/">
    <script>
    //# sourceURL=generated/app.js
    //# sourceMappingURL=app.js.map
    </script>
    <script>
    //# sourceMappingURL=plain.js.map
    </script>
    """)

    map(context.site, "/assets/generated/app.js.map", ~s|{"version":3,"mappings":""}|)
    map(context.site, "/assets/plain.js.map", ~s|{"version":3,"mappings":""}|)

    crawl(page, context, ["js"])

    body = File.read!(saved(context.root, page))
    assert String.contains?(body, "//# sourceMappingURL=#{offline(page, generated)}")
    assert String.contains?(body, "//# sourceMappingURL=#{offline(page, plain)}")
    assert_link_opens(context.root, page, generated)
    assert_link_opens(context.root, page, plain)
    refute_stored(context, [url <> "/assets/generated/app.js"])
  end

  test "stylesheets and style elements keep the last block-comment map", context do
    url = context.url
    page = url <> "/page"
    sheet = url <> "/css/app.css"
    landed = url <> "/cdn/app.css"
    map = url <> "/cdn/real.css.map"
    inline = url <> "/assets/inline.css.map"

    html(context.site, "/page", """
    <base href="/assets/">
    <link rel="stylesheet" href="/css/app.css">
    <style>/*# sourceMappingURL=inline.css.map */</style>
    """)

    redirect(context.site, "/css/app.css", landed)
    css(context.site, "/cdn/app.css", @decoy_css)
    map(context.site, "/cdn/real.css.map", ~s|{"version":3,"mappings":""}|)
    map(context.site, "/assets/inline.css.map", ~s|{"version":3,"mappings":""}|)

    crawl(page, context, ["css"])

    saved = File.read!(saved(context.root, sheet))
    assert String.contains?(saved, "fake.css.map")
    assert String.contains?(saved, "//# sourceMappingURL=nope.css.map")
    assert String.contains?(saved, "/*@ sourceMappingURL=old.css.map */")
    assert String.contains?(saved, "/*# sourceMappingURL=#{offline(sheet, map)} */")
    assert_link_opens(context.root, sheet, map)
    assert_link_opens(context.root, page, inline)
  end

  test "a SourceMap header wins and a page header does not name an inline map", context do
    url = context.url
    page = url <> "/page"
    script = url <> "/app.js"
    sheet = url <> "/app.css"
    header = url <> "/header.js.map"
    sheet_map = url <> "/sheet.css.map"

    html(
      context.site,
      "/page",
      """
      <script>var x = 1;</script>
      <style>body{margin:0}</style>
      <script src="/app.js"></script>
      <link rel="stylesheet" href="/app.css">
      """,
      [{"SourceMap", "page.js.map"}]
    )

    js(
      context.site,
      "/app.js",
      "var a = 1;\n//# sourceMappingURL=comment.js.map\n",
      [{"SourceMap", "header.js.map"}, {"X-SourceMap", "older.js.map"}]
    )

    css(context.site, "/app.css", "h1{color:red}", [{"X-SourceMap", "sheet.css.map"}])
    map(context.site, "/header.js.map", ~s|{"version":3,"mappings":""}|)
    map(context.site, "/sheet.css.map", ~s|{"version":3,"mappings":""}|)

    crawl(page, context, ["js", "css"])

    saved = File.read!(saved(context.root, script))
    assert String.starts_with?(saved, "var a = 1;")
    assert String.contains?(saved, "//# sourceMappingURL=#{offline(script, header)}")
    refute String.contains?(saved, "comment.js.map")
    refute String.contains?(saved, "older.js.map")
    assert_link_opens(context.root, script, header)

    sheet_body = File.read!(saved(context.root, sheet))
    assert sheet_body == "h1{color:red}\n/*# sourceMappingURL=#{offline(sheet, sheet_map)} */"
    assert_link_opens(context.root, sheet, sheet_map)
  end

  test "a map saves fetched sources and an empty sourceRoot stays beside the map", context do
    url = context.url
    page = url <> "/page"
    script = url <> "/js/app.js"
    map = url <> "/maps/app.js.map"
    empty_map = url <> "/maps/empty.js.map"
    lib = context.url2 <> "/lib.ts"
    absolute = url <> "/abs.ts"
    beside = url <> "/maps/app.ts"

    html(context.site, "/page", """
    <script src="/js/app.js"></script>
    <script src="/js/empty.js"></script>
    """)

    js(context.site, "/js/app.js", "//# sourceMappingURL=/maps/app.js.map\n")
    js(context.site, "/js/empty.js", "//# sourceMappingURL=/maps/empty.js.map\n")

    map(context.site, "/maps/app.js.map", """
    {"version":3,"file":"https://no.test/file.ts","sourceRoot":"../src","sources":["app.ts","/abs.ts","#{lib}","webpack://app/boot.ts"],"sourcesContent":["embedded app source",null],"mappings":"https://no.test/nope.ts","names":["https://no.test/name.ts"]}
    """)

    map(
      context.site,
      "/maps/empty.js.map",
      ~s|{"version":3,"sourceRoot":"","sources":["app.ts"],"mappings":""}|
    )

    text(context.site2, "/lib.ts", "let lib = 1;\n")
    text(context.site, "/abs.ts", "let abs = 1;\n")
    text(context.site, "/maps/app.ts", "let beside = 1;\n")

    crawl(page, context, ["js"])

    saved = File.read!(saved(context.root, map))
    assert String.contains?(saved, ~s("sourceRoot":""))
    refute String.contains?(saved, ~s("sourceRoot":"../src"))
    assert String.contains?(saved, "embedded app source")
    assert String.contains?(saved, "https://no.test/nope.ts")
    assert String.contains?(saved, "https://no.test/name.ts")
    assert String.contains?(saved, "https://no.test/file.ts")
    assert String.contains?(saved, "webpack://app/boot.ts")
    assert String.contains?(saved, "\"app.ts\"")
    assert_link_opens(context.root, map, lib)
    assert_link_opens(context.root, map, absolute)
    assert_link_opens(context.root, script, map)
    assert_link_opens(context.root, empty_map, beside)
    refute_stored(context, [url <> "/app.ts", url <> "/src/app.ts"])
  end

  test "index maps, data maps, and rejected maps", context do
    url = context.url
    page = url <> "/page"
    index_js = url <> "/js/index.js"
    data_js = url <> "/js/data.js"
    old_js = url <> "/js/old.js"
    bad_js = url <> "/js/bad.js"
    index_map = url <> "/maps/index.js.map"
    part = url <> "/maps/part.js.map"
    part_source = url <> "/maps/part.ts"
    inline = url <> "/maps/inline.ts"
    app = url <> "/js/src/app.ts"
    old_map = url <> "/maps/old.js.map"
    bad_map = url <> "/maps/bad.js.map"

    html(context.site, "/page", """
    <script src="/js/index.js"></script>
    <script src="/js/data.js"></script>
    <script src="/js/old.js"></script>
    <script src="/js/bad.js"></script>
    """)

    js(context.site, "/js/index.js", "//# sourceMappingURL=/maps/index.js.map\n")

    js(context.site, "/js/data.js", """
    //# sourceMappingURL=data:application/json;charset=utf-8,{"version":3,"sources":["src/app.ts"],"mappings":""}
    """)

    js(context.site, "/js/old.js", "//# sourceMappingURL=/maps/old.js.map\n")
    js(context.site, "/js/bad.js", "//# sourceMappingURL=/maps/bad.js.map\n")

    map(context.site, "/maps/index.js.map", """
    {"version":3,"sources":["ignored.ts"],"sections":[{"url":"part.js.map"},{"map":{"version":3,"sources":["inline.ts"],"mappings":""}}]}
    """)

    map(
      context.site,
      "/maps/part.js.map",
      ~s|{"version":3,"sources":["part.ts"],"mappings":""}|
    )

    map(context.site, "/maps/old.js.map", ~s|{"version":2,"sources":["nope.ts"],"mappings":""}|)
    text(context.site, "/maps/bad.js.map", "not json")
    text(context.site, "/maps/part.ts", "let part = 1;\n")
    text(context.site, "/maps/inline.ts", "let inline = 1;\n")
    text(context.site, "/js/src/app.ts", "let app = 1;\n")

    crawl(page, context, ["js"])

    assert_link_opens(context.root, index_js, index_map)
    assert_link_opens(context.root, index_map, part)
    assert_link_opens(context.root, index_map, inline)
    assert_link_opens(context.root, part, part_source)
    assert_link_opens(context.root, old_js, old_map)
    assert_link_opens(context.root, bad_js, bad_map)

    saved = File.read!(saved(context.root, data_js))
    assert String.contains?(saved, "sourceMappingURL=data:application/json;charset=utf-8,")

    [payload] =
      Regex.run(~r/sourceMappingURL=data:application\/json;charset=utf-8,(\S+)/, saved,
        capture: :all_but_first
      )

    decoded = URI.decode(payload)
    assert String.contains?(decoded, offline(data_js, app))

    assert File.read!(
             Path.expand(
               link_path(offline(data_js, app)),
               Path.dirname(saved(context.root, data_js))
             )
           ) ==
             File.read!(saved(context.root, app))

    refute_stored(context, [
      url <> "/maps/ignored.ts",
      url <> "/maps/nope.ts",
      url <> "/js/nope.ts",
      url <> "/part.ts",
      url <> "/js/part.ts"
    ])
  end

  test "a redirected script resolves a relative SourceMap header from the landed URL", context do
    url = context.url
    page = url <> "/page"
    script = url <> "/base/app.js"
    landed = url <> "/cdn/app.js"
    map = url <> "/cdn/app.js.map"

    html(context.site, "/page", """
    <base href="/assets/">
    <script src="/base/app.js"></script>
    """)

    redirect(context.site, "/base/app.js", landed)
    js(context.site, "/cdn/app.js", "var a = 1;\n", [{"SourceMap", "app.js.map"}])
    map(context.site, "/cdn/app.js.map", ~s|{"version":3,"mappings":""}|)

    crawl(page, context, ["js"])

    saved = File.read!(saved(context.root, script))
    assert String.contains?(saved, "//# sourceMappingURL=#{offline(script, map)}")
    assert_link_opens(context.root, script, map)

    refute_stored(context, [
      url <> "/base/app.js.map",
      url <> "/assets/app.js.map",
      url <> "/app.js.map"
    ])
  end

  defp crawl(url, context, assets) do
    {:ok, opts} =
      start_crawl(
        url,
        scope: context.scope,
        workers: 1,
        retries: 0,
        assets: assets,
        store: Store,
        save_to: context.root,
        req_options: context.req_options
      )

    wait(8_000, fn -> refute Crawler.running?(opts) end)
    opts
  end

  defp html(site, path, body, headers \\ []), do: respond(site, path, "text/html", body, headers)

  defp js(site, path, body, headers \\ []),
    do: respond(site, path, "application/javascript", body, headers)

  defp css(site, path, body, headers \\ []), do: respond(site, path, "text/css", body, headers)
  defp map(site, path, body), do: respond(site, path, "application/json", body)
  defp text(site, path, body), do: respond(site, path, "text/plain", body)

  defp respond(site, path, type, body, headers \\ []) do
    ReqTestSite.expect_once(site, "GET", path, fn conn ->
      conn =
        Enum.reduce([{"content-type", type} | headers], conn, fn {name, value}, conn ->
          Plug.Conn.put_resp_header(conn, name, value)
        end)

      Plug.Conn.resp(conn, 200, body)
    end)
  end

  defp redirect(site, path, location) do
    ReqTestSite.expect_once(site, "GET", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", location)
      |> Plug.Conn.resp(302, "")
    end)
  end

  defp offline(from, to), do: Linker.offline_link(from, to)

  defp refute_stored(context, urls) do
    Enum.each(urls, fn url ->
      refute Store.find({url, context.scope})
    end)
  end

  defp occurrences(body, text) do
    body |> String.split(text) |> length() |> Kernel.-(1)
  end
end
