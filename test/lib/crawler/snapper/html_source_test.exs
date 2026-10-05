defmodule Crawler.Snapper.HtmlSourceTest do
  use Crawler.OfflineLinkCase, async: true

  import Crawler.TestHelpers, only: [tmp: 1]
  import Crawler.SnapshotHelpers, only: [link_path: 1, saved: 2]

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
    image = Linker.offline_link(@page, "http://example.com/blog/a.png")
    page = Linker.offline_link(@page, "http://example.com/blog/next.html")

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
    image = Linker.offline_link(@page, "http://example.com/blog/a.png")

    assert rewrite(source, @page) ==
             ~s|<img src="#{image}"><div data-template="<img src='a.png'><base href='fake/'>|
  end

  for quote <- ["\"", "'"] do
    test "recovers a missing attribute separator after #{quote} without entering the quoted value" do
      quote = unquote(quote)
      title = "literal href=next"
      source = "<a title=#{quote}#{title}#{quote}href=#{quote}next#{quote}>go</a>"
      target = Linker.offline_link(@page, "http://example.com/blog/next")
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
    target = Linker.offline_link(@page, "http://example.com/blog/a.png")

    assert rewrite(source, @page) ==
             ~s|<img title="<img src='a.png' style='background:url(a.png)'>"src="#{target}">|
  end

  test "removes real base hrefs while retaining unrelated attributes and base-shaped literal source" do
    literal = ~s|<div title="<base href='wrong/'>"></div><!-- <base href="wrong/"> -->|

    source =
      literal <>
        ~s|<base href="https://example.com/actual/" data-name="a>b"><a href="next.html">go</a>|

    target = Linker.offline_link(@page, "https://example.com/actual/next.html")

    assert rewrite(source, @page) ==
             literal <> ~s|<base data-name="a>b"><a href="#{target}">go</a>|
  end

  for value <- ["caf&#233;", "caf&#xE9;", "caf&#X00e9;", "caf&eacute;", "café"] do
    test "rewrites decoded URL attribute #{value} and retains unrelated source" do
      value = unquote(value)
      source = "<a\tHREF = '#{value}' title=\"café &eacute; <a href='#{value}'>\">go</a>"
      target = Linker.offline_link(@page, "http://example.com/blog/café")
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

    image = Linker.offline_link(@page, "http://example.com/blog/café.png")
    retina = Linker.offline_link(@page, "http://example.com/blog/café@2.png")
    page = Linker.offline_link(@page, "http://example.com/blog/café")
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
    image = Linker.offline_link(@page, "http://example.com/blog/a.png")

    assert rewrite(source, @page) ==
             literal <> ~s|<img src="#{image}"><style>p { background:url("#{image}") }</style>|
  end

  test "inline CSS escapes and URL entities compose while literal strings retain their source" do
    source =
      ~S|<div style="background:url(caf&#233;\)photo.png); --label:&quot;url(caf&#233;\)photo.png)&quot;"></div>|

    image = Linker.offline_link(@page, "http://example.com/blog/café)photo.png")

    assert rewrite(source, @page) ==
             ~s|<div style="background:url(#{image}); --label:&quot;url(caf&#233;\\)photo.png)&quot;"></div>|
  end

  test "unquoted query equals signs remain part of the URL and open the saved query file" do
    root = tmp("snapshot-html-unquoted-query")
    page = "http://example.com/index.html"
    target = "http://example.com/next?x=1&y=2"
    source = ~s|<a href=next?x=1&y=2 title="keep">go</a>|

    for {url, body} <- [{target, "QUERY TARGET"}, {page, source}] do
      assert {:ok, _opts} =
               Snapper.snap(body, %{
                 url: url,
                 save_to: root,
                 content_type: "text/html",
                 html_tag: "a",
                 assets: [],
                 depth: 1,
                 max_depths: 3
               })
    end

    body = File.read!(saved(root, page))
    [{"a", attrs, ["go"]}] = Floki.find(Floki.parse_document!(body), "a")
    assert Enum.map(attrs, &elem(&1, 0)) == ["href", "title"]
    {"href", href} = List.keyfind(attrs, "href", 0)
    assert href == Linker.offline_link(page, target)
    opened = Path.expand(link_path(href), Path.dirname(saved(root, page)))
    assert opened == Path.expand(saved(root, target))
    assert File.read!(opened) == <<0xEF, 0xBB, 0xBF, "QUERY TARGET">>
  end

  test "rewrites an unquoted URL ending at slash-close to a quoted saved-file reference" do
    root = tmp("snapshot-html-unquoted-slash")
    page = "http://example.com/index.html"
    target = "http://example.com/icon.png/"
    source = ~s|<img src=icon.png/><div title="src=icon.png/>"></div>|

    assert {:ok, _opts} =
             Snapper.snap("IMAGE", %{
               url: target,
               save_to: root,
               content_type: "image/png",
               html_tag: "img"
             })

    assert {:ok, _opts} =
             Snapper.snap(source, %{
               url: page,
               save_to: root,
               content_type: "text/html",
               html_tag: "a",
               assets: ["images"],
               depth: 1,
               max_depths: 3
             })

    body = File.read!(saved(root, page))
    [src] = body |> Floki.parse_document!() |> Floki.attribute("img", "src")
    assert src == Linker.offline_link(page, target)
    assert body =~ ~s|<img src="#{src}">|
    assert body =~ ~s|<div title="src=icon.png/>"></div>|
    opened = Path.expand(link_path(src), Path.dirname(saved(root, page)))
    assert opened == Path.expand(saved(root, target))
    assert File.read!(opened) == "IMAGE"
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

    for {url, body, type} <- [
          {link, "TARGET", "text/html"},
          {image, "IMAGE", "image/png"},
          {page, source, "text/html"}
        ] do
      assert {:ok, _opts} =
               Snapper.snap(body, %{
                 url: url,
                 save_to: root,
                 content_type: type,
                 html_tag: "a",
                 assets: ["images", "css"],
                 depth: 1,
                 max_depths: 3
               })
    end

    document = root |> saved(page) |> File.read!() |> Floki.parse_document!()
    [href] = Floki.attribute(document, "a", "href")
    [src] = Floki.attribute(document, "img", "src")
    [srcset] = Floki.attribute(document, "img", "srcset")
    [style] = Floki.attribute(document, "div", "style")
    [{"link", [{"href", style_src}], []}] = CssParser.parse(style)
    assert srcset == src <> " 1x"
    assert style_src == src

    for {reference, target} <- [{href, link}, {src, image}, {style_src, image}] do
      opened = Path.expand(link_path(reference), Path.dirname(saved(root, page)))
      assert opened == Path.expand(saved(root, target))
      assert File.read!(opened) == File.read!(saved(root, target))
    end
  end
end
