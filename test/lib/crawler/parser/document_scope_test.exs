defmodule Crawler.Parser.DocumentScopeTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker
  alias Crawler.Parser
  alias Crawler.Snapper.LinkReplacer

  @page "http://example.com/dir/page"
  @start "http://example.com/start"
  @diagram "http://example.com/diagram.svg"
  @embed "http://example.com/embed.svg"

  @style """
  <style>body { background: url(plain.png) }</style>
  <style type="">body { background: url(empty.png) }</style>
  <style type="Text/CSS">body { background: url(css.png) }</style>
  <style type="text/css; charset=utf-8">body { background: url(param.png) }</style>
  <style type=" text/css ">body { background: url(spaced.png) }</style>
  <style type="text/plain">body { background: url(other.png) }</style>
  <div style="background: url(attr.png)"></div>
  <svg>
    <style type="text/css">g { fill: url(svg.png) }</style>
    <style type="text/css; charset=utf-8">g { fill: url(svg-param.png) }</style>
  </svg>
  """

  @sheets """
  <link rel="stylesheet" href="missing.css">
  <link rel="stylesheet" href="typed.css" type=" text/css ">
  <link rel="stylesheet" href="param.css" type="text/css; charset=utf-8">
  <link rel="stylesheet" href="plain.css" type="text/plain">
  <link rel="stylesheet" href="empty.css" type="">
  <link rel="alternate stylesheet" href="alt.css" title="Alt">
  <link rel="preload" as="style" href="preload.css" type="text/css; charset=utf-8">
  <link rel="preload" as="style" href="preload-plain.css" type="text/plain">
  <link rel="preload" as="font" href="font.woff2" type="font/woff2">
  """

  @sheet_header [
    {"link",
     Enum.join(
       [
         ~s|</header.css>; rel="stylesheet"; type="text/css; charset=utf-8"|,
         ~s|</header-missing.css>; rel="stylesheet"|,
         ~s|</header-plain.css>; rel="stylesheet"; type="text/plain"|,
         ~s|</header-empty.css>; rel="stylesheet"; type=""|
       ],
       ", "
     )}
  ]

  @shadow """
  <base href="/assets/">
  <div>
    <template shadowrootmode="open">
      <base href="/wrong/">
      <a href="next.html">Next</a>
      <img src="pic.png">
      <script src="app.js"></script>
      <style>a { background: url(bg.png) }</style>
      <style type="text/plain">a { background: url(no.png) }</style>
      <template><a href="inner.html">Inner</a></template>
    </template>
  </div>
  <span>
    <template shadowrootmode="CLOSED"><a href="closed.html">Closed</a></template>
  </span>
  <template>
    <template shadowrootmode="open"><a href="nested.html">Nested</a></template>
  </template>
  <template shadowrootmode="yes"><a href="bad.html">Bad</a></template>
  """

  @srcdoc """
  <base href="/assets/">
  <iframe src="/frame.html" srcdoc="&lt;a href=&quot;next.html&quot;&gt;Next&lt;/a&gt;&lt;img src=&quot;a.png&quot;&gt;&lt;link rel=&quot;stylesheet&quot; href=&quot;plain.css&quot; type=&quot;text/plain&quot;&gt;"></iframe>
  <iframe src="/only.html"><a href="/fallback.html">Fallback</a></iframe>
  <iframe src="/empty-src.html" srcdoc=""></iframe>
  <iframe srcdoc="&lt;base href=&quot;/other/&quot;&gt;&lt;a href=&quot;there.html&quot;&gt;There&lt;/a&gt;"></iframe>
  """

  @presentation_urls ~w(paint.png stroke.png clips.svg#c masks.svg#m mark.svg start.svg mid.svg end.svg cursor.png)

  @presentation """
  <svg>
    <rect fill="url(paint.png)" stroke="url(stroke.png)" filter="url(#local)"/>
    <rect clip-path="url(clips.svg#c)" mask="url(masks.svg#m)"/>
    <rect marker="url(mark.svg)" marker-start="url(start.svg)"/>
    <rect marker-mid="url(mid.svg)" marker-end="url(end.svg)" cursor="url(cursor.png) 4 12, auto"/>
    <image href="icon.png"/>
  </svg>
  <div fill="url(no.png)"></div>
  <img src="/images/picture.svg">
  """

  @picture """
  <?xml-stylesheet type="text/css" href="theme.css"?>
  <svg><image href="icon.png"/><rect fill="url(paint.png)"/></svg>
  """

  @svg_document """
  <?xml-stylesheet type="text/css" href="theme.css"?>
  <?xml-stylesheet type="text/css; charset=utf-8" href="param.css"?>
  <?xml-stylesheet type="text/xsl" href="no.xsl"?>
  <svg>
    <rect fill="url(paint.png)"/>
    <image href="icon.png"/>
  </svg>
  """

  @svg_page """
  <?xml-stylesheet type="text/css" href="not-html.css"?>
  <a href="/diagram.svg">Diagram</a>
  <object data="/embed.svg"></object>
  <img src="/images/picture.svg">
  """

  test "style elements are css only for a missing, empty, or exact text/css type" do
    opts = %{assets: ["css"]}

    assert found(@style, opts) == [
             {"plain.png", asset("plain.png"), "link", nil, "style"},
             {"empty.png", asset("empty.png"), "link", nil, "style"},
             {"css.png", asset("css.png"), "link", nil, "style"},
             {"attr.png", asset("attr.png"), "link", nil, "div"},
             {"svg.png", asset("svg.png"), "link", nil, "style"}
           ]

    saved = rewrite(@style, opts)

    for name <- ~w(plain.png empty.png css.png attr.png svg.png) do
      refute saved =~ "url(#{name})"
    end

    for name <- ~w(param.png spaced.png other.png svg-param.png) do
      assert saved =~ "url(#{name})"
    end
  end

  test "stylesheet links honour the css channel and a css mime type" do
    opts = %{assets: ["css"], headers: @sheet_header}

    assert found(@sheets, opts) == [
             {"/header.css", "http://example.com/header.css", "link", nil, "link"},
             {"/header-missing.css", "http://example.com/header-missing.css", "link", nil,
              "link"},
             {"missing.css", asset("missing.css"), "link", nil, "link"},
             {"typed.css", asset("typed.css"), "link", nil, "link"},
             {"param.css", asset("param.css"), "link", nil, "link"},
             {"alt.css", asset("alt.css"), "link", nil, "link"},
             {"preload.css", asset("preload.css"), "link", nil, "link"},
             {"font.woff2", asset("font.woff2"), "font", nil, "link"}
           ]

    saved = rewrite(@sheets, opts)
    assert saved =~ ~s|href="plain.css"|
    assert saved =~ ~s|href="empty.css"|
    assert saved =~ ~s|href="preload-plain.css"|
    refute saved =~ ~s|href="param.css"|
    refute saved =~ ~s|href="missing.css"|
    refute saved =~ ~s|href="typed.css"|
    refute saved =~ ~s|href="preload.css"|
  end

  test "live shadow roots are crawled and inert templates are not" do
    opts = %{url: @start, assets: ["css", "images", "js"]}

    assert found(@shadow, opts) == [
             {"next.html", "http://example.com/assets/next.html", "a", nil, "a"},
             {"pic.png", "http://example.com/assets/pic.png", "img", nil, "img"},
             {"app.js", "http://example.com/assets/app.js", "script", :script, "script"},
             {"bg.png", "http://example.com/assets/bg.png", "link", nil, "style"},
             {"closed.html", "http://example.com/assets/closed.html", "a", nil, "a"}
           ]

    saved = rewrite(@shadow, opts)
    assert saved =~ ~s|<base href="/wrong/">|
    refute saved =~ ~s|<base href="/assets/">|
    assert saved =~ "inner.html"
    assert saved =~ "nested.html"
    assert saved =~ "bad.html"
    assert saved =~ "url(no.png)"
    refute saved =~ ~s|href="next.html"|
    refute saved =~ ~s|src="pic.png"|
    refute saved =~ ~s|src="app.js"|
    refute saved =~ "url(bg.png)"
    refute saved =~ ~s|href="closed.html"|
    refute saved =~ "/wrong/next.html"
  end

  test "iframe srcdoc is the frame document and fallback text stays inert" do
    opts = %{assets: ["images"]}

    assert found(@srcdoc, opts) == [
             {"next.html", "http://example.com/assets/next.html", "a", nil, "a"},
             {"a.png", "http://example.com/assets/a.png", "img", nil, "img"},
             {"/only.html", "http://example.com/only.html", "a", nil, "iframe"},
             {"there.html", "http://example.com/other/there.html", "a", nil, "a"}
           ]

    saved = rewrite(@srcdoc, opts)
    next_href = Linker.offline_link(@page, "http://example.com/assets/next.html")
    image_href = Linker.offline_link(@page, "http://example.com/assets/a.png")
    there_href = Linker.offline_link(@page, "http://example.com/other/there.html")
    assert saved =~ next_href
    assert saved =~ image_href
    assert saved =~ there_href
    assert saved =~ ~s|src="/frame.html"|
    assert saved =~ ~s|src="/empty-src.html"|
    assert saved =~ ~s|href="/fallback.html"|
    assert saved =~ "plain.css"
    refute saved =~ ~s|href="next.html"|
  end

  test "an svg document follows srcdoc in html foreign content" do
    source =
      ~s|<svg><foreignObject><iframe src="/frame.html" srcdoc="&lt;a href=&quot;next.html&quot;&gt;N&lt;/a&gt;"></iframe></foreignObject></svg>|

    opts = %{url: @diagram, content_type: "image/svg+xml", html_tag: "a"}

    assert found(source, opts) == [
             {"next.html", "http://example.com/next.html", "a", nil, "a"}
           ]

    saved = rewrite(source, opts)
    assert saved =~ Linker.offline_link(@diagram, "http://example.com/next.html")
    assert saved =~ ~s|src="/frame.html"|

    assert rewrite(source, %{opts | html_tag: "img"}) == source
  end

  test "srcdoc uses its own robots meta instead of the parent nofollow" do
    source = """
    <meta name="robots" content="nofollow">
    <a href="/page.html">Page</a>
    <iframe srcdoc="&lt;a href=&quot;/inside.html&quot;&gt;In&lt;/a&gt;"></iframe>
    <iframe srcdoc="&lt;meta name=&quot;robots&quot; content=&quot;nofollow&quot;&gt;&lt;a href=&quot;/blocked.html&quot;&gt;B&lt;/a&gt;"></iframe>
    """

    assert found(source, %{}) == [
             {"/inside.html", "http://example.com/inside.html", "a", nil, "a"}
           ]
  end

  test "an unquoted srcdoc stays one attribute after its links are rewritten" do
    source = "<iframe srcdoc=&lt;a&#32;href=&quot;next.html&quot;&gt;></iframe>"

    assert found(source, %{}) == [
             {"next.html", asset("next.html"), "a", nil, "a"}
           ]

    offline = Linker.offline_link(@page, asset("next.html"))
    assert rewrite(source, %{}) =~ ~s|srcdoc="&lt;a href=&quot;#{offline}&quot;&gt;"|
  end

  test "a robots meta inside a live shadow root does not nofollow the page" do
    source = """
    <a href="/page.html">Page</a>
    <template shadowrootmode="open">
      <meta name="robots" content="nofollow">
      <a href="/live.html">Live</a>
    </template>
    <template>
      <meta name="robots" content="nofollow">
      <a href="/hidden.html">Hidden</a>
    </template>
    """

    assert found(source, %{url: @start}) == [
             {"/page.html", "http://example.com/page.html", "a", nil, "a"},
             {"/live.html", "http://example.com/live.html", "a", nil, "a"}
           ]
  end

  test "srcdoc does not repeat the parent link header" do
    source = ~s|<iframe srcdoc="&lt;a href=&quot;next.html&quot;&gt;N&lt;/a&gt;"></iframe>|
    headers = [{"link", ~s|</app.css>; rel="stylesheet"|}]
    urls = source |> found(%{assets: ["css"], headers: headers}) |> Enum.map(&elem(&1, 1))

    assert Enum.count(urls, &(&1 == "http://example.com/app.css")) == 1
    assert "http://example.com/dir/next.html" in urls
    refute "http://example.com/dir/app.css" in urls
  end

  test "svg presentation attributes follow css urls and skip same-drawing fragments" do
    both = %{assets: ["css", "images"]}

    assert found(@presentation, both) == [
             {"paint.png", asset("paint.png"), "link", nil, "rect"},
             {"stroke.png", asset("stroke.png"), "link", nil, "rect"},
             {"clips.svg#c", "http://example.com/dir/clips.svg", "link", nil, "rect"},
             {"masks.svg#m", "http://example.com/dir/masks.svg", "link", nil, "rect"},
             {"mark.svg", asset("mark.svg"), "link", nil, "rect"},
             {"start.svg", asset("start.svg"), "link", nil, "rect"},
             {"mid.svg", asset("mid.svg"), "link", nil, "rect"},
             {"end.svg", asset("end.svg"), "link", nil, "rect"},
             {"cursor.png", asset("cursor.png"), "link", nil, "rect"},
             {"icon.png", asset("icon.png"), "img", nil, "image"},
             {"/images/picture.svg", "http://example.com/images/picture.svg", "img", nil, "img"}
           ]

    saved = rewrite(@presentation, both)
    assert saved =~ "url(#local)"
    assert saved =~ ~s|fill="url(no.png)"|

    for name <- @presentation_urls do
      refute saved =~ "url(#{name})"
    end

    refute saved =~ ~s|href="icon.png"|

    images = %{assets: ["images"]}

    assert found(@presentation, images) == [
             {"icon.png", asset("icon.png"), "img", nil, "image"},
             {"/images/picture.svg", "http://example.com/images/picture.svg", "img", nil, "img"}
           ]

    saved = rewrite(@presentation, images)

    for name <- @presentation_urls do
      assert saved =~ "url(#{name})"
    end

    assert saved =~ "url(#local)"
    assert saved =~ ~s|fill="url(no.png)"|
    refute saved =~ ~s|href="icon.png"|

    picture =
      rewrite(@picture, Map.merge(both, %{html_tag: "img", content_type: "image/svg+xml"}))

    assert picture == @picture
  end

  test "svg documents follow xml stylesheets and html documents do not" do
    page = %{assets: ["css", "images"]}

    assert found(@svg_page, page) == [
             {"/diagram.svg", "http://example.com/diagram.svg", "a", nil, "a"},
             {"/embed.svg", "http://example.com/embed.svg", "a", nil, "object"},
             {"/images/picture.svg", "http://example.com/images/picture.svg", "img", nil, "img"}
           ]

    assert rewrite(@svg_page, page) =~ ~s|href="not-html.css"|

    document = %{
      url: @diagram,
      referrer_url: @diagram,
      content_type: "image/svg+xml",
      html_tag: "a",
      assets: ["css", "images"]
    }

    assert found(@svg_document, document) == [
             {"theme.css", "http://example.com/theme.css", "link", nil, "link"},
             {"param.css", "http://example.com/param.css", "link", nil, "link"},
             {"paint.png", "http://example.com/paint.png", "link", nil, "rect"},
             {"icon.png", "http://example.com/icon.png", "img", nil, "image"}
           ]

    assert found(@svg_document, %{document | url: @embed, referrer_url: @embed}) ==
             found(@svg_document, document)

    swapped = """
    <?xml-stylesheet href='param.css' type='text/css; charset=utf-8'?>
    <?xml-stylesheet href="missing.css"?>
    <svg></svg>
    """

    assert found(swapped, document) == [
             {"param.css", "http://example.com/param.css", "link", nil, "link"}
           ]

    saved = rewrite(@svg_document, document)
    theme = Linker.offline_link(@diagram, "http://example.com/theme.css")
    param = Linker.offline_link(@diagram, "http://example.com/param.css")
    assert saved =~ ~s|href="#{theme}"|
    assert saved =~ ~s|href="#{param}"|
    assert saved =~ ~s|href="no.xsl"|
    refute saved =~ ~s|href="theme.css"|
    refute saved =~ ~s|href="param.css"|

    assert rewrite(@picture, %{document | html_tag: "img"}) == @picture
  end

  test "an xml stylesheet href survives a greater-than inside a quoted value" do
    opts = svg_document_opts()
    offline = Linker.offline_link(@diagram, "http://example.com/theme.css")

    sources = [
      ~s|<?xml-stylesheet type="text/css" title="a>b" href="theme.css"?><svg></svg>|,
      ~s|<?xml-stylesheet href="theme.css" type="text/css" title="a>b"?><svg></svg>|,
      ~s|<?xml-stylesheet type="text/css; charset=utf-8" title="a>b" href="theme.css"?><svg></svg>|,
      ~s|<?xml-stylesheet type="text/css" title="a?>b" href="theme.css"?><svg></svg>|,
      ~s|<?xml-stylesheet type='text/css' title='a>b' href='theme.css'?><svg></svg>|
    ]

    for source <- sources do
      assert found(source, opts) == [
               {"theme.css", "http://example.com/theme.css", "link", nil, "link"}
             ]

      saved = rewrite(source, opts)
      assert saved =~ offline
      refute saved =~ ~s|href="theme.css"|
      refute saved =~ ~s|href='theme.css'|
      assert saved =~ "a>b" or saved =~ "a?>b"
    end

    greater_href = ~s|<?xml-stylesheet type="text/css" href="a>b.css"?><svg></svg>|
    assert [{"a>b.css", resolved, "link", nil, "link"}] = found(greater_href, opts)
    assert resolved == Linker.url(@diagram, "a>b.css")

    saved = rewrite(greater_href, opts)
    assert saved =~ Linker.offline_link(@diagram, resolved)
    refute saved =~ ~s|href="a>b.css"|

    broken = """
    <?xml-stylesheet type="text/css" href="early.css">
    <?xml-stylesheet type="text/css" href="late.css"?>
    <svg></svg>
    """

    assert found(broken, opts) == [
             {"late.css", "http://example.com/late.css", "link", nil, "link"}
           ]

    saved = rewrite(broken, opts)
    assert saved =~ ~s|href="early.css"|
    refute saved =~ ~s|href="late.css"|
  end

  test "a quoted xml stylesheet value is not markup" do
    opts = svg_document_opts()

    source =
      ~s|<?xml-stylesheet type="text/css" title="a><?xml-stylesheet type='text/css' href='nested.css'?><a href='escaped.html'></a>" href="theme.css"?><svg></svg>|

    assert found(source, opts) == [
             {"theme.css", "http://example.com/theme.css", "link", nil, "link"}
           ]

    saved = rewrite(source, opts)
    offline = Linker.offline_link(@diagram, "http://example.com/theme.css")
    assert saved =~ ~s|href="#{offline}"|
    refute saved =~ ~s|href="theme.css"|
    assert saved =~ ~s|href='nested.css'|
    assert saved =~ ~s|href='escaped.html'|

    hidden = """
    <svg><foreignObject><template>
      <?xml-stylesheet type="text/css" title="a></template><a href='escaped.html'></a>" href="hidden.css"?>
      <a href="inert.html">Inert</a>
    </template></foreignObject></svg>
    """

    assert found(hidden, opts) == []

    saved = rewrite(hidden, opts)
    assert saved =~ ~s|href="hidden.css"|
    assert saved =~ ~s|href='escaped.html'|
    assert saved =~ ~s|href="inert.html"|
  end

  test "a quoted greater-than does not open an xml stylesheet that ends at >" do
    opts = svg_document_opts()

    source =
      ~s|<?xml-stylesheet type="text/css" title="a><?xml-stylesheet type='text/css' href='nested.css'?><a href='escaped.html'></a>" href="early.css"><?xml-stylesheet type="text/css" href="late.css"?><svg></svg>|

    assert found(source, opts) == [
             {"late.css", "http://example.com/late.css", "link", nil, "link"}
           ]

    saved = rewrite(source, opts)
    offline = Linker.offline_link(@diagram, "http://example.com/late.css")
    assert saved =~ offline
    refute saved =~ ~s|href="late.css"|
    assert saved =~ ~s|href='nested.css'|
    assert saved =~ ~s|href='escaped.html'|
    assert saved =~ ~s|href="early.css"|

    quoted_pi =
      ~s|<?xml-stylesheet type="text/css" title="a?>b" href="early.css"><?xml-stylesheet type="text/css" href="late.css"?><svg></svg>|

    assert found(quoted_pi, opts) == [
             {"late.css", "http://example.com/late.css", "link", nil, "link"}
           ]

    html =
      ~s|<?xml-stylesheet type="text/css" title="a><a href='escaped.html'></a>" href="early.css"><a href="real.html">R</a>|

    assert found(html, %{}) == [
             {"real.html", asset("real.html"), "a", nil, "a"}
           ]
  end

  test "an unclosed xml stylesheet quote is not markup" do
    opts = svg_document_opts()

    source =
      ~s|<?xml-stylesheet type="text/css" title="a><?xml-stylesheet type='text/css' href='nested.css'?><a href='escaped.html'></a><svg></svg>|

    assert found(source, opts) == []
    assert rewrite(source, opts) == source
  end

  test "an xml stylesheet inside an inert template is ignored" do
    opts = svg_document_opts()

    source = """
    <?xml-stylesheet type="text/css" href="theme.css"?>
    <svg>
      <foreignObject>
        <template>
          <?xml-stylesheet type="text/css" href="hidden.css"?>
          <a href="inert.html">Inert</a>
        </template>
        <template shadowrootmode="open">
          <?xml-stylesheet type="text/css" href="live.css"?>
          <a href="live.html">Live</a>
          <template shadowrootmode="closed">
            <?xml-stylesheet type="text/css" href="deeper.css"?>
          </template>
          <template>
            <?xml-stylesheet type="text/css" href="inner.css"?>
          </template>
        </template>
      </foreignObject>
    </svg>
    <template>
      <template shadowrootmode="open">
        <?xml-stylesheet type="text/css" href="nested.css"?>
      </template>
    </template>
    """

    assert found(source, opts) == [
             {"theme.css", "http://example.com/theme.css", "link", nil, "link"},
             {"live.css", "http://example.com/live.css", "link", nil, "link"},
             {"deeper.css", "http://example.com/deeper.css", "link", nil, "link"},
             {"live.html", "http://example.com/live.html", "a", nil, "a"}
           ]

    saved = rewrite(source, opts)

    for name <- ~w(theme.css live.css deeper.css live.html) do
      offline = Linker.offline_link(@diagram, "http://example.com/" <> name)
      assert saved =~ offline
      refute saved =~ ~s|href="#{name}"|
    end

    for name <- ~w(hidden.css inner.css nested.css inert.html) do
      assert saved =~ ~s|href="#{name}"|
    end
  end

  defp svg_document_opts do
    %{
      url: @diagram,
      referrer_url: @diagram,
      content_type: "image/svg+xml",
      html_tag: "a",
      assets: ["css"]
    }
  end

  defp found(source, opts) do
    source
    |> Parser.parse_links(page_opts(opts), fn
      {_, raw, _, url}, link_opts -> link_tuple(raw, url, link_opts)
      {_, url}, link_opts -> link_tuple(url, url, link_opts)
    end)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp link_tuple(raw, url, opts) do
    {raw, url, opts.html_tag, opts[:javascript_goal], opts.reference_tag}
  end

  defp page_opts(opts) do
    Map.merge(%{url: @page, content_type: "text/html", html_tag: "a"}, opts)
  end

  defp rewrite(source, opts) do
    opts = page_opts(opts)
    opts = Map.put_new(opts, :referrer_url, opts.url)

    assert {:ok, body} = LinkReplacer.replace_links(source, opts)
    body
  end

  defp asset(name), do: "http://example.com/dir/" <> name
end
