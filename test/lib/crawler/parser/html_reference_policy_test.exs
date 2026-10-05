defmodule Crawler.Parser.HTMLReferencePolicyTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser
  alias Crawler.Parser.HtmlParser

  @page "http://example.com/dir/page"

  test "keeps navigation and CSS roles for the same spelling on one element" do
    source = ~s|<a href="asset.png" style="background:url(asset.png)">A</a>|

    assert references(source, ["css"]) == [
             {"asset.png", "http://example.com/dir/asset.png", "a"},
             {"asset.png", "http://example.com/dir/asset.png", "link"}
           ]
  end

  test "script source selection excludes data blocks and ignores external inline bodies" do
    source = """
    <script type="application/ld+json" src="ignored.json">import './ignored.js';</script>
    <script type="module" src="app.js">import './ignored.js';</script>
    <script src="">import './empty-source.js';</script>
    <script type="Text/JavaScript">import './classic.js';</script>
    <script type="module">import './module.js';</script>
    """

    assert references(source, ["js"]) == [
             {"app.js", "http://example.com/dir/app.js", "script"},
             {"./classic.js", "http://example.com/dir/classic.js", "script"},
             {"./module.js", "http://example.com/dir/module.js", "script"}
           ]

    assert references(source, []) == []
  end

  test "CSS style attributes compose with script and style sources" do
    source = """
    <script type="application/ld+json" style="background:url(script.png)">{}</script>
    <style style="background:url(style.png)">a {background:url(text.png)}</style>
    """

    assert references(source, ["css"]) == [
             {"script.png", "http://example.com/dir/script.png", "link"},
             {"style.png", "http://example.com/dir/style.png", "link"},
             {"text.png", "http://example.com/dir/text.png", "link"}
           ]

    assert references(source, ["js"]) == []
  end

  test "foreign elements use their own URL attributes and retain HTML integration points" do
    source = """
    <svg><image href="image.png"/><use xlink:href="sprite.svg#mark"/>
    <script src="ignored.js"/><a href="next">A</a>
    <foreignObject><script src="app.js"></script></foreignObject></svg>
    <math><a href="ignored">A</a></math>
    """

    assert references(source, ["js", "images"]) == [
             {"image.png", "http://example.com/dir/image.png", "img"},
             {"sprite.svg#mark", "http://example.com/dir/sprite.svg", "img"},
             {"next", "http://example.com/dir/next", "a"},
             {"app.js", "http://example.com/dir/app.js", "script"}
           ]
  end

  test "unquoted slash-close URLs keep their source slash" do
    assert references(~s|<img src=icon.png/>|, ["images"]) == [
             {"icon.png/", "http://example.com/dir/icon.png/", "img"}
           ]
  end

  test "public tuples preserve raw script boundaries and required children" do
    script = ~s|<!--<script></script><a href="ignored">I</a>-->|
    source = ~s|<script>#{script}</script><a href="next">Next</a>|

    assert HtmlParser.parse(source, %{assets: ["js"]}) == [
             {"script", [], [script]},
             {"a", [{"href", "next"}], ["Next"]}
           ]
  end

  test "discovery and public tuples use the first active duplicate attribute" do
    source = ~s|<a href="one" href="two">A</a><a href="two">B</a>|

    assert references(source, []) == [
             {"one", "http://example.com/dir/one", "a"},
             {"two", "http://example.com/dir/two", "a"}
           ]

    assert HtmlParser.parse(source, %{}) == [
             {"a", [{"href", "one"}], ["A"]},
             {"a", [{"href", "two"}], ["B"]}
           ]
  end

  test "public tuples preserve children after an unquoted terminal slash" do
    assert HtmlParser.parse(~s|<a href=next/>Next</a>|, %{}) == [
             {"a", [{"href", "next/"}], ["Next"]}
           ]
  end

  test "script type precedence and ASCII whitespace determine executable sources" do
    source = """
    <script language="json" src="ignored.json">import './ignored.js';</script>
    <script language="json">import './ignored.js';</script>
    <script language="JavaScript" src="classic.js"></script>
    <script language="JavaScript">import './language.js';</script>
    <script type="" language="json" src="empty-type.js"></script>
    <script type="" language="json">import './empty-type-inline.js';</script>
    <script type=" module " language="json">import './module.js';</script>
    <script type="&#160;module&#160;" src="ignored.js">import './ignored.js';</script>
    <script type="&#160;text/javascript&#160;">import './ignored.js';</script>
    <script type=" " language="javascript" src="ignored.js"></script>
    <script type="text/javascript; charset=utf-8" src="ignored.js"></script>
    <script language=" javascript" src="ignored.js"></script>
    """

    assert references(source, ["js"]) == [
             {"classic.js", "http://example.com/dir/classic.js", "script"},
             {"./language.js", "http://example.com/dir/language.js", "script"},
             {"empty-type.js", "http://example.com/dir/empty-type.js", "script"},
             {"./empty-type-inline.js", "http://example.com/dir/empty-type-inline.js", "script"},
             {"./module.js", "http://example.com/dir/module.js", "script"}
           ]
  end

  defp references(source, assets) do
    source
    |> Parser.parse_links(
      %{url: @page, content_type: "text/html", html_tag: "a", assets: assets},
      fn
        {_, raw, _, url}, opts -> {raw, url, opts.html_tag}
        {_, url}, opts -> {url, url, opts.html_tag}
      end
    )
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end
end
