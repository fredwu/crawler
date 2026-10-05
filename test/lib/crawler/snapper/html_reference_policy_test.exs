defmodule Crawler.Snapper.HTMLReferencePolicyTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker
  alias Crawler.Snapper.LinkReplacer

  @page "http://example.com/dir/page"

  test "rewrites only eligible element attributes when channels share the same spelling" do
    source =
      ~s|<a href="app.js">A</a><div data="app.js" href="app.js">D</div>| <>
        ~s|<script src="app.js" integrity="keep"></script>| <>
        ~s|<link rel="stylesheet" href="app.js" integrity="keep">| <>
        ~s|<img src="app.js" srcset="app.js 1x">| <>
        ~s|<div style="background:url(app.js)"></div>|

    anchor = ~s|<a href="#{offline("app.js")}">A</a>|
    assert rewrite(source, []) == String.replace(source, ~s|<a href="app.js">A</a>|, anchor)
    body = rewrite(source, ["js"])
    assert body =~ anchor
    assert body =~ ~s|<script src="#{offline("app.js")}"></script>|
    assert body =~ ~s|<link rel="stylesheet" href="app.js" integrity="keep">|
    assert body =~ ~s|<img src="app.js" srcset="app.js 1x">|
    assert body =~ ~s|<div data="app.js" href="app.js">D</div>|
    assert body =~ ~s|<div style="background:url(app.js)"></div>|
  end

  test "CSS and image channels do not rewrite excluded script sources or their integrity" do
    source =
      ~s|<script src="shared.png" integrity="keep"></script>| <>
        ~s|<link rel="stylesheet" href="shared.png" integrity="remove">| <>
        ~s|<img src="shared.png" srcset="shared.png 1x, other.png 2x">| <>
        ~s|<div srcset="shared.png 1x" style="background:url(shared.png)"></div>|

    body = rewrite(source, ["css", "images"])
    assert body =~ ~s|<script src="shared.png" integrity="keep"></script>|
    assert body =~ ~s|<link rel="stylesheet" href="#{offline("shared.png")}">|
    assert body =~ ~s|srcset="#{offline("shared.png")} 1x, #{offline("other.png")} 2x"|

    assert body =~
             ~s|<div srcset="shared.png 1x" style="background:url(#{offline("shared.png")})"></div>|
  end

  test "preserves data blocks and external inline bodies beside eligible imports" do
    ignored = ~s|import './shared.js';|

    source =
      ~s|<script type="application/ld+json" src="./shared.js">#{ignored}</script>| <>
        ~s|<script type="module" src="app.js">#{ignored}</script>| <>
        ~s|<script type="module">#{ignored}</script>|

    body = rewrite(source, ["js"])

    assert body ==
             ~s|<script type="application/ld+json" src="./shared.js">#{ignored}</script>| <>
               ~s|<script type="module" src="#{offline("app.js")}">#{ignored}</script>| <>
               ~s|<script type="module">import '#{offline("shared.js")}';</script>|
  end

  test "rewrites style attributes on script and style while preserving excluded sources" do
    source =
      ~s|<script src="app.js" style="background:url(shared.png)">import './shared.js';</script>| <>
        ~s|<style style="background:url(shared.png)">a{background:url(shared.png)}</style>|

    expected = String.replace(source, "url(shared.png)", "url(#{offline("shared.png")})")
    assert rewrite(source, ["css"]) == expected
    assert rewrite(source, []) == source
  end

  test "keeps foreign attributes and raw text separate from eligible SVG resources" do
    source =
      ~s|<svg><script src="image.png"/><image href="image.png" data="image.png"/>| <>
        ~s|<![CDATA[<image href="image.png"/>]]></svg>| <>
        ~s|<math><a href="image.png">M</a></math><a href="image.png">A</a>|

    expected =
      ~s|<svg><script src="image.png"/><image href="#{offline("image.png")}" data="image.png"/>| <>
        ~s|<![CDATA[<image href="image.png"/>]]></svg>| <>
        ~s|<math><a href="image.png">M</a></math><a href="#{offline("image.png")}">A</a>|

    assert rewrite(source, ["images", "js"]) == expected
  end

  test "repeated references and distinct source spellings keep complete saved targets" do
    source =
      ~s|<a href="other">A</a><a href="other">B</a><a href="./other">C</a>| <>
        ~s|<a href="other?x=1&amp;y=2">D</a><a href="other?x=1&#38;y=2">E</a>|

    target = offline("other")
    query = offline("other?x=1&y=2")

    assert rewrite(source, []) ==
             ~s|<a href="#{target}">A</a><a href="#{target}">B</a><a href="#{target}">C</a>| <>
               ~s|<a href="#{query}">D</a><a href="#{query}">E</a>|
  end

  test "keeps ignored duplicate URL and CSS attributes byte-identical" do
    source =
      ~s|<a href="one" href="two">A</a><a href="two">B</a>| <>
        ~s|<div style="background:url(one)" style="background:url(two)"></div>| <>
        ~s|<script src="one" src="two" integrity="first" integrity="second"></script>|

    assert rewrite(source, ["css", "js"]) ==
             ~s|<a href="#{offline("one")}" href="two">A</a><a href="#{offline("two")}">B</a>| <>
               ~s|<div style="background:url(#{offline("one")})" style="background:url(two)"></div>| <>
               ~s|<script src="#{offline("one")}" src="two"></script>|
  end

  test "removes all duplicate integrity fields only on rewritten eligible resources" do
    source =
      ~s|<a href="app.js">A</a>| <>
        ~s|<script src="app.js" integrity="first" integrity='second'></script>| <>
        ~s|<script src="data:text/javascript,void(0)" integrity="third" integrity=fourth></script>|

    anchor = ~s|<a href="#{offline("app.js")}">A</a>|
    assert rewrite(source, []) == String.replace(source, ~s|<a href="app.js">A</a>|, anchor)

    assert rewrite(source, ["js"]) ==
             anchor <>
               ~s|<script src="#{offline("app.js")}"></script>| <>
               ~s|<script src="data:text/javascript,void(0)" integrity="third" integrity=fourth></script>|
  end

  test "script type and language precedence also select saved source rewrites" do
    ignored = ~s|import './shared.js';|

    source =
      ~s|<a href="shared.js">A</a>| <>
        ~s|<script language="json" src="shared.js" integrity="keep">#{ignored}</script>| <>
        ~s|<script language="json">#{ignored}</script>| <>
        ~s|<script type="&#160;module&#160;" src="shared.js" integrity="keep">#{ignored}</script>| <>
        ~s|<script type="&#160;text/javascript&#160;">#{ignored}</script>| <>
        ~s|<script language="JavaScript" src="shared.js" integrity="remove"></script>| <>
        ~s|<script language="JavaScript">#{ignored}</script>| <>
        ~s|<script type="" language="json" src="shared.js" integrity="remove"></script>| <>
        ~s|<script type="" language="json">#{ignored}</script>|

    target = offline("shared.js")

    expected =
      ~s|<a href="#{target}">A</a>| <>
        ~s|<script language="json" src="shared.js" integrity="keep">#{ignored}</script>| <>
        ~s|<script language="json">#{ignored}</script>| <>
        ~s|<script type="&#160;module&#160;" src="shared.js" integrity="keep">#{ignored}</script>| <>
        ~s|<script type="&#160;text/javascript&#160;">#{ignored}</script>| <>
        ~s|<script language="JavaScript" src="#{target}"></script>| <>
        ~s|<script language="JavaScript">import '#{target}';</script>| <>
        ~s|<script type="" language="json" src="#{target}"></script>| <>
        ~s|<script type="" language="json">import '#{target}';</script>|

    assert rewrite(source, ["js"]) == expected
  end

  defp rewrite(source, assets) do
    assert {:ok, body} =
             LinkReplacer.replace_links(source, %{
               url: @page,
               referrer_url: @page,
               content_type: "text/html",
               html_tag: "a",
               assets: assets
             })

    body
  end

  defp offline(path), do: Linker.offline_link(@page, "http://example.com/dir/" <> path)
end
