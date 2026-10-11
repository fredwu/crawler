defmodule Crawler.Parser.DrawingMathTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker
  alias Crawler.Parser
  alias Crawler.Snapper.LinkReplacer

  @page "http://example.com/dir/page"
  @diagram "http://example.com/diagram.svg"

  test "svg style sheets follow imports, images, and fonts and skip comments" do
    source = """
    <base href="/assets/">
    <svg>
      <style>
        g { fill: url("paint.png"); background: image-set("wide.png" 1x, "narrow.png" 2x); }
        @import "theme.css";
        /* url(hidden.png) */
      </style>
      <rect style="fill: url(attr.png)"/>
    </svg>
    """

    assert found(source, ["css"]) == [
             {"paint.png", "http://example.com/assets/paint.png", "link", nil, "style"},
             {"wide.png", "http://example.com/assets/wide.png", "link", nil, "style"},
             {"narrow.png", "http://example.com/assets/narrow.png", "link", nil, "style"},
             {"theme.css", "http://example.com/assets/theme.css", "link", nil, "style"},
             {"attr.png", "http://example.com/assets/attr.png", "link", nil, "rect"}
           ]

    assert found(source, ["images", "js"]) == []

    saved = rewrite(source, ["css"])
    refute saved =~ ~s|url("paint.png")|
    refute saved =~ ~s|@import "theme.css"|
    refute saved =~ "url(attr.png)"
    assert saved =~ "url(hidden.png)"

    untouched = rewrite(source, [])
    assert untouched =~ ~s|url("paint.png")|
    assert untouched =~ ~s|@import "theme.css"|
    assert untouched =~ "url(attr.png)"
    assert untouched =~ "url(hidden.png)"
  end

  test "svg css keeps a fragment in the same drawing" do
    source = """
    <base href="/assets/">
    <svg>
      <style>g { fill: url(#metal); background: url("paint.png"); }</style>
      <rect style="fill: url(#shine)"/>
    </svg>
    """

    assert found(source, ["css"]) == [
             {"paint.png", "http://example.com/assets/paint.png", "link", nil, "style"}
           ]

    saved = rewrite(source, ["css"])
    assert saved =~ "url(#metal)"
    assert saved =~ "url(#shine)"
    refute saved =~ ~s|url("paint.png")|
  end

  test "an html style still follows a fragment url" do
    source = ~s|<style>a { background: url(#top); }</style>|

    assert found(source, ["css"]) == [
             {"#top", "http://example.com/dir/page", "link", nil, "style"}
           ]

    refute rewrite(source, ["css"]) =~ "url(#top)"
  end

  test "svg style keeps a fragment when another link repeats it" do
    source = """
    <a href="#shade">Page</a>
    <div style="background: url(#shade)"></div>
    <style>a { background: url(#shade); }</style>
    <svg>
      <style>g { fill: url(#shade); background: url("paint.png"); }</style>
      <rect style="fill: url(#shade); stroke: url(line.png)"/>
    </svg>
    """

    saved = rewrite(source, ["css"])
    assert saved =~ "fill: url(#shade); background:"
    assert saved =~ ~s|style="fill: url(#shade); stroke:|
    refute saved =~ "a { background: url(#shade)"
    refute saved =~ ~s|style="background: url(#shade)"|
    refute saved =~ ~s|url("paint.png")|
    refute saved =~ "url(line.png)"

    standalone = """
    <svg>
      <a href="#shade">Shade</a>
      <style>g { fill: url(#shade); }</style>
      <rect style="fill: url(#shade)"/>
    </svg>
    """

    saved = rewrite(standalone, %{assets: ["css"], content_type: "image/svg+xml"})
    assert saved =~ "g { fill: url(#shade); }"
    assert saved =~ ~s|style="fill: url(#shade)"|
  end

  test "svg paint fragments stay literal when another link repeats them" do
    source = """
    <a href="#icon">Page</a>
    <svg>
      <a href="#icon">Shade</a>
      <use href="#icon"/>
      <pattern href="#icon"/>
      <feImage xlink:href="#icon"/>
      <filter href="#icon"/>
      <linearGradient href="#icon"/>
      <image href="sprite.svg#mark"/>
    </svg>
    """

    for saved <- [
          rewrite(source, ["images", "css"]),
          rewrite(source, %{assets: ["images", "css"], content_type: "image/svg+xml"})
        ] do
      assert saved =~ ~s|<use href="#icon"/>|
      assert saved =~ ~s|<pattern href="#icon"/>|
      assert saved =~ ~s|<feImage xlink:href="#icon"/>|
      assert saved =~ ~s|<filter href="#icon"/>|
      assert saved =~ ~s|<linearGradient href="#icon"/>|
      refute saved =~ ~s|href="sprite.svg#mark"|
    end
  end

  test "svg scripts load href, not src, and inline imports stay inside inline scripts" do
    source = """
    <svg>
      <script href="draw.js" src="ignored.js"></script>
      <script xlink:href="fallback.js"></script>
      <script href="" xlink:href="empty.js"></script>
      <script type="module">import "./inline.js";</script>
      <script href="outer.js">import "./inner.js";</script>
      <script type="module" href="module.js"></script>
      <foreignObject><script src="app.js"></script></foreignObject>
    </svg>
    """

    assert found(source, ["js"]) == [
             {"draw.js", asset("draw.js"), "script", :script, "script"},
             {"fallback.js", asset("fallback.js"), "script", :script, "script"},
             {"./inline.js", asset("inline.js"), "script", :module, "script"},
             {"outer.js", asset("outer.js"), "script", :script, "script"},
             {"module.js", asset("module.js"), "script", :module, "script"},
             {"app.js", asset("app.js"), "script", :script, "script"}
           ]

    assert found(source, []) == []

    saved = rewrite(source, ["js"])
    assert saved =~ ~s|src="ignored.js"|
    assert saved =~ ~s|xlink:href="empty.js"|
    assert saved =~ ~s|import "./inner.js"|
    refute saved =~ ~s|import "./inline.js"|
    refute saved =~ ~s|href="draw.js"|
    refute saved =~ ~s|href="outer.js"|
    refute saved =~ ~s|src="app.js"|
    assert rewrite(source, []) =~ ~s|href="draw.js"|
  end

  test "a self-closing svg script does not hide the next image" do
    source = ~s|<svg><script href="draw.js"/><image href="icon.png"/></svg>|

    assert found(source, ["js", "images"]) == [
             {"draw.js", asset("draw.js"), "script", :script, "script"},
             {"icon.png", asset("icon.png"), "img", nil, "image"}
           ]
  end

  test "svg paint files follow href and skip same-drawing fragments" do
    source = """
    <base href="/assets/">
    <svg>
      <image href="icon.png"/>
      <use href="sprite.svg#mark"/>
      <feImage href="tex.png" xlink:href="ignored.png"/>
      <feImage xlink:href="legacy.png"/>
      <linearGradient href="paints.svg#metal"/>
      <radialGradient href="shine.svg"/>
      <pattern href="#local"/>
      <filter href="filters.svg"/>
      <a href="next.html">Next</a>
    </svg>
    """

    assert found(source, ["images"]) == [
             {"icon.png", "http://example.com/assets/icon.png", "img", nil, "image"},
             {"sprite.svg#mark", "http://example.com/assets/sprite.svg", "img", nil, "use"},
             {"tex.png", "http://example.com/assets/tex.png", "img", nil, "feimage"},
             {"legacy.png", "http://example.com/assets/legacy.png", "img", nil, "feimage"},
             {"paints.svg#metal", "http://example.com/assets/paints.svg", "img", nil,
              "lineargradient"},
             {"shine.svg", "http://example.com/assets/shine.svg", "img", nil, "radialgradient"},
             {"filters.svg", "http://example.com/assets/filters.svg", "img", nil, "filter"},
             {"next.html", "http://example.com/assets/next.html", "a", nil, "a"}
           ]

    assert found(source, []) == [
             {"next.html", "http://example.com/assets/next.html", "a", nil, "a"}
           ]

    saved = rewrite(source, ["images"])
    refute saved =~ ~s|href="tex.png"|
    refute saved =~ ~s|xlink:href="legacy.png"|
    assert saved =~ ~s|href="#local"|
    assert saved =~ ~s|xlink:href="ignored.png"|
  end

  test "a base element inside svg does not become the document base" do
    source = ~s|<svg><base href="/assets/"/><image href="icon.png"/></svg>|

    assert found(source, ["images"]) == [
             {"icon.png", asset("icon.png"), "img", nil, "image"}
           ]
  end

  test "math links are page links and a drawing inside plain math stays inert" do
    source = """
    <math>
      <mrow href="/next">Next</mrow>
      <a href="/also.html">Also</a>
      <mo href="https://other.test/out">Out</mo>
      <mrow xlink:href="/xlink.html">X</mrow>
      <mrow href="" xlink:href="/blocked.html">Empty</mrow>
    </math>
    <template><math><mrow href="/inert.html">Inert</mrow></math></template>
    <math><svg><image href="not-svg.png"/></svg></math>
    <math>
      <annotation-xml encoding="text/html"><a href="/from-math.html">In</a></annotation-xml>
    </math>
    <a href="/next">Page</a>
    <a href="https://other.test/out">Page out</a>
    """

    assert found(source, []) == [
             {"/next", "http://example.com/next", "a", nil, "a"},
             {"/also.html", "http://example.com/also.html", "a", nil, "a"},
             {"https://other.test/out", "https://other.test/out", "a", nil, "a"},
             {"/xlink.html", "http://example.com/xlink.html", "a", nil, "a"},
             {"/from-math.html", "http://example.com/from-math.html", "a", nil, "a"},
             {"/next", "http://example.com/next", "a", nil, "a"},
             {"https://other.test/out", "https://other.test/out", "a", nil, "a"}
           ]

    nofollow = """
    <meta name="robots" content="nofollow">
    <math>
      <mrow href="/next">Next</mrow>
      <a href="/also.html">Also</a>
    </math>
    <math>
      <annotation-xml encoding="text/html"><a href="/from-math.html">In</a></annotation-xml>
    </math>
    <script src="app.js"></script>
    """

    assert found(nofollow, ["js"]) == [
             {"app.js", asset("app.js"), "script", :script, "script"}
           ]

    rel = ~s|<math><mrow href="/next" rel="nofollow">N</mrow><mi href="/kept.html">K</mi></math>|

    assert found(rel, []) == [
             {"/kept.html", "http://example.com/kept.html", "a", nil, "a"}
           ]

    saved = rewrite(source, [])
    next_href = Linker.offline_link(@page, "http://example.com/next")
    out_href = Linker.offline_link(@page, "https://other.test/out")
    assert saved =~ ~s|<mrow href="#{next_href}">|
    assert saved =~ ~s|<a href="#{next_href}">Page</a>|
    assert saved =~ ~s|<mo href="#{out_href}">|
    assert saved =~ ~s|<a href="#{out_href}">Page out</a>|
    assert saved =~ ~s|href="/inert.html"|
    assert saved =~ ~s|href="not-svg.png"|
  end

  test "an svg document is parsed from its own url and a picture svg is not" do
    source = """
    <svg>
      <image href="icon.png"/>
      <script href="draw.js"></script>
      <style>g { fill: url(paint.png); }</style>
      <a href="next.html">Next</a>
    </svg>
    """

    document = %{
      url: @diagram,
      referrer_url: @diagram,
      content_type: "image/svg+xml; charset=utf-8",
      html_tag: "a",
      assets: ["css", "js", "images"]
    }

    assert found(source, document) == [
             {"icon.png", "http://example.com/icon.png", "img", nil, "image"},
             {"draw.js", "http://example.com/draw.js", "script", :script, "script"},
             {"paint.png", "http://example.com/paint.png", "link", nil, "style"},
             {"next.html", "http://example.com/next.html", "a", nil, "a"}
           ]

    for tag <- ["img", "link", "script"] do
      assert found(source, %{document | html_tag: tag}) == []
    end

    assert found(source, %{document | assets: []}) == [
             {"next.html", "http://example.com/next.html", "a", nil, "a"}
           ]

    saved = rewrite(source, document)
    refute saved =~ ~s|href="icon.png"|
    refute saved =~ ~s|href="draw.js"|
    refute saved =~ "url(paint.png)"

    picture = rewrite(source, %{document | html_tag: "img", assets: ["css", "js", "images"]})
    assert picture == source
  end

  defp found(source, assets) when is_list(assets), do: found(source, %{assets: assets})

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

  defp rewrite(source, assets) when is_list(assets), do: rewrite(source, %{assets: assets})

  defp rewrite(source, opts) do
    opts = page_opts(opts)
    opts = Map.put_new(opts, :referrer_url, opts.url)

    assert {:ok, body} = LinkReplacer.replace_links(source, opts)
    body
  end

  defp asset(name), do: "http://example.com/dir/" <> name
end
