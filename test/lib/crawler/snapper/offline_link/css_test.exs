defmodule Crawler.Snapper.OfflineLink.CssTest do
  use Crawler.OfflineLinkCase, async: true

  alias Crawler.Charset
  alias Crawler.Parser
  alias Crawler.Snapper.LinkReplacer

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
    wide = "http://example.com/css/wide.png"
    narrow = "http://example.com/css/narrow.png"

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

  test "rewrites a nested image-set" do
    css = "http://example.com/css/app.css"

    nested =
      rewrite(~s|div { background: image-set(image-set(a.png) 1x); }|, css, "text/css", "link")

    refute nested =~ "image-set(a.png)"
    assert_points(nested, css, "http://example.com/css/a.png")
  end

  test "rewrites a Latin-1 stylesheet after response decoding" do
    css = "http://example.com/css/app.css"
    latin = "div{background:url(\"shown.png\")} image-set(\"caf" <> <<0xE9>> <> ".png\")"
    opts = %{content_type: "text/css", headers: [{"content-type", "text/css; charset=latin1"}]}
    decoded = Charset.decode(latin, opts)

    assert decoded == ~s|div{background:url("shown.png")} image-set("café.png")|
    body = rewrite(decoded, css, "text/css", "link")
    assert_points(body, css, "http://example.com/css/shown.png")
  end

  test "undecoded invalid UTF-8 CSS returns a tagged error before discovery or rewriting" do
    latin = "div{background:url(\"shown.png\")} image-set(\"caf" <> <<0xE9>> <> ".png\")"

    opts = %{
      url: "http://example.com/css/app.css",
      content_type: "text/css",
      html_tag: "link",
      assets: ["css", "images"]
    }

    assert Parser.parse_links(latin, opts, fn _, _ ->
             flunk("invalid source reached discovery")
           end) ==
             {:error, :invalid_utf8}

    assert LinkReplacer.replace_links(latin, opts) == {:error, :invalid_utf8}
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
