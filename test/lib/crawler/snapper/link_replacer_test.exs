defmodule Crawler.Snapper.LinkReplacerTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker
  alias Crawler.Parser.CssSheets
  alias Crawler.Snapper.LinkReplacer

  doctest LinkReplacer

  test "rewrites links that contain regex characters" do
    assert {:ok, body} =
             LinkReplacer.replace_links(
               "<a href='http://example.com/search?q=1'></a>",
               %{
                 url: "http://example.com/dir/page",
                 depth: 1,
                 max_depths: 2,
                 html_tag: "a",
                 content_type: "text/html",
                 referrer_url: "http://example.com/dir/page"
               }
             )

    assert body =~
             Linker.offline_link("http://example.com/dir/page", "http://example.com/search?q=1")

    refute body =~ "href='http://example.com/search?q=1'"
  end

  test "rewrites links against the resolved url" do
    opts = %{
      url: "http://host/old",
      referrer_url: "http://host/dir/page",
      depth: 1,
      max_depths: 2,
      html_tag: "a",
      content_type: "text/html",
      assets: ["js"]
    }

    assert {:ok, body} =
             LinkReplacer.replace_links(
               "<a href='next'></a><a href='//cdn.example/lib.js'></a><a href='http://host/dir/page#a'></a>",
               opts
             )

    assert body =~ "href='../../host/dir/next/__index.html'"
    assert body =~ "href='../../cdn.example/lib.js'"
    assert body =~ "href='../../host/dir/page/__index.html#a'"
    refute body =~ "href='next'"
    refute body =~ "//cdn.example/lib.js"
    refute body =~ "href='http://host/dir/page#a'"
  end

  test "rewrites srcset, style urls, and html-escaped queries" do
    opts = %{
      url: "http://host/dir/page",
      referrer_url: "http://host/dir/page",
      depth: 1,
      max_depths: 3,
      html_tag: "a",
      content_type: "text/html",
      assets: ["images", "css"]
    }

    html = """
    <img src="a.jpg" srcset="a.jpg 1x, b.jpg 2x">
    <div style="background: url('bg2.png')"></div>
    <a href="/search?q=1&amp;x=2"></a>
    """

    assert {:ok, body} = LinkReplacer.replace_links(html, opts)

    refute body =~ ~s|srcset="a.jpg 1x, b.jpg 2x"|
    refute body =~ "url('bg2.png')"
    refute body =~ ~s|href="/search?q=1&amp;x=2"|
    assert body =~ "b.jpg"
    assert body =~ "bg2.png"
    assert body =~ Linker.offline_link(opts.url, "http://host/search?q=1&x=2")
  end

  test "rewrites style attributes without changing CSS examples in text or other attributes" do
    opts = %{
      url: "http://host/dir/page",
      referrer_url: "http://host/dir/page",
      depth: 1,
      max_depths: 3,
      html_tag: "a",
      content_type: "text/html",
      assets: ["images", "css"]
    }

    html = """
    <img src="a.png">
    <p>url("a.png"), image-set("a.png" 1x), @import "theme.css";</p>
    <div title="style=url('a.png')" data-note="image-set('a.png' 1x)"
         STYLE="background:url(&quot;a.png&quot;); background-image:image-set(&quot;a.png&quot; 1x); @import &quot;theme.css&quot;;"></div>
    <div style=background:url(a.png)></div>
    """

    assert {:ok, body} = LinkReplacer.replace_links(html, opts)
    image = Linker.offline_link(opts.url, "http://host/dir/a.png")

    assert body =~ ~s|<p>url("a.png"), image-set("a.png" 1x), @import "theme.css";</p>|
    assert body =~ ~s|title="style=url('a.png')"|
    assert body =~ ~s|data-note="image-set('a.png' 1x)"|
    assert body =~ ~s|src="#{image}"|
    assert body =~ "url(&quot;#{image}&quot;)"
    assert body =~ "image-set(&quot;#{image}&quot; 1x)"
    assert body =~ "@import &quot;theme.css&quot;;"
    assert body =~ ~s|style=background:url(#{image})|
  end

  test "a later style element rewrites a registered picture" do
    scope = System.unique_integer([:positive])
    on_exit(fn -> CssSheets.drop(scope) end)

    opts = %{
      url: "http://host/dir/page",
      referrer_url: "http://host/dir/page",
      scope: scope,
      depth: 1,
      max_depths: 3,
      html_tag: "a",
      content_type: "text/html",
      assets: ["css", "images"]
    }

    html = """
    <style>
      @property --icon { syntax: "<url>"; inherits: true; }
      :root { --icon: url("shown.png"); }
    </style>
    <style>
      body { background: var(--icon); background-image: url("also.png"); }
    </style>
    """

    assert {:ok, body} = LinkReplacer.replace_links(html, opts)
    shown = Linker.offline_link(opts.url, "http://host/dir/shown.png")
    also = Linker.offline_link(opts.url, "http://host/dir/also.png")

    refute body =~ ~s|url("shown.png")|
    refute body =~ ~s|url("also.png")|
    assert body =~ shown
    assert body =~ also
    assert body =~ "var(--icon)"
  end

  test "a later style element rewrites an unregistered picture" do
    scope = System.unique_integer([:positive])
    on_exit(fn -> CssSheets.drop(scope) end)

    opts = %{
      url: "http://host/dir/page",
      referrer_url: "http://host/dir/page",
      scope: scope,
      depth: 1,
      max_depths: 3,
      html_tag: "a",
      content_type: "text/html",
      assets: ["css", "images"]
    }

    html = """
    <style>
      :root { --bg: url("shown.png"); --idle: url("idle.png"); }
    </style>
    <style>
      body { background: var(--bg); color: var(--idle); }
    </style>
    """

    assert {:ok, body} = LinkReplacer.replace_links(html, opts)
    shown = Linker.offline_link(opts.url, "http://host/dir/shown.png")

    refute body =~ ~s|url("shown.png")|
    assert body =~ ~s|url("idle.png")|
    assert body =~ shown
    assert body =~ "var(--bg)"
    assert body =~ "var(--idle)"
  end

  test "a srcdoc rewrites a picture used by a later style element" do
    scope = System.unique_integer([:positive])
    on_exit(fn -> CssSheets.drop(scope) end)

    opts = %{
      url: "http://host/dir/page",
      referrer_url: "http://host/dir/page",
      document_url: "http://host/dir/page",
      scope: scope,
      depth: 1,
      max_depths: 3,
      html_tag: "a",
      content_type: "text/html",
      assets: ["css", "images"]
    }

    html =
      ~s|<iframe srcdoc="<style>:root { --bg: url(&quot;shown.png&quot;); --idle: url(&quot;idle.png&quot;); }</style><style>body { background: var(--bg); color: var(--idle); }</style>"></iframe>|

    assert {:ok, body} = LinkReplacer.replace_links(html, opts)
    shown = Linker.offline_link(opts.url, "http://host/dir/shown.png")

    refute body =~ "url(&quot;shown.png&quot;)"
    assert body =~ "url(&quot;idle.png&quot;)"
    assert body =~ shown
    assert body =~ "var(--bg)"
  end

  test "does not rewrite prose and keeps every spelling of one url" do
    opts = %{
      url: "http://host/dir/page",
      referrer_url: "http://host/dir/page",
      depth: 1,
      max_depths: 3,
      html_tag: "a",
      content_type: "text/html",
      assets: ["images", "css"]
    }

    html = """
    <p>See a.jpg today. See "a.jpg" today.</p>
    <img src="./a.jpg" srcset="a.jpg 1x, b.jpg 2x">
    <div style="background: url(&quot;q.png&quot;)"></div>
    <div style="background: url(&quot;q.png&quot;); @import &#39;other.css&#39;;"></div>
    """

    assert {:ok, body} = LinkReplacer.replace_links(html, opts)

    assert body =~ "See a.jpg today"
    assert body =~ "See \"a.jpg\" today"
    refute body =~ "srcset=\"a.jpg 1x"
    refute body =~ "url(&quot;q.png&quot;)"
    refute body =~ "&quot;q.png&quot;"
    assert body =~ "&#39;other.css&#39;"
    assert body =~ "a.jpg"
    assert body =~ "b.jpg"
    assert body =~ "q.png"
  end
end
