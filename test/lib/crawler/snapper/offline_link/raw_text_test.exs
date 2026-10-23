defmodule Crawler.Snapper.OfflineLink.RawTextTest do
  use Crawler.OfflineLinkCase, async: true

  alias Crawler.Charset
  alias Crawler.Parser
  alias Crawler.Snapper.LinkReplacer

  test "keeps raw style and script queries separate from decoded attributes" do
    html = """
    <base href="https://cdn.example/assets/">
    <style>.raw { background: url("asset.png?x=1&amp;y=2#part") }</style>
    <div style="background:url(&quot;asset.png?x=1&amp;y=2#part&quot;)"></div>
    <script type="module">import "./module.js?x=1&amp;y=2"; const example = '<base href="keep/">';</script>
    <script src="./module.js?x=1&amp;y=2"></script>
    """

    body = rewrite(html, @page)

    raw_asset =
      "https://cdn.example/assets/asset.png?x=1&amp;y=2#part"

    attr_asset = "https://cdn.example/assets/asset.png?x&#61;1&amp;y&#61;2#part"
    raw_script = "https://cdn.example/assets/module.js?x=1&amp;y=2"
    attr_script = "https://cdn.example/assets/module.js?x&#61;1&amp;y&#61;2"

    refute body =~ ~s|<base href="https://cdn.example/assets/">|
    assert body =~ ~s|const example = '<base href="keep/">';|
    refute raw_asset == attr_asset
    refute raw_script == attr_script
    assert body =~ ~s|<style>.raw { background: url("#{raw_asset}") }</style>|
    assert body =~ "background:url(&quot;#{attr_asset}&quot;)"

    assert body =~
             ~s|<script type="module">import "#{raw_script}"; const example = '<base href="keep/">';</script>|

    assert body =~ ~s|<script src="#{attr_script}"></script>|
  end

  test "resolves raw text against a redirect landing referrer" do
    assert {:ok, body} =
             LinkReplacer.replace_links(
               ~s|<style>.a { background: url("asset.png") }</style><script>import("./app.js"); import "./stay.js";</script>|,
               %{
                 url: @page,
                 referrer_url: "https://cdn.example/landing/page.html",
                 content_type: "text/html",
                 html_tag: "a",
                 assets: ["css", "js"],
                 depth: 1,
                 max_depths: 3
               }
             )

    assert_points(body, @page, "https://cdn.example/landing/asset.png")
    assert_points(body, @page, "https://cdn.example/landing/app.js")
    assert body =~ ~s|import "./stay.js"|
  end

  test "leaves disabled raw text and non-javascript scripts intact" do
    html = """
    <a href="asset.png?x=1&amp;y=2"></a>
    <style>.a { background: url("asset.png?x=1&y=2") }</style>
    <script type="module">import "./asset.js";</script>
    <script type="application/ld+json">{"note": "asset.png?x=1&amp;y=2"}</script>
    """

    assert {:ok, body} =
             LinkReplacer.replace_links(html, %{
               url: @page,
               referrer_url: @page,
               content_type: "text/html",
               html_tag: "a",
               assets: [],
               depth: 1,
               max_depths: 3
             })

    assert body =~ ~s|<style>.a { background: url("asset.png?x=1&y=2") }</style>|
    assert body =~ ~s|<script type="module">import "./asset.js";</script>|
    assert body =~ ~s|{"note": "asset.png?x=1&amp;y=2"}|
    assert_points(body, @page, "http://example.com/blog/asset.png?x=1&y=2")
  end

  for {type, tag, source} <- [
        {"text/css", "link",
         ~s|.a{background:url("asset.png?x=1&y=2")} .b{background:url("asset.png?x=1&amp;y=2")}|},
        {"application/javascript", "script",
         ~s|import "./asset.js?x=1&y=2"; import "./asset.js?x=1&amp;y=2";|}
      ] do
    test "keeps literal query spellings in standalone #{type}" do
      type = unquote(type)
      tag = unquote(tag)
      source = unquote(source)
      filename = if tag == "link", do: "asset.png", else: "asset.js"
      body = rewrite(source, @page, type, tag)
      decoded = "http://example.com/blog/#{filename}?x=1&y=2"
      literal = "http://example.com/blog/#{filename}?x=1&amp;y=2"

      refute decoded == literal
      assert occurrences(body, decoded) == 1
      assert occurrences(body, literal) == 1
    end
  end

  test "keeps literal quote spellings in CSS sources and JavaScript payloads" do
    css =
      ~s|.a{background:url('asset.png?name="Reilly"')} .b{background:url('asset.png?name=&quot;Reilly&quot;')}|

    quoted = ~s|http://example.com/blog/asset.png?name=%22Reilly%22|

    entity =
      "http://example.com/blog/asset.png?name=&quot;Reilly&quot;"

    expected_css = ~s|.a{background:url('#{quoted}')} .b{background:url('#{entity}')}|

    refute quoted == entity
    assert rewrite(css, @page, "text/css", "link") == expected_css
    assert rewrite("<style>#{css}</style>", @page) == "<style>#{expected_css}</style>"

    specifier = "./asset.js?name=&quot;Reilly&quot;"
    js = ~s|const note='asset.js?name="Reilly"';import '#{specifier}';|

    offline =
      "http://example.com/blog/asset.js?name=&quot;Reilly&quot;"

    expected_js = String.replace(js, "import '#{specifier}'", "import '#{offline}'")

    assert rewrite(js, @page, "application/javascript", "script") == expected_js

    assert rewrite(~s|<script type="module">#{js}</script>|, @page) ==
             ~s|<script type="module">#{expected_js}</script>|
  end

  for {prefix, source, target} <- [
        {~s|<div title="<script>"></div>|,
         ~s|<script type="module">import "./asset.js";</script>|, "asset.js"},
        {~s|<div title="<style>"></div>|, ~s|<style>.a{background:url("asset.png")}</style>|,
         "asset.png"},
        {"<!-- <script> -->", ~s|<script type="module">import "./asset.js";</script>|,
         "asset.js"},
        {"<!-- <style> -->", ~s|<style>.a{background:url("asset.png")}</style>|, "asset.png"}
      ] do
    test "keeps fake raw tag #{prefix} and rewrites the real links" do
      prefix = unquote(prefix)
      source = unquote(source)
      body = rewrite(prefix <> ~s|<a href="next.html">next</a>| <> source, @page)
      next = "http://example.com/blog/next.html"
      target = "http://example.com/blog/" <> unquote(target)
      reference = if unquote(target) == "asset.js", do: "./asset.js", else: "asset.png"

      assert body ==
               prefix <>
                 ~s|<a href="#{next}">next</a>| <> String.replace(source, reference, target)

      assert_points(body, @page, "http://example.com/blog/next.html")
      assert_points(body, @page, "http://example.com/blog/" <> unquote(target))
    end
  end

  test "rewrites a raw style through EOF without adding a closing tag" do
    source = ~s|<style>.a{background:url("asset.png")}|
    body = rewrite(source, @page)
    target = "http://example.com/blog/asset.png"

    assert body == ~s|<style>.a{background:url("#{target}")}|
    assert_points(body, @page, "http://example.com/blog/asset.png")
  end

  test "keeps an EOF comment with a fake raw opener intact" do
    comment = ~s|<!-- <style>.a{background:url("next.html")}|
    body = rewrite(~s|<a href="next.html">next</a>| <> comment, @page)
    target = "http://example.com/blog/next.html"

    assert body == ~s|<a href="#{target}">next</a>| <> comment
    assert_points(body, @page, "http://example.com/blog/next.html")
  end

  for tag <- ~w(textarea title xmp iframe noembed noframes TEXTAREA TiTlE) do
    test "keeps literal markup inside #{tag} and rewrites the following anchor" do
      tag = unquote(tag)
      literal = "<#{tag}><script><a href=\"next.html\">literal</a></#{tag}>"
      body = rewrite(literal <> ~s|<a href="next.html">next</a>|, @page)
      target = "http://example.com/blog/next.html"

      assert body == literal <> ~s|<a href="#{target}">next</a>|
      assert_points(body, @page, "http://example.com/blog/next.html")
    end
  end

  test "keeps plaintext markup literal through EOF" do
    literal = ~s|<plaintext><script></plaintext><a href="next.html">literal</a>|
    body = rewrite(~s|<a href="next.html">next</a>| <> literal, @page)
    target = "http://example.com/blog/next.html"

    assert body == ~s|<a href="#{target}">next</a>| <> literal
    assert_points(body, @page, "http://example.com/blog/next.html")
  end

  test "rewrites a Latin-1 script and the following anchor after response decoding" do
    html = "<script>var caf" <> <<0xE9>> <> "=1; import(\"./a.js\");</script><a href=\"p.html\">"

    decoded =
      Charset.decode(html, %{
        content_type: "text/html",
        headers: [{"content-type", "text/html; charset=latin1"}]
      })

    assert decoded == ~s|<script>var café=1; import("./a.js");</script><a href="p.html">|
    body = rewrite(decoded, @page)

    assert body =~ "var café=1;"
    assert_points(body, @page, "http://example.com/blog/p.html")
    assert_points(body, @page, "http://example.com/blog/a.js")
  end

  test "undecoded invalid UTF-8 HTML returns a tagged error before discovery or rewriting" do
    html = "<script>var caf" <> <<0xE9>> <> "=1; import(\"./a.js\");</script><a href=\"p.html\">"
    opts = %{url: @page, content_type: "text/html", html_tag: "a", assets: ["js"]}

    assert Parser.parse_links(html, opts, fn _, _ -> flunk("invalid source reached discovery") end) ==
             {:error, :invalid_utf8}

    assert LinkReplacer.replace_links(html, opts) == {:error, :invalid_utf8}
  end
end
