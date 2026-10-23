defmodule Crawler.Snapper.HtmlUnquotedRecoveryTest do
  use Crawler.OfflineLinkCase, async: true

  test "a quote inside an unquoted attribute cannot swallow a later real anchor" do
    source = ~s|<div x=a"b></div><a href="next">go</a>|
    target = "http://example.com/blog/next"
    assert Floki.attribute(Floki.parse_document!(source), "a", "href") == ["next"]

    assert rewrite(source, @page) == ~s|<div x=a"b></div><a href="#{target}">go</a>|
  end

  for {value, encoded} <- [
        {"a<b.png", "a%3cb.png"},
        {"a`b.png", "a%60b.png"},
        {~s|a"b.png|, "a%22b.png"},
        {"a'b.png", "a&#39;b.png"}
      ] do
    test "rewrites the complete recovered unquoted URL #{value} without changing later markup" do
      value = unquote(value)
      source = ~s|<img src=#{value}><a href="next">go</a>|
      before = Floki.parse_document!(source)
      assert Floki.attribute(before, "img", "src") == [value]
      assert Floki.attribute(before, "a", "href") == ["next"]
      image = "http://example.com/blog/" <> unquote(encoded)
      page = "http://example.com/blog/next"
      body = rewrite(source, @page)

      assert body == ~s|<img src=#{image}><a href="#{page}">go</a>|
      document = Floki.parse_document!(body)
      assert Floki.attribute(document, "img", "src") == [String.replace(image, "&#39;", "'")]
      assert Floki.attribute(document, "a", "href") == [page]
    end
  end

  test "recoverable unquoted data beside a quoted template keeps the template opaque" do
    source = ~s|<div x=a`b title="<a href='next'>"></div><a href="next">go</a>|
    page = "http://example.com/blog/next"

    assert rewrite(source, @page) ==
             ~s|<div x=a`b title="<a href='next'>"></div><a href="#{page}">go</a>|
  end
end
