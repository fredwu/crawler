defmodule Crawler.Snapper.ForeignTextTest do
  use Crawler.OfflineLinkCase, async: true

  alias Crawler.HTMLSpans

  for foreign <- ["svg", "math"] do
    test "a self-closing script in #{foreign} leaves later links visible" do
      foreign = unquote(foreign)
      source = ~s|<#{foreign}><script/></#{foreign}><a href="next">go</a>|
      target = Linker.offline_link(@page, "http://example.com/blog/next")

      assert rewrite(source, @page) ==
               ~s|<#{foreign}><script/></#{foreign}><a href="#{target}">go</a>|

      tags = HTMLSpans.tags(source)
      assert Enum.find(tags, &(&1.name == "script")).content_span == nil
      assert Enum.find(tags, &(&1.name == "a")).namespace == :html
    end
  end

  test "foreign CDATA keeps anchor-shaped text literal beside a real anchor" do
    literal = ~s|<![CDATA[x><a href="next">]]>|
    source = ~s|<svg>#{literal}</svg><a href="next">real</a>|
    target = Linker.offline_link(@page, "http://example.com/blog/next")
    body = rewrite(source, @page)

    assert body == ~s|<svg>#{literal}</svg><a href="#{target}">real</a>|
    document = Floki.parse_document!(body)
    assert Floki.attribute(document, "a", "href") == [target]
    assert Floki.text(Floki.find(document, "svg")) == ~s|x><a href="next">|
  end

  test "HTML script slash-close syntax still starts a raw-text region" do
    source = ~s|<script/><a href="next">literal</a>|
    [script] = HTMLSpans.tags(source)
    assert script.namespace == :html
    assert script.content_span != nil
    assert rewrite(source, @page) == source
  end

  for container <- [
        ~s|<svg><foreignObject>|,
        ~s|<svg><desc>|,
        ~s|<svg><title>|,
        ~s|<math><mtext>|,
        ~s|<math><annotation-xml encoding="text/html">|,
        ~s|<math><annotation-xml encoding="text&#47;html">|,
        ~s|<math><annotation-xml encoding="application/xhtml+xml">|
      ] do
    test "#{container} restores HTML raw-text rules at its integration point" do
      source = unquote(container) <> ~s|<script/><a href="next">literal</a>|
      script = source |> HTMLSpans.tags() |> Enum.find(&(&1.name == "script"))
      assert script.namespace == :html
      assert script.content_span != nil
      refute Enum.any?(HTMLSpans.tags(source), &(&1.name == "a"))
    end
  end

  for attribute <- ["color", "FACE", "size"] do
    test "a foreign font #{attribute} attribute restores HTML script raw-text rules" do
      source = ~s|<svg><font #{unquote(attribute)}="red"><script/><a href="next">literal</a>|
      assert rewrite(source, @page) == source

      for opts <- [[], [attributes: false]] do
        script = source |> HTMLSpans.tags(opts) |> Enum.find(&(&1.name == "script"))
        assert script.namespace == :html
        assert script.content_span != nil
        refute Enum.any?(HTMLSpans.tags(source, opts), &(&1.name == "a"))
      end
    end
  end

  test "attribute-shaped font data does not trigger a foreign breakout" do
    source =
      ~s|<svg><font data-color="red" title="face='serif' size=2"><script/><a href="next">real</a></font></svg>|

    target = Linker.offline_link(@page, "http://example.com/blog/next")
    assert rewrite(source, @page) == String.replace(source, ~s|href="next"|, ~s|href="#{target}"|)

    script = source |> HTMLSpans.tags(attributes: false) |> Enum.find(&(&1.name == "script"))
    assert script.namespace == :svg
    assert script.content_span == nil
  end

  test "font children at an SVG integration point already use HTML rules" do
    source = ~s|<svg><foreignObject><font><script/><a href="next">literal</a>|
    script = source |> HTMLSpans.tags(attributes: false) |> Enum.find(&(&1.name == "script"))
    assert script.namespace == :html
    assert script.content_span != nil
    assert rewrite(source, @page) == source
  end

  test "nested foreign content after an integration point keeps its own self-closing rules" do
    source =
      ~s|<svg><foreignObject><svg><script/></svg><a href="next">go</a></foreignObject></svg>|

    target = Linker.offline_link(@page, "http://example.com/blog/next")
    assert rewrite(source, @page) == String.replace(source, ~s|href="next"|, ~s|href="#{target}"|)
  end
end
