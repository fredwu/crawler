defmodule Crawler.HTMLForeignEndTest do
  use ExUnit.Case, async: true

  alias Crawler.HTMLSpans
  alias Crawler.HTMLSpans.Context

  for foreign <- ["svg", "math"], closing <- ["p", "br"] do
    test "#{foreign} </#{closing}> makes the following slash-closed script HTML raw text" do
      prefix = "<#{unquote(foreign)}></#{String.upcase(unquote(closing))}><script/>"
      literal = ~s|<meta charset="latin1"><base href="/wrong/"><a href="next">literal</a>|
      source = prefix <> literal

      for opts <- [[], [attributes: false]] do
        assert [container, close, script] = HTMLSpans.tags(source, opts)
        assert container.namespace in [:svg, :math]
        assert close.namespace == :html
        assert script.namespace == :html
        assert script.content_span == {byte_size(prefix), byte_size(literal)}
        assert HTMLSpans.slice(source, script.content_span) == literal
      end

      assert HTMLSpans.base_tags(source) == []
    end

    test "real tags after the HTML script close remain visible for #{foreign} </#{closing}>" do
      literal = ~s|<meta charset="latin1"><a href="literal">In</a>|

      source =
        "<#{unquote(foreign)}></#{unquote(closing)}><script/>" <>
          literal <>
          ~s|</script><a href="next">Out</a>|

      scripts = source |> HTMLSpans.tags() |> Enum.filter(&(&1.name == "script"))
      assert [script] = scripts
      assert HTMLSpans.slice(source, script.content_span) == literal
      assert [anchor] = anchors(source)
      assert HTMLSpans.value(anchor, "href") == "next"
      assert anchor.namespace == :html
    end

    test "#{foreign} </#{closing}> cannot remove an enclosing HTML template" do
      source =
        "<template><#{unquote(foreign)}></#{unquote(closing)}><script/>" <>
          ~s|<a href="literal">Literal</a></script><a href="inside">In</a>| <>
          ~s|</template><a href="outside">Out</a>|

      script = source |> HTMLSpans.tags() |> Enum.find(&(&1.name == "script"))
      assert script.namespace == :html
      assert script.in_template?
      assert [inside, outside] = anchors(source)
      assert inside.in_template?
      refute outside.in_template?
    end
  end

  for {opening, close, namespace} <- [
        {"<svg><foreignObject>", "</foreignObject>", :svg},
        {"<svg><desc>", "</desc>", :svg},
        {"<math><mtext>", "</mtext>", :math},
        {~s|<math><annotation-xml encoding="text/html">|, "</annotation-xml>", :math}
      ],
      closing <- ["p", "br"] do
    test "</#{closing}> stops at the integration point in #{opening}" do
      literal = ~s|<a href="literal">In</a>|

      source =
        unquote(opening) <>
          "<svg></#{unquote(closing)}><script/>" <>
          literal <>
          "</script>" <> unquote(close) <> "<script/>"

      assert [html_script, foreign_script] =
               source |> HTMLSpans.tags() |> Enum.filter(&(&1.name == "script"))

      assert html_script.namespace == :html
      assert HTMLSpans.slice(source, html_script.content_span) == literal
      assert foreign_script.namespace == unquote(namespace)
      assert foreign_script.content_span == nil
      assert anchors(source) == []
    end
  end

  test "foreign paragraph recovery closes an existing HTML paragraph after leaving foreign nodes" do
    parent = node("div", :html)
    stack = [node("g", :svg), node("svg", :svg), node("p", :html), parent]
    assert Context.advance(%{closing?: true, name: "p"}, :html, stack) == [parent]
  end

  test "foreign break recovery stops at HTML boundaries and keeps template scope" do
    template = node("template", :html)
    stack = [node("svg", :svg), template]
    assert Context.advance(%{closing?: true, name: "br"}, :html, stack) == [template]
    assert Context.advance(%{closing?: true, name: "p"}, :html, stack) == [template]
  end

  test "other foreign end tags retain their namespace and closing rules" do
    source = ~s|<svg></span><script/></svg><a href="next">Out</a>|
    script = source |> HTMLSpans.tags() |> Enum.find(&(&1.name == "script"))
    assert script.namespace == :svg
    assert script.content_span == nil
    assert [anchor] = anchors(source)
    assert HTMLSpans.value(anchor, "href") == "next"
  end

  defp anchors(source) do
    source
    |> HTMLSpans.tags()
    |> Enum.filter(&(&1.name == "a" and not &1.closing?))
  end

  defp node(name, namespace), do: %{name: name, namespace: namespace, html_children?: false}
end
