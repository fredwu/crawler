defmodule Crawler.CrawlDiscoveryTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "discovers ordinary links and assets with distinct redirect requests", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    host = "#{site.host}:#{site.port}"

    ReqTestSite.expect_once(site, "GET", "/behavior/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "#{url}/behavior/dir/page")
      |> Plug.Conn.resp(302, "")
    end)

    body = """
    <html>
      <head>
        <base href="#{url}/behavior/other/">
        <script src="/behavior/app.js"></script>
        <script type="module" src="/behavior/mod.js"></script>
        <script src="//#{host}/behavior/lib.js"></script>
      </head>
      <a href="next">next</a>
      <a href="#{url}/behavior/dir/page#a">a</a>
      <a href="#{url}/behavior/dir/page#b">b</a>
      <a href="mailto:a@b.c">mail</a>
      <a href="javascript:void(0)">js</a>
      <a href="/behavior/search?q=1">search</a>
    </html>
    """

    landing_hits = :counters.new(1, [:atomics])

    ReqTestSite.expect(site, "GET", "/behavior/dir/page", fn conn ->
      :counters.add(landing_hits, 1, 1)
      assert :counters.get(landing_hits, 1) <= 2

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, body)
    end)

    for path <- [
          "/behavior/other/next",
          "/behavior/app.js",
          "/behavior/mod.js",
          "/behavior/lib.js",
          "/behavior/search"
        ] do
      ReqTestSite.expect_once(site, "GET", path, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.resp(200, path)
      end)
    end

    {:ok, opts} =
      start_crawl("#{url}/behavior/old",
        scope: "links",
        assets: ["js"],
        max_depths: 2,
        workers: 2,
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        save_to:
          Path.join(tmp(), "behavior-links" <> "-#{Base.encode16(:crypto.strong_rand_bytes(6))}"),
        req_options: req_options
      )

    on_exit(fn -> File.rm_rf(opts.save_to) end)
    export = ready_export(opts)
    assert :counters.get(landing_hits, 1) == 2
    page = root_resource(export, opts)
    search = reference_target(export, page, "#{url}/behavior/search?q=1")
    resources = export.manifest["resources"]

    assert Enum.frequencies_by(resources, & &1["url"]) == %{
             "#{url}/behavior/dir/page" => 2,
             "#{url}/behavior/app.js" => 2,
             "#{url}/behavior/mod.js" => 2,
             "#{url}/behavior/lib.js" => 2,
             "#{url}/behavior/other/next" => 1,
             "#{url}/behavior/search?q=1" => 1
           }

    landing = reference_target(export, page, "#{url}/behavior/dir/page")
    refute landing["id"] == page["id"]

    for script <- ["app.js", "mod.js", "lib.js"] do
      script_url = "#{url}/behavior/#{script}"

      variants =
        for document_resource <- [page, landing] do
          target = reference_target(export, document_resource, script_url)
          assert target["content_type"] == "text/html"
          assert read_resource(export, target) == "/behavior/#{script}"
          assert_link_opens(export, document_resource, target)
          target["id"]
        end

      assert length(Enum.uniq(variants)) == 2

      artifact_ids =
        resources
        |> Enum.filter(&(&1["url"] == script_url))
        |> Enum.map(& &1["id"])
        |> Enum.sort()

      assert Enum.sort(variants) == artifact_ids
    end

    assert Store.ops_count("links") == 6

    assert %Store.Page{
             processed: true,
             url: stored_url,
             body: nil,
             opts: nil,
             analysis: nil,
             interpretation: nil,
             source_revision: nil,
             credit: nil,
             picture_type: nil,
             target_handle: handle,
             fetch_tag: "a"
           } = Store.find_processed({"#{url}/behavior/old", "links"})

    assert stored_url == "#{url}/behavior/old"
    refute is_nil(handle)
    {:ok, document} = Floki.parse_document(read_resource(export, page))

    [href] =
      Enum.filter(
        Floki.attribute(document, "a", "href"),
        &(&1 == relative_reference(page, search))
      )

    assert_opens(export, page, search, href)
    assert read_resource(export, search) == @utf8_bom <> "/behavior/search"
  end

  test "redirect fragments share one direct landing request and one logical page", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    page = "#{url}/behavior/frag/page"

    ReqTestSite.expect_once(site, "GET", "/behavior/frag/from", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "#{page}#a")
      |> Plug.Conn.resp(302, "")
    end)

    landing_hits = :counters.new(1, [:atomics])

    ReqTestSite.expect(site, "GET", "/behavior/frag/page", fn conn ->
      :counters.add(landing_hits, 1, 1)
      assert :counters.get(landing_hits, 1) <= 2

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, ~s(<a href="#{page}#b">b</a>))
    end)

    {:ok, opts} =
      start_crawl("#{url}/behavior/frag/from",
        scope: "frag",
        store: Store,
        workers: 2,
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(opts)

      assert %Store.Page{body: body} = Store.find_processed({page, "frag"})
      assert body =~ "#{page}#b"
      assert Store.ops_count("frag") == 1
      assert :counters.get(landing_hits, 1) == 2
      assert Store.find({"#{page}#a", "frag"}).body == body
      assert Store.find({"#{page}#b", "frag"}).body == body
    end)
  end

  test "fetches media and style links and stores distinct offline files", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    sheet = """
    @import "other.css";
    @import url("nested.css");
    body { background: url( "spaced.png" ); }
    @font-face { src: url( 'font.woff2' ); }
    """

    entry = """
    <html>
      <img src="a.jpg" srcset="a.jpg 1x, b.jpg 2x">
      <picture><source srcset="c.webp" type="image/webp"><img src="c.jpg"></picture>
      <video src="d.mp4" poster="d.jpg"></video>
      <audio src="e.mp3"></audio>
      <link rel="preload" as="style" href="pre.css">
      <link rel="stylesheet alternate" href="alt.css">
      <link rel="stylesheet" href="sheet.css">
      <style>body { background: url(bg.png); }</style>
      <div style="background: url('bg2.png')"></div>
      <a href="/archive/search?q=1&amp;x=2">one</a>
      <a href="/archive/search?q=2">two</a>
      <a href="/archive/bare">bare</a>
      <a href="/archive/bare/index.html">index</a>
    </html>
    """

    ReqTestSite.expect_once(site, "GET", "/archive/entry", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, entry)
    end)

    ReqTestSite.expect_once(site, "GET", "/archive/sheet.css", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/css")
      |> Plug.Conn.resp(200, sheet)
    end)

    for {path, type, body} <- [
          {"/archive/a.jpg", "image/jpeg", "a"},
          {"/archive/b.jpg", "image/jpeg", "b"},
          {"/archive/c.webp", "image/webp", "c"},
          {"/archive/c.jpg", "image/jpeg", "c-jpg"},
          {"/archive/d.mp4", "video/mp4", "d"},
          {"/archive/d.jpg", "image/jpeg", "poster"},
          {"/archive/e.mp3", "audio/mpeg", "e"},
          {"/archive/pre.css", "text/css", "/* pre */"},
          {"/archive/alt.css", "text/css", "/* alt */"},
          {"/archive/bg.png", "image/png", "bg"},
          {"/archive/bg2.png", "image/png", "bg2"},
          {"/archive/other.css", "text/css", "/* other */"},
          {"/archive/nested.css", "text/css", "/* nested */"},
          {"/archive/spaced.png", "image/png", "spaced"},
          {"/archive/font.woff2", "font/woff2", "font"},
          {"/archive/bare", "text/html", "PAGE"},
          {"/archive/bare/index.html", "text/html", "INDEX"}
        ] do
      ReqTestSite.expect_once(site, "GET", path, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", type)
        |> Plug.Conn.resp(200, body)
      end)
    end

    ReqTestSite.stub(site, "GET", "/archive/search", fn conn ->
      label = if conn.query_string == "q=1&x=2", do: "1", else: "2"

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "results for " <> label)
    end)

    {:ok, opts} =
      start_crawl("#{url}/archive/entry",
        scope: "archive",
        assets: ["images", "css"],
        max_depths: 3,
        workers: 1,
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        max_manifest_bytes: 16_777_216,
        save_to:
          Path.join(
            tmp(),
            "behavior-archive" <> "-#{Base.encode16(:crypto.strong_rand_bytes(6))}"
          ),
        req_options: req_options
      )

    on_exit(fn -> File.rm_rf(opts.save_to) end)
    export = ready_export(opts)
    source = root_resource(export, opts)
    stylesheet = reference_target(export, source, "#{url}/archive/sheet.css")

    for {target_url, body} <- [
          {"#{url}/archive/bare", "PAGE"},
          {"#{url}/archive/bare/index.html", "INDEX"},
          {"#{url}/archive/search?q=1&x=2", "results for 1"},
          {"#{url}/archive/search?q=2", "results for 2"}
        ] do
      target = reference_target(export, source, target_url)
      assert_link_opens(export, source, target)
      assert read_resource(export, target) == @utf8_bom <> body
    end

    replacements =
      Map.new(
        [
          {"a.jpg", "a.jpg"},
          {"b.jpg", "b.jpg"},
          {"c.webp", "c.webp"},
          {"c.jpg", "c.jpg"},
          {"d.mp4", "d.mp4"},
          {"d.jpg", "d.jpg"},
          {"e.mp3", "e.mp3"},
          {"pre.css", "pre.css"},
          {"alt.css", "alt.css"},
          {"sheet.css", "sheet.css"},
          {"bg.png", "bg.png"},
          {"bg2.png", "bg2.png"},
          {"/archive/search?q=1&amp;x=2", "search?q=1&x=2"},
          {"/archive/search?q=2", "search?q=2"},
          {"/archive/bare/index.html", "bare/index.html"},
          {"/archive/bare", "bare"}
        ],
        fn {raw, path} ->
          target = reference_target(export, source, "#{url}/archive/#{path}")
          {raw, relative_reference(source, target)}
        end
      )

    pattern =
      replacements
      |> Map.keys()
      |> Enum.sort_by(&byte_size/1, :desc)
      |> Enum.map_join("|", &Regex.escape/1)
      |> Regex.compile!()

    expected_page = Regex.replace(pattern, entry, &Map.fetch!(replacements, &1))

    assert read_resource(export, source) == @utf8_bom <> expected_page

    expected_css =
      Enum.reduce(["other.css", "nested.css", "spaced.png", "font.woff2"], sheet, fn path, body ->
        target = reference_target(export, stylesheet, "#{url}/archive/#{path}")
        String.replace(body, path, relative_reference(stylesheet, target))
      end)

    assert read_resource(export, stylesheet) == expected_css

    for {from, targets} <- [
          {source,
           [
             {"a.jpg", "a"},
             {"b.jpg", "b"},
             {"c.webp", "c"},
             {"c.jpg", "c-jpg"},
             {"d.mp4", "d"},
             {"d.jpg", "poster"},
             {"e.mp3", "e"},
             {"pre.css", "/* pre */"},
             {"alt.css", "/* alt */"},
             {"bg.png", "bg"},
             {"bg2.png", "bg2"}
           ]},
          {stylesheet,
           [
             {"other.css", "/* other */"},
             {"nested.css", "/* nested */"},
             {"spaced.png", "spaced"},
             {"font.woff2", "font"}
           ]}
        ],
        {path, bytes} <- targets do
      target = reference_target(export, from, "#{url}/archive/#{path}")
      assert_link_opens(export, from, target)
      assert read_resource(export, target) == bytes
    end

    for resource <- export.manifest["resources"] do
      refute resource["path"] =~ "?"
      refute resource["path"] =~ "&"
    end
  end

  test "crawls embedded resources and skips them when assets are empty", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    page = "#{url}/embed/page"

    html = """
    <html>
      <area href="area.html">
      <iframe src="frame.html"></iframe>
      <link rel="icon" href="icon.png">
      <link rel="shortcut icon" href="shortcut.png">
      <link rel="preload" as="image" href="pre.png">
      <link rel="preload" as="script" href="pre.js">
      <link rel="preload" as="font" href="pre.woff2">
      <track src="cap.vtt">
      <svg><image href="svg.png"></image><use href="icons.svg#a"></use></svg>
    </html>
    """

    ReqTestSite.expect_once(site, "GET", "/embed/page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, html)
    end)

    for path <- ~w(
      /embed/area.html
      /embed/frame.html
      /embed/icon.png
      /embed/shortcut.png
      /embed/pre.png
      /embed/pre.js
      /embed/pre.woff2
      /embed/cap.vtt
      /embed/svg.png
      /embed/icons.svg
    ) do
      ReqTestSite.expect_once(site, "GET", path, fn conn ->
        type =
          if String.ends_with?(path, ".html"), do: "text/html", else: "application/octet-stream"

        conn
        |> Plug.Conn.put_resp_header("content-type", type)
        |> Plug.Conn.resp(200, path)
      end)
    end

    {:ok, opts} =
      start_crawl(page,
        scope: "embed",
        assets: ["images", "css", "js"],
        max_depths: 2,
        workers: 1,
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        max_manifest_bytes: 16_777_216,
        save_to:
          Path.join(tmp(), "behavior-embed" <> "-#{Base.encode16(:crypto.strong_rand_bytes(6))}"),
        req_options: req_options
      )

    on_exit(fn -> File.rm_rf(opts.save_to) end)
    export = ready_export(opts)
    source = resource_for_url(export, page)

    assert %Store.Page{
             picture_type: "application/octet-stream",
             body: nil,
             opts: nil,
             analysis: nil,
             interpretation: nil,
             source_revision: nil,
             credit: nil
           } =
             Store.find_processed({"#{url}/embed/icons.svg", "embed"})

    expected =
      Enum.reduce(
        ~w(area.html frame.html icon.png shortcut.png pre.png pre.js pre.woff2 cap.vtt svg.png icons.svg),
        html,
        fn name, body ->
          target = reference_target(export, source, "#{url}/embed/#{name}")
          assert Store.find_processed({"#{url}/embed/#{name}", "embed"})
          fragment = if name == "icons.svg", do: "#a", else: ""
          href = relative_reference(source, target, fragment)
          assert_opens(export, source, target, href, fragment)
          bytes = "/embed/" <> name

          expected_bytes =
            if String.ends_with?(name, ".html"), do: @utf8_bom <> bytes, else: bytes

          assert read_resource(export, target) == expected_bytes
          String.replace(body, name <> fragment, href)
        end
      )

    assert read_resource(export, source) == @utf8_bom <> expected

    bare = "#{url}/embed/bare"

    ReqTestSite.expect_once(site, "GET", "/embed/bare", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, """
      <link rel="icon" href="icon.png"><link rel="preload" as="script" href="pre.js">
      """)
    end)

    {:ok, skipped} =
      start_crawl(bare,
        scope: "embed-empty",
        assets: [],
        workers: 1,
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        req_options: req_options
      )

    wait(fn ->
      refute Crawler.running?(skipped)
      assert Store.find_processed({bare, "embed-empty"})
      refute Store.find({"#{url}/embed/icon.png", "embed-empty"})
      refute Store.find({"#{url}/embed/pre.js", "embed-empty"})
    end)
  end

  defp root_resource(export, opts) do
    record = :sys.get_state(Store).exports[{opts.scope, opts.generation}]
    resource_by_id(export, record.target_contexts[opts.target_handle].public_id)
  end
end
