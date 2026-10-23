defmodule Crawler.Snapper.HtmlSourceTest do
  use Crawler.OfflineLinkCase, async: false

  import Crawler.TestHelpers, only: [tmp: 1]
  import Crawler.SnapshotHelpers, only: [saved_artifact: 2]

  alias Crawler.ManagedSnapshotHelpers, as: Managed
  alias Crawler.Parser.CssParser
  alias Crawler.Snapper

  test "charset scanning keeps non-UTF-8 tag names opaque before the real declaration" do
    source =
      "<X-" <> <<0xE9>> <> ">note</X-" <> <<0xE9>> <> "><meta charset='latin1'>caf" <> <<0xE9>>

    assert Crawler.Charset.decode(source, %{content_type: "text/html"}) ==
             "<X-é>note</X-é><meta charset='utf-8'>café"
  end

  test "changes actual URL attributes and preserves HTML-shaped quoted data and comments" do
    literal =
      ~s|<div data-template="<img src='a.png'><base href='fake/'><a href='next.html'>"></div>|

    comment = ~s|<!-- <img src="a.png"><base href="fake/"><a href="next.html"> -->|
    source = ~s|<img src="a.png"><a href='next.html'>go</a>| <> literal <> comment
    image = "http://example.com/blog/a.png"
    page = "http://example.com/blog/next.html"

    body = rewrite(source, @page)

    assert body == ~s|<img src="#{image}"><a href='#{page}'>go</a>| <> literal <> comment
    document = Floki.parse_document!(body)
    assert Floki.attribute(document, "img", "src") == [image]
    assert Floki.attribute(document, "a", "href") == [page]

    assert Floki.attribute(document, "div", "data-template") ==
             [~s|<img src='a.png'><base href='fake/'><a href='next.html'>|]
  end

  test "an unfinished quoted attribute keeps embedded markup literal" do
    source = ~s|<img src="a.png"><div data-template="<img src='a.png'><base href='fake/'>|
    image = "http://example.com/blog/a.png"

    assert rewrite(source, @page) ==
             ~s|<img src="#{image}"><div data-template="<img src='a.png'><base href='fake/'>|
  end

  for quote <- ["\"", "'"] do
    test "recovers a missing attribute separator after #{quote} without entering the quoted value" do
      quote = unquote(quote)
      title = "literal href=next"
      source = "<a title=#{quote}#{title}#{quote}href=#{quote}next#{quote}>go</a>"
      target = "http://example.com/blog/next"
      before = Floki.parse_document!(source)
      assert Floki.attribute(before, "a", "href") == ["next"]

      body = rewrite(source, @page)
      assert body == "<a title=#{quote}#{title}#{quote}href=#{quote}#{target}#{quote}>go</a>"
      document = Floki.parse_document!(body)
      assert Floki.attribute(document, "a", "title") == [title]
      assert Floki.attribute(document, "a", "href") == [target]
    end
  end

  test "quoted template attributes stay opaque beside adjacent recovered attributes" do
    source = ~s|<img title="<img src='a.png' style='background:url(a.png)'>"src="a.png">|
    target = "http://example.com/blog/a.png"

    assert rewrite(source, @page) ==
             ~s|<img title="<img src='a.png' style='background:url(a.png)'>"src="#{target}">|
  end

  test "removes real base hrefs while retaining unrelated attributes and base-shaped literal source" do
    literal = ~s|<div title="<base href='wrong/'>"></div><!-- <base href="wrong/"> -->|

    source =
      literal <>
        ~s|<base href="https://example.com/actual/" data-name="a>b"><a href="next.html">go</a>|

    target = "https://example.com/actual/next.html"

    assert rewrite(source, @page) ==
             literal <> ~s|<base data-name="a>b"><a href="#{target}">go</a>|
  end

  for value <- ["caf&#233;", "caf&#xE9;", "caf&#X00e9;", "caf&eacute;", "café"] do
    test "rewrites decoded URL attribute #{value} and retains unrelated source" do
      value = unquote(value)
      source = "<a\tHREF = '#{value}' title=\"café &eacute; <a href='#{value}'>\">go</a>"
      target = "http://example.com/blog/café"
      body = rewrite(source, @page)

      assert body == "<a\tHREF = '#{target}' title=\"café &eacute; <a href='#{value}'>\">go</a>"
      assert body |> Floki.parse_document!() |> Floki.attribute("a", "href") == [target]
      assert_points(body, @page, "http://example.com/blog/café")
    end
  end

  test "rewrites entities in srcset, style and refresh URLs without altering surrounding values" do
    source = """
    <img srcset="caf&#233;.png 1x, caf&eacute;@2.png 2x" alt="caf&#233;.png">
    <div style="background:url(&apos;caf&#xE9;.png&apos;); color:red"></div>
    <meta http-equiv="refresh" content="0; URL=&quot;caf&eacute;&quot;">
    <meta name="description" content="0; URL=&quot;caf&eacute;&quot;">
    """

    image = "http://example.com/blog/café.png"
    retina = "http://example.com/blog/café@2.png"
    page = "http://example.com/blog/café"
    body = rewrite(source, @page)

    assert body == """
           <img srcset="#{image} 1x, #{retina} 2x" alt="caf&#233;.png">
           <div style="background:url(&apos;#{image}&apos;); color:red"></div>
           <meta http-equiv="refresh" content="0; URL=&quot;#{page}&quot;">
           <meta name="description" content="0; URL=&quot;caf&eacute;&quot;">
           """
  end

  test "preserves raw text and non-executable scripts while rewriting real asset sources" do
    literal = """
    <textarea><img src="a.png"><base href="fake/"></textarea>
    <title><a href="caf&#233;"></title>
    <script type="application/json">{"template":"<img src='a.png'><base href='fake/'>"}</script>
    <script>const html = '<img src="a.png"><base href="fake/">';</script>
    """

    source = literal <> ~s|<img src="a.png"><style>p { background:url("a.png") }</style>|
    image = "http://example.com/blog/a.png"

    assert rewrite(source, @page) ==
             literal <> ~s|<img src="#{image}"><style>p { background:url("#{image}") }</style>|
  end

  test "inline CSS escapes and URL entities compose while literal strings retain their source" do
    source =
      ~S|<div style="background:url(caf&#233;\)photo.png); --label:&quot;url(caf&#233;\)photo.png)&quot;"></div>|

    image = "http://example.com/blog/café\\29&#32;photo.png"

    assert rewrite(source, @page) ==
             ~s|<div style="background:url(#{image}); --label:&quot;url(caf&#233;\\)photo.png)&quot;"></div>|
  end

  test "unquoted query equals signs remain part of the URL and open the saved query file" do
    root = tmp("snapshot-html-unquoted-query")
    page = "http://example.com/index.html"
    target = "http://example.com/next?x=1&y=2"
    source = ~s|<a href=next?x=1&y=2 title="keep">go</a>|

    export =
      managed_export(root, page, source, [{target, "QUERY TARGET", "text/html"}], assets: [])

    from = Managed.resource_for_url(export, page)
    to = Managed.reference_target(export, from, target)
    body = Managed.read_resource(export, from)
    [{"a", attrs, ["go"]}] = Floki.find(Floki.parse_document!(body), "a")
    assert Enum.map(attrs, &elem(&1, 0)) == ["href", "title"]
    {"href", href} = List.keyfind(attrs, "href", 0)
    Managed.assert_opens(export, from, to, href)
    assert body == <<0xEF, 0xBB, 0xBF>> <> ~s|<a href=#{href} title="keep">go</a>|
    assert Managed.read_resource(export, to) == <<0xEF, 0xBB, 0xBF, "QUERY TARGET">>
  end

  test "rewrites an unquoted URL ending at slash-close without changing adjacent source" do
    root = tmp("snapshot-html-unquoted-slash")
    page = "http://example.com/index.html"
    target = "http://example.com/icon.png/"
    source = ~s|<img src=icon.png/><div title="src=icon.png/>"></div>|

    export =
      managed_export(root, page, source, [{target, "IMAGE", "image/png"}], assets: ["images"])

    from = Managed.resource_for_url(export, page)
    to = Managed.reference_target(export, from, target)
    body = Managed.read_resource(export, from)
    [src] = body |> Floki.parse_document!() |> Floki.attribute("img", "src")
    assert body == <<0xEF, 0xBB, 0xBF>> <> ~s|<img src=#{src}><div title="src=icon.png/>"></div>|
    Managed.assert_opens(export, from, to, src)
    assert Managed.read_resource(export, to) == "IMAGE"
  end

  test "entity-encoded saved links and asset URLs open their intended files" do
    root = tmp("snapshot-html-entity-spans")
    page = "http://example.com/index.html"
    link = "http://example.com/café"
    image = "http://example.com/café.png"

    source = """
    <a href="caf&#233;">café</a>
    <img src="caf&eacute;.png" srcset="caf&#xE9;.png 1x">
    <div style="background:url(&apos;caf&#233;.png&apos;)"></div>
    """

    export =
      managed_export(
        root,
        page,
        source,
        [{link, "TARGET", "text/html"}, {image, "IMAGE", "image/png"}],
        assets: ["images", "css"]
      )

    from = Managed.resource_for_url(export, page)
    document = export |> Managed.read_resource(from) |> Floki.parse_document!()
    [href] = Floki.attribute(document, "a", "href")
    [src] = Floki.attribute(document, "img", "src")
    [srcset] = Floki.attribute(document, "img", "srcset")
    [style] = Floki.attribute(document, "div", "style")
    [{"link", [{"href", style_src}], []}] = CssParser.parse(style)
    assert srcset == src <> " 1x"

    for {reference, target, index} <- [
          {href, link, 0},
          {src, image, 1},
          {src, image, 2},
          {style_src, image, 3}
        ] do
      to = Managed.edge_target(export, from, index)
      assert to["url"] == Crawler.URL.normalize(target)
      Managed.assert_opens(export, from, to, reference)
      expected = if target == link, do: <<0xEF, 0xBB, 0xBF, "TARGET">>, else: "IMAGE"
      assert Managed.read_resource(export, to) == expected
    end

    assert Managed.read_resource(export, from) ==
             <<0xEF, 0xBB, 0xBF>> <>
               """
               <a href="#{href}">café</a>
               <img src="#{src}" srcset="#{srcset}">
               <div style="background:url(&apos;#{style_src}&apos;)"></div>
               """
  end

  test "standalone public ID acknowledgements preserve unquoted query URLs and source attributes" do
    root = tmp("standalone-html-query-ack-source")
    page_url = "http://example.com/index.html"
    target_url = "http://example.com/next?x=1&y=2"
    source = ~s|<a href=next?x=1&y=2 title="keep">go</a>|
    target_id = "standalone000000000007001"
    page_id = "standalone000000000007002"

    opts = %{
      save_to: root,
      content_type: "text/html",
      html_tag: "a",
      assets: [],
      depth: 1,
      max_depths: 3
    }

    assert {:ok, %{public_id: ^target_id} = target} =
             Snapper.snap(
               "QUERY TARGET",
               Map.merge(opts, %{public_id: target_id, url: target_url})
             )

    assert {:ok, %{public_id: ^page_id} = page} =
             Snapper.snap(source, Map.merge(opts, %{public_id: page_id, url: page_url}))

    body = File.read!(saved_artifact(root, page))

    assert body ==
             <<0xEF, 0xBB, 0xBF>> <>
               ~s|<a href=http://example.com/next?x&#61;1&amp;y&#61;2 title="keep">go</a>|

    [{"a", attrs, ["go"]}] = Floki.find(Floki.parse_document!(body), "a")
    assert Enum.map(attrs, &elem(&1, 0)) == ["href", "title"]
    assert {"title", "keep"} in attrs
    assert {"href", target_url} in attrs
    assert File.read!(saved_artifact(root, target)) == <<0xEF, 0xBB, 0xBF, "QUERY TARGET">>
  end

  test "standalone public ID acknowledgements preserve slash-close URL boundaries and unrelated source" do
    root = tmp("standalone-html-slash-ack-source")
    page_url = "http://example.com/index.html"
    target_url = "http://example.com/icon.png/"
    source = ~s|<img src=icon.png/><div title="src=icon.png/>"></div>|
    target_id = "standalone000000000008001"
    page_id = "standalone000000000008002"

    assert {:ok, %{public_id: ^target_id} = target} =
             Snapper.snap("IMAGE", %{
               public_id: target_id,
               url: target_url,
               save_to: root,
               content_type: "image/png",
               html_tag: "img"
             })

    assert {:ok, %{public_id: ^page_id} = page} =
             Snapper.snap(source, %{
               public_id: page_id,
               url: page_url,
               save_to: root,
               content_type: "text/html",
               html_tag: "a",
               assets: ["images"],
               depth: 1,
               max_depths: 3
             })

    body = File.read!(saved_artifact(root, page))

    assert body ==
             <<0xEF, 0xBB, 0xBF>> <>
               ~s|<img src=#{target_url}><div title="src=icon.png/>"></div>|

    urls =
      body
      |> Crawler.Parser.parse_links(
        %{url: page_url, content_type: "text/html", html_tag: "a", assets: ["images"]},
        fn
          {_, _, _, url}, _opts -> url
          {_, url}, _opts -> url
        end
      )
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    assert urls == [target_url]
    [{"img", attrs, []}] = Floki.find(Floki.parse_document!(body), "img")
    assert Enum.map(attrs, &elem(&1, 0)) == ["src"]

    assert Floki.find(Floki.parse_document!(body), "div") == [
             {"div", [{"title", "src=icon.png/>"}], []}
           ]

    assert File.read!(saved_artifact(root, target)) == "IMAGE"
  end

  test "standalone public ID acknowledgements preserve entity URL agreement across HTML and CSS" do
    root = tmp("standalone-html-entity-ack-source")
    page_url = "http://example.com/index.html"
    link_url = "http://example.com/café"
    image_url = "http://example.com/café.png"

    source = """
    <a href="caf&#233;">café</a>
    <img src="caf&eacute;.png" srcset="caf&#xE9;.png 1x">
    <div style="background:url(&apos;caf&#233;.png&apos;)"></div>
    """

    opts = %{save_to: root, html_tag: "a", assets: ["images", "css"], depth: 1, max_depths: 3}
    link_id = "standalone000000000009001"
    image_id = "standalone000000000009002"
    page_id = "standalone000000000009003"

    assert {:ok, %{public_id: ^link_id} = link} =
             Snapper.snap(
               "TARGET",
               Map.merge(opts, %{public_id: link_id, url: link_url, content_type: "text/html"})
             )

    assert {:ok, %{public_id: ^image_id} = image} =
             Snapper.snap(
               "IMAGE",
               Map.merge(opts, %{public_id: image_id, url: image_url, content_type: "image/png"})
             )

    assert {:ok, %{public_id: ^page_id} = page} =
             Snapper.snap(
               source,
               Map.merge(opts, %{public_id: page_id, url: page_url, content_type: "text/html"})
             )

    body = File.read!(saved_artifact(root, page))

    assert body ==
             <<0xEF, 0xBB, 0xBF>> <>
               """
               <a href="#{link_url}">café</a>
               <img src="#{image_url}" srcset="#{image_url} 1x">
               <div style="background:url(&apos;#{image_url}&apos;)"></div>
               """

    document = Floki.parse_document!(body)
    assert Floki.attribute(document, "a", "href") == [link_url]
    [src] = Floki.attribute(document, "img", "src")
    [srcset] = Floki.attribute(document, "img", "srcset")
    [style] = Floki.attribute(document, "div", "style")
    [{"link", [{"href", style_src}], []}] = CssParser.parse(style)
    assert src == image_url
    assert srcset == src <> " 1x"
    assert style_src == src
    assert File.read!(saved_artifact(root, link)) == <<0xEF, 0xBB, 0xBF, "TARGET">>
    assert File.read!(saved_artifact(root, image)) == "IMAGE"
  end

  defp managed_export(root, page, source, targets, options) do
    File.rmdir!(root)
    root = root <> "-#{System.pid()}-#{System.unique_integer([:positive])}"
    requests = Crawler.RequestLog.new()

    route_key = fn url ->
      uri = url |> Crawler.URL.canonical() |> URI.parse()
      URI.to_string(%{uri | query: uri.query || ""})
    end

    routes =
      Map.new([{page, source, "text/html"} | targets], fn {url, body, type} ->
        {route_key.(url), {body, type}}
      end)

    plug = fn conn ->
      key = conn |> Plug.Conn.request_url() |> route_key.()
      Crawler.RequestLog.record(requests, key)
      {body, type} = Map.fetch!(routes, key)
      conn |> Plug.Conn.put_resp_header("content-type", type) |> Plug.Conn.resp(200, body)
    end

    assert {:ok, opts} =
             Crawler.crawl(
               page,
               Keyword.merge(
                 [
                   scope: Crawler.TestHelpers.unique_scope("managed-snapshot"),
                   save_to: root,
                   store: nil,
                   workers: 1,
                   max_body: 1_048_576,
                   max_analysis_bytes: 16_777_216,
                   max_css_work: 5_000,
                   max_css_pictures: 1_000,
                   max_depths: 3,
                   respect_robots: false,
                   req_options: [plug: plug, retry: false]
                 ],
                 options
               )
             )

    on_exit(fn ->
      Crawler.stop(opts)
      File.rm_rf!(root)
    end)

    export = Managed.ready_export(opts)

    assert Crawler.RequestLog.frequencies(requests) ==
             Map.new(routes, fn {url, _} -> {url, 1} end)

    export
  end
end
