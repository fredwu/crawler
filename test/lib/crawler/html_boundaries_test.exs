defmodule Crawler.HTMLBoundariesTest do
  use ExUnit.Case, async: true

  alias Crawler.HTMLSpans
  alias Crawler.HTMLSpans.Markup

  for comment <- [
        "<!-->",
        "<!--->",
        "<!-- hidden --!>",
        "<!-- hidden --->",
        "<!-- outer <!-- nested -->",
        "<!-- outer <!-->",
        "<!-- outer <!--->",
        "<!-- --!x -->",
        "<!-- --!-> hidden -->",
        "<!-- --!-->"
      ] do
    test "#{comment} ends before the next real tag" do
      comment = unquote(comment)
      anchor = ~s|<a href="next">real</a>|
      source = "é" <> comment <> anchor

      assert Markup.next(source, 0, false) == {2, byte_size(comment), :comment}
      assert [opening, closing] = HTMLSpans.tags(source)
      assert opening.name == "a"
      assert opening.span == {2 + byte_size(comment), byte_size(~s|<a href="next">|)}
      assert closing.name == "a"
      assert closing.closing?
    end
  end

  for comment <- ["<!--", "<!---", "<!-- hidden --", "<!-- hidden --!", "<!-- outer <!--"] do
    test "#{comment} consumes comment content through EOF" do
      source = unquote(comment) <> ~s|<a href="next">literal</a>|
      assert Markup.next(source, 0, false) == {0, byte_size(source), :comment}
      assert HTMLSpans.tags(source) == []
    end
  end

  for content <- [
        ~s|<!--<script></script><meta charset="latin1">-->|,
        ~s|<!--<ScRiPt ></sCrIpT ><meta charset="latin1">-->|,
        ~s|<!--<script/><meta charset="latin1"></script/><a href="literal">|,
        ~s|<!--<script\t></script\r><a href="literal">|,
        ~s|<!--<script></scripty><a href="literal"></script>-->|,
        ~s|<!--<script></script!><a href="literal"></script>-->|,
        ~s|<!--<script></script><script></script><a href="literal">-->|,
        ~s|<!--<script>-->|,
        ~s|<!--<script><a href="literal">--->|
      ] do
    test "script states keep #{content} inside one byte span" do
      content = unquote(content)
      source = "é<script>" <> content <> ~s|</script><a href="next">real</a>|

      assert [script, anchor, closing] = HTMLSpans.tags(source)
      assert script.content_span == {10, byte_size(content)}
      assert HTMLSpans.slice(source, script.content_span) == content
      assert anchor.name == "a"
      assert HTMLSpans.value(anchor, "href") == "next"
      assert closing.closing?
    end
  end

  for content <- [
        "<script>",
        "<!-<script>",
        "<!--<scripty>",
        "<!--<script!>",
        "<!--<script=>",
        "<!--<scripté>",
        "<!--<script\v>",
        "<!--<script>-->"
      ] do
    test "#{content} does not double-escape the next closing tag" do
      content = unquote(content)
      source = "<script>" <> content <> ~s|</script><a href="next">real</a>|
      assert [script, anchor, _closing] = HTMLSpans.tags(source)
      assert HTMLSpans.slice(source, script.content_span) == content
      assert HTMLSpans.value(anchor, "href") == "next"
    end
  end

  test "a double-escaped script without a real closing tag consumes through EOF" do
    content = ~s|<!--<script></script><meta charset="latin1"><a href="literal">|
    source = "<script>" <> content
    assert [script] = HTMLSpans.tags(source)
    assert HTMLSpans.slice(source, script.content_span) == content
    assert HTMLSpans.base_tags(source) == []
  end

  test "a closing script tag respects attributes and EOF" do
    source = ~s|<script>js</SCRIPT title=">"><a href="next">real</a>|
    assert [script, anchor, _closing] = HTMLSpans.tags(source)
    assert HTMLSpans.slice(source, script.content_span) == "js"
    assert HTMLSpans.value(anchor, "href") == "next"

    source = ~s|<script>js</script title="unterminated><a href='literal'>|
    assert [script] = HTMLSpans.tags(source)

    assert HTMLSpans.slice(source, script.content_span) ==
             ~s|js</script title="unterminated><a href='literal'>|
  end

  test "a later quote can complete the closing script tag before a real following anchor" do
    source =
      ~s|<script>js</script title="unterminated><a href="literal"><a href="next">real</a>|

    assert [script, anchor, closing] = HTMLSpans.tags(source)
    assert HTMLSpans.slice(source, script.content_span) == "js"
    assert HTMLSpans.value(anchor, "href") == "next"
    assert closing.closing?
  end

  test "other raw-text elements retain their closing rules" do
    source = ~s|<style><!--<script></style><a href="next">real</a>|
    assert [style, anchor, _closing] = HTMLSpans.tags(source)
    assert HTMLSpans.slice(source, style.content_span) == "<!--<script>"
    assert HTMLSpans.value(anchor, "href") == "next"
  end

  test "foreign script tags and HTML integration points keep their own boundaries" do
    source = ~s|<svg><script/><a href="next">real</a></svg>|
    script = source |> HTMLSpans.tags() |> Enum.find(&(&1.name == "script"))
    assert script.namespace == :svg
    assert script.content_span == nil

    content = ~s|<!--<script></script><a href="literal">-->|
    source = ~s|<svg><foreignObject><script>#{content}</script><a href="next">real</a>|
    tags = HTMLSpans.tags(source)
    script = Enum.find(tags, &(&1.name == "script"))
    assert script.namespace == :html
    assert HTMLSpans.slice(source, script.content_span) == content
    assert [anchor] = Enum.filter(tags, &(&1.name == "a" and not &1.closing?))
    assert HTMLSpans.value(anchor, "href") == "next"
  end
end
