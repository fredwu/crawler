defmodule Crawler.Snapper.OfflineLink.HtmlTest do
  use Crawler.OfflineLinkCase, async: true

  test "keeps fragments on anchors and svg sprites" do
    html = """
    <a href="post.html?q=1#section"></a>
    <a href="#top"></a>
    <svg><use href="icons.svg#a"></use><use xlink:href="sprite.svg#b"></use></svg>
    """

    body = rewrite(html, @page)

    assert_points(body, @page, "http://example.com/blog/post.html?q=1", "#section")
    assert_points(body, @page, @page, "#top")
    assert_points(body, @page, "http://example.com/blog/icons.svg", "#a")
    assert_points(body, @page, "http://example.com/blog/sprite.svg", "#b")
    refute body =~ "post.html?q=1#section"
    refute body =~ ~s(href="#top")
    refute body =~ ~s(href="icons.svg#a")
    refute body =~ ~s(xlink:href="sprite.svg#b")
  end

  test "rewrites unquoted links from a directory index" do
    body = rewrite(~s(<img src=plain.png><a href=other.html></a>), @page)

    refute body =~ "src=plain.png"
    refute body =~ "href=other.html"
    assert_points(body, @page, "http://example.com/blog/plain.png")
    assert_points(body, @page, "http://example.com/blog/other.html")
  end

  test "rewrites imagesrcset, image-set, object, embed, and meta refresh" do
    html = """
    <link rel="preload" as="image" imagesrcset="a.jpg 1x, b.jpg 2x">
    <object data="file.pdf"></object>
    <embed src="movie.mp4"></embed>
    <meta http-equiv="refresh" content="0; url=next.html">
    <meta http-equiv="Refresh" content="5; URL='later.html'">
    <style>div { background: image-set("wide.png" 1x, "narrow.png" 2x); }</style>
    """

    body = rewrite(html, @page)

    refute body =~ ~s(imagesrcset="a.jpg 1x, b.jpg 2x")
    refute body =~ ~s(data="file.pdf")
    refute body =~ ~s(src="movie.mp4")
    refute body =~ "url=next.html"
    refute body =~ "URL='later.html'"
    refute body =~ ~s|image-set("wide.png" 1x, "narrow.png" 2x)|
    assert body =~ "1x"
    assert body =~ "2x"
    assert_points(body, @page, "http://example.com/blog/a.jpg")
    assert_points(body, @page, "http://example.com/blog/b.jpg")
    assert_points(body, @page, "http://example.com/blog/file.pdf")
    assert_points(body, @page, "http://example.com/blog/movie.mp4")
    assert_points(body, @page, "http://example.com/blog/next.html")
    assert_points(body, @page, "http://example.com/blog/later.html")
    assert_points(body, @page, "http://example.com/blog/wide.png")
    assert_points(body, @page, "http://example.com/blog/narrow.png")
  end

  test "rewrites an unquoted image-set and leaves a refresh url in prose" do
    html = """
    <p>See url=next.html today</p>
    <meta http-equiv="refresh" content="0; url=next.html">
    <style>div { background: image-set(wide.png 1x, narrow.png 2x); }</style>
    """

    body = rewrite(html, @page)

    assert body =~ "See url=next.html today"
    refute body =~ ~s(content="0; url=next.html")
    refute body =~ "image-set(wide.png 1x, narrow.png 2x)"
    assert body =~ "1x"
    assert_points(body, @page, "http://example.com/blog/next.html")
    assert_points(body, @page, "http://example.com/blog/wide.png")
    assert_points(body, @page, "http://example.com/blog/narrow.png")
  end

  test "keeps distinct letter case inside hex image-set quotes" do
    html =
      ~s|<div style="background: image-set(&#x27;A.png&#x27; 1x, &#x27;a.png&#x27; 2x)"></div>|

    body = rewrite(html, @page)

    assert_points(body, @page, "http://example.com/blog/A.png")
    assert_points(body, @page, "http://example.com/blog/a.png")
  end

  test "rewrites apostrophe entities in refresh and style attributes" do
    html =
      ~s|<meta http-equiv="refresh" content="0; URL=&apos;later.html&apos;"><div style="background: url(&apos;a.png&apos;)"></div><div style="background: image-set(&apos;b.png&apos; 1x)"></div>|

    body = rewrite(html, @page)

    refute body =~ "&apos;later.html&apos;"
    refute body =~ "&apos;a.png&apos;"
    refute body =~ "&apos;b.png&apos;"
    assert_points(body, @page, "http://example.com/blog/later.html")
    assert_points(body, @page, "http://example.com/blog/a.png")
    assert_points(body, @page, "http://example.com/blog/b.png")
  end

  test "rewrites an unquoted srcset URL with an internal comma" do
    html = ~s|<img srcset=a.jpg,b.jpg><link rel="preload" as="image" imagesrcset=a.jpg,b.jpg>|
    body = rewrite(html, @page)
    candidate = Linker.offline_link(@page, "http://example.com/blog/a.jpg,b.jpg")

    refute body =~ "srcset=a.jpg,b.jpg"
    refute body =~ "imagesrcset=a.jpg,b.jpg"
    assert occurrences(body, candidate) == 2
    assert_points(body, @page, "http://example.com/blog/a.jpg,b.jpg")
  end

  test "rewrites complete comma-containing srcset candidates and retains descriptors" do
    candidates = "https://cdn.example/c_fill,w_400/photo.jpg 1x,next.jpg 2x, bare.jpg,"

    html = """
    <img srcset="#{candidates}">
    <link rel="preload" as="image" imagesrcset="#{candidates}">
    <img src="w_400/photo.jpg">
    """

    body = rewrite(html, @page)
    transformed = Linker.offline_link(@page, "https://cdn.example/c_fill,w_400/photo.jpg")
    next = Linker.offline_link(@page, "http://example.com/blog/next.jpg")
    bare = Linker.offline_link(@page, "http://example.com/blog/bare.jpg")
    expected = "#{transformed} 1x,#{next} 2x, #{bare},"

    assert body =~ ~s|srcset="#{expected}"|
    assert body =~ ~s|imagesrcset="#{expected}"|
    assert_points(body, @page, "https://cdn.example/c_fill,w_400/photo.jpg")
    assert_points(body, @page, "http://example.com/blog/w_400/photo.jpg")
  end

  test "rewrites data-first srcset candidates without changing the data payload" do
    candidates = "data:image/svg+xml,a.png 1x, a.png 2x"

    html = """
    <img srcset="#{candidates}">
    <link rel="preload" as="image" imagesrcset="#{candidates}">
    """

    body = rewrite(html, @page)
    image = Linker.offline_link(@page, "http://example.com/blog/a.png")
    expected = "data:image/svg+xml,a.png 1x, #{image} 2x"

    assert body =~ ~s|srcset="#{expected}"|
    assert body =~ ~s|imagesrcset="#{expected}"|
    assert occurrences(body, image) == 2
  end

  test "rewrites a refresh url when an earlier attribute contains a closing bracket" do
    html = ~s|<meta data-name="a>b" http-equiv="refresh" content="0; url=next.html">|
    body = rewrite(html, @page)

    assert body =~ ~s|data-name="a>b"|
    refute body =~ "url=next.html"
    assert_points(body, @page, "http://example.com/blog/next.html")

    quoted = ~s|<meta http-equiv="refresh" content="0; url='a>b.html'">|
    quoted_body = rewrite(quoted, @page)
    refute quoted_body =~ "url='a>b.html'"
    assert_points(quoted_body, @page, "http://example.com/blog/a>b.html")
  end

  test "drops a base tag when an attribute contains a closing bracket" do
    html =
      ~s|<head><base data-name="a>b" href="https://example.com/dir/"></head><a href="next.html"></a>|

    body = rewrite(html, @page)

    refute body =~ "<base"
    refute body =~ "https://example.com/dir"
    assert_points(body, @page, "https://example.com/dir/next.html")

    closed = ~s|<base href="https://example.com/dir/" />|
    refute rewrite(closed, @page) =~ "<base"
  end

  test "does not rewrite a parent prefix inside a longer unquoted link" do
    page = "http://example.com/blog/post/"

    html = """
    <a href="..">up</a>
    <img src=plain.png>
    <a href=other.html>next</a>
    <a href="../..">top</a>
    <img src=icon.png/>
    """

    body = rewrite(html, page)
    assert_points(body, page, "http://example.com/blog/")
    assert_points(body, page, "http://example.com/")
    assert_points(body, page, "http://example.com/blog/post/plain.png")
    assert_points(body, page, "http://example.com/blog/post/other.html")
    assert_points(body, page, "http://example.com/blog/post/icon.png")
    refute body =~ "__index.html/"
  end

  test "leaves an unquoted attribute in prose" do
    html = """
    <a href=other.html></a><p>Type href=other.html to continue</p>
    <img alt="a>b" src=plain.png>
    """

    body = rewrite(html, @page)
    assert body =~ "<p>Type href=other.html to continue</p>"
    refute body =~ "<a href=other.html>"
    assert body =~ ~s|alt="a>b"|
    assert_points(body, @page, "http://example.com/blog/other.html")
    assert_points(body, @page, "http://example.com/blog/plain.png")
  end

  for {opening, closing, normalized, attribute_quote, payload_quote} <- [
        {"&quot;", "&quot;", "&quot;", "\"", "'"},
        {"&apos;", "&apos;", "&apos;", "'", "\""},
        {"&#0034;", "&#34;", "&#34;", "\"", "'"},
        {"&#0039;", "&#39;", "&#39;", "'", "\""},
        {"&#X0022;", "&#x22;", "&#x22;", "\"", "'"},
        {"&#X0027;", "&#x27;", "&#x27;", "'", "\""}
      ] do
    test "preserves data payloads inside #{opening} quotes beside the same image candidate" do
      opening = unquote(opening)
      closing = unquote(closing)
      normalized = unquote(normalized)
      attribute_quote = unquote(attribute_quote)
      payload_quote = unquote(payload_quote)
      data = "data:text/css,body{background:url(#{payload_quote}a.png#{payload_quote})}"

      html =
        "<div style=#{attribute_quote}background:image-set(" <>
          "#{opening}#{data}#{closing} 1x,#{opening}a.png#{closing} 2x)#{attribute_quote}></div>"

      body = rewrite(html, @page)
      target = Linker.offline_link(@page, "http://example.com/blog/a.png")

      assert body ==
               "<div style=#{attribute_quote}background:image-set(" <>
                 "#{opening}#{data}#{closing} 1x,#{normalized}#{target}#{normalized} 2x)#{attribute_quote}></div>"

      assert_points(body, @page, "http://example.com/blog/a.png")
      assert occurrences(body, target) == 1
    end
  end

  test "rewrites a refresh url that has spaces inside its quotes" do
    html = ~s|<meta http-equiv="refresh" content="0; url=' next.html '">|

    body = rewrite(html, @page)
    refute body =~ "url=' next.html '"
    assert_points(body, @page, "http://example.com/blog/next.html")
  end

  test "rewrites hexadecimal double quotes without folding letter case" do
    html = """
    <meta http-equiv="refresh" content="0; url=&#x22;next.html&#x22;">
    <meta http-equiv="refresh" content="0; url=&#X0022;Later.html&#x0022;">
    <div style="background: image-set(&#x22;a.png&#x22; 1x)"></div>
    <div style="background: image-set(&#X22;A.PNG&#x22; 1x, &#x22;a.png&#x22; 2x)"></div>
    <div style="@import &#x22;theme.css&#x22;; background: url(&#x22;pic.png&#x22;)"></div>
    """

    body = rewrite(html, @page)

    refute body =~ "&#x22;next.html&#x22;"
    refute body =~ "&#X0022;Later.html&#x0022;"
    refute body =~ "&#x22;a.png&#x22;"
    refute body =~ "&#x22;A.PNG&#x22;"
    refute body =~ "&#x22;theme.css&#x22;"
    refute body =~ "&#x22;pic.png&#x22;"
    assert_points(body, @page, "http://example.com/blog/next.html")
    assert_points(body, @page, "http://example.com/blog/Later.html")
    assert_points(body, @page, "http://example.com/blog/a.png")
    assert_points(body, @page, "http://example.com/blog/A.PNG")
    assert_points(body, @page, "http://example.com/blog/theme.css")
    assert_points(body, @page, "http://example.com/blog/pic.png")
  end

  for {opening, closing, normalized} <- [
        {"\"", "\"", "\""},
        {"'", "'", "'"},
        {"&quot;", "&quot;", "&quot;"},
        {"&apos;", "&apos;", "&apos;"},
        {"&#0034;", "&#34;", "&#34;"},
        {"&#0039;", "&#39;", "&#39;"},
        {"&#X0022;", "&#x22;", "&#x22;"},
        {"&#X0027;", "&#x27;", "&#x27;"}
      ] do
    test "preserves offline paths across quote syntax #{opening}" do
      opening = unquote(opening)
      closing = unquote(closing)
      normalized = unquote(normalized)
      attribute_quote = if opening == "\"", do: "'", else: "\""

      html = """
      <div style=#{attribute_quote}@IMPORT #{opening}Theme.css#{closing}; background: URL( #{opening}Picture.png#{closing} ); background-image: image-set(#{opening}Picture.png#{closing} 1x)#{attribute_quote}></div>
      <meta http-equiv="refresh" content=#{attribute_quote}0; URL=#{opening}Next.html#{closing}#{attribute_quote}>
      """

      body = rewrite(html, @page)
      quoted = fn target -> normalized <> Linker.offline_link(@page, target) <> normalized end

      assert body =~ "@IMPORT #{quoted.("http://example.com/blog/Theme.css")};"
      assert body =~ "url(#{quoted.("http://example.com/blog/Picture.png")})"
      assert body =~ "image-set(#{quoted.("http://example.com/blog/Picture.png")} 1x)"
      assert body =~ "URL=#{quoted.("http://example.com/blog/Next.html")}"
    end
  end
end
