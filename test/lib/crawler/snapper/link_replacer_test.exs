defmodule Crawler.Snapper.LinkReplacerTest do
  use ExUnit.Case, async: true

  alias Crawler.Snapper.LinkReplacer

  doctest LinkReplacer

  test "preserves absolute links that contain regex characters" do
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

    assert body == "<a href='http://example.com/search?q=1'></a>"
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

    assert body =~ "href='http://host/dir/next'"
    assert body =~ "href='http://cdn.example/lib.js'"
    assert body =~ "href='http://host/dir/page#a'"
    refute body =~ "href='next'"
    refute body =~ "href='//cdn.example/lib.js'"
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
    assert body =~ "http://host/search?q&#61;1&amp;x&#61;2"
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
    image = "http://host/dir/a.png"

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
    shown = "http://host/dir/shown.png"
    also = "http://host/dir/also.png"

    refute body =~ ~s|url("shown.png")|
    refute body =~ ~s|url("also.png")|
    assert body =~ shown
    assert body =~ also
    assert body =~ "var(--icon)"
  end

  test "a later style element rewrites an unregistered picture" do
    scope = System.unique_integer([:positive])

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
    shown = "http://host/dir/shown.png"

    refute body =~ ~s|url("shown.png")|
    assert body =~ ~s|url("idle.png")|
    assert body =~ shown
    assert body =~ "var(--bg)"
    assert body =~ "var(--idle)"
  end

  test "a srcdoc rewrites a picture used by a later style element" do
    scope = System.unique_integer([:positive])

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
    shown = "http://host/dir/shown.png"

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

  test "standalone online script and stylesheet references keep integrity and strip userinfo" do
    source =
      ~s|<script src="app.js" integrity="script"></script>| <>
        ~s|<link rel="stylesheet" href="https://cdn.test/app.css" integrity="style">|

    assert {:ok, body} =
             LinkReplacer.replace_links(source, %{
               url: "https://user:secret@example.test/dir/page",
               content_type: "text/html",
               html_tag: "a",
               assets: ["js", "css"]
             })

    assert body ==
             ~s|<script src="https://example.test/dir/app.js" integrity="script"></script>| <>
               ~s|<link rel="stylesheet" href="https://cdn.test/app.css" integrity="style">|

    refute body =~ "user"
    refute body =~ "secret"
  end

  test "bound successful targets become local while failed and absent targets stay online" do
    source =
      ~s|<script src="ok.js" integrity="ok"></script>| <>
        ~s|<script src="failed.js" integrity="failed"></script>| <>
        ~s|<a href="missing#section">Missing</a>|

    opts = %{
      url: "https://user:secret@example.test/dir/page",
      content_type: "text/html",
      html_tag: "a",
      assets: ["js"]
    }

    assert {:ok, body} =
             Crawler.StandaloneRewriteHelpers.replace_bound(
               source,
               opts,
               fn
                 %{value: "ok.js"} -> :successful_script
                 %{value: "failed.js"} -> :failed_script
                 %{value: "missing#section"} -> nil
               end,
               %{successful_script: {:ok, "fixtures/app.js"}, failed_script: {:error, :not_found}}
             )

    assert body ==
             ~s|<script src="fixtures/app.js"></script>| <>
               ~s|<script src="https://example.test/dir/failed.js" integrity="failed"></script>| <>
               ~s|<a href="https://example.test/dir/missing#section">Missing</a>|

    refute body =~ "user"
    refute body =~ "secret"
  end

  test "one URL can bind a successful script and a failed image independently" do
    source = ~s|<script src="same" integrity="script"></script><img src="same">|

    opts = %{
      url: "https://example.test/page",
      content_type: "text/html",
      html_tag: "a",
      assets: ["js", "images"]
    }

    assert {:ok, body} =
             Crawler.StandaloneRewriteHelpers.replace_bound(
               source,
               opts,
               fn
                 %{context: %{html_tag: "script"}} -> :script
                 %{context: %{html_tag: "img"}} -> :image
               end,
               %{script: {:ok, "fixtures/script.js"}, image: {:error, :failed}}
             )

    assert body ==
             ~s|<script src="fixtures/script.js"></script><img src="https://example.test/same">|
  end

  test "a successful local resolution that keeps the source value also keeps integrity" do
    source = ~s|<script src="app.js" integrity="original"></script>|

    opts = %{
      url: "https://example.test/page",
      content_type: "text/html",
      html_tag: "a",
      assets: ["js"]
    }

    assert {:ok, ^source} =
             Crawler.StandaloneRewriteHelpers.replace_bound(
               source,
               opts,
               fn %{value: "app.js"} -> :script end,
               %{script: {:ok, "app.js"}}
             )
  end

  test "a local resolver cannot rewrite an occurrence without a bound target" do
    source = ~s|<a href="next#section">Next</a>|
    opts = %{url: "https://example.test/page", content_type: "text/html", html_tag: "a"}
    assert {:ok, prepared} = Crawler.Parser.prepare_for_parse(source, opts)

    assert {:error, :unbound_local_target} =
             LinkReplacer.replace_prepared(prepared, fn _occurrence ->
               {:local, "fixtures/next.html"}
             end)

    assert {:ok, ~s|<a href="https://example.test/next#section">Next</a>|} =
             LinkReplacer.replace_prepared(prepared, &Crawler.Analysis.online_fallback/1)
  end
end
