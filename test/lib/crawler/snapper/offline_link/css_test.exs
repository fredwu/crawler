defmodule Crawler.Snapper.OfflineLink.CssTest do
  use Crawler.OfflineLinkCase, async: true

  test "keeps the next image-set file when another candidate is a data url" do
    css = ~s|div { background: image-set(url("data:image/png;base64,abc") 1x, "b.png" 2x); }|
    body = rewrite(css, "http://example.com/css/app.css", "text/css", "link")

    assert body =~ ~s|url("data:image/png;base64,abc") 1x|
    refute body =~ ~s|"b.png"|
    assert_points(body, "http://example.com/css/app.css", "http://example.com/css/b.png")
  end

  test "rewrites every repeated unquoted image-set and leaves nearby text" do
    css = """
    /* wide.png 1x */
    .a { background: image-set(wide.png 1x); }
    .b { background: image-set(wide.png 1x, narrow.png 2x); }
    .c { background: image-set(wide.png 1x, narrow.png 2x); }
    .d { background: image-set(wide.png); }
    .e { background: image-set(wide.png); }
    """

    page = "http://example.com/css/app.css"
    body = rewrite(css, page, "text/css", "link")
    wide = Linker.offline_link(page, "http://example.com/css/wide.png")
    narrow = Linker.offline_link(page, "http://example.com/css/narrow.png")

    assert body =~ "/* wide.png 1x */"
    refute body =~ "image-set(wide.png 1x)"
    refute body =~ "image-set(wide.png 1x, narrow.png 2x)"
    refute body =~ "image-set(wide.png)"
    refute body =~ "css/../../"
    assert occurrences(body, wide) == 5
    assert occurrences(body, narrow) == 2
    assert_points(body, page, "http://example.com/css/wide.png")
    assert_points(body, page, "http://example.com/css/narrow.png")
  end

  test "rewrites a nested image-set and a stylesheet that is not utf-8" do
    css = "http://example.com/css/app.css"

    nested =
      rewrite(~s|div { background: image-set(image-set(a.png) 1x); }|, css, "text/css", "link")

    refute nested =~ "image-set(a.png)"
    assert_points(nested, css, "http://example.com/css/a.png")

    latin = "div{background:url(\"shown.png\")} image-set(\"caf" <> <<0xE9>> <> ".png\")"
    body = rewrite(latin, css, "text/css", "link")
    assert_points(body, css, "http://example.com/css/shown.png")
  end

  test "does not rewrite a file name inside a data url" do
    css =
      ~s|div { background: image-set("data:text/css,body{background:url('a.png')}" 1x, "b.png" 2x); }|

    body = rewrite(css, "http://example.com/css/app.css", "text/css", "link")
    assert body =~ "url('a.png')"
    refute body =~ ~s|"b.png"|
    assert_points(body, "http://example.com/css/app.css", "http://example.com/css/b.png")
  end

  test "rewrites a stylesheet that climbs out of the host" do
    css = "http://example.com/css/app.css"

    body =
      rewrite(
        ~s|body { background: url(../../images/a.png); }|,
        css,
        "Text/CSS",
        "link"
      )

    refute body =~ "url(../../images/a.png)"
    assert_points(body, css, "http://example.com/images/a.png")
  end
end
