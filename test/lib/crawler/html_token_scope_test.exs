defmodule Crawler.HTMLTokenScopeTest do
  use ExUnit.Case, async: true

  alias Crawler.HTMLSpans
  alias Crawler.HTMLSpans.Context
  alias Crawler.HTMLSpans.Markup

  for source <- [
        "<a",
        "<a href=next",
        ~s|<a href="next"|,
        ~s|<a href="next|,
        "<img src=next.png",
        ~s|<img src='next.png|,
        "<base href=/wrong/",
        ~s|<meta charset="latin1"|,
        "</template",
        ~s|<script src="app.js"|
      ] do
    test "#{source} has no complete tag token at EOF" do
      source = unquote(source)
      assert Markup.next(source, 0, false) == nil
      assert HTMLSpans.tags(source) == []
      assert HTMLSpans.base_tags(source) == []
      assert HTMLSpans.parser_source(source) == source
    end
  end

  test "a complete preceding tag retains its byte span before an unfinished token" do
    prefix = ~s|é<a href="real">go</a>|
    source = prefix <> ~s|<a href="next><img src='literal'>|
    assert [anchor, closing] = HTMLSpans.tags(source)
    assert anchor.span == {2, byte_size(~s|<a href="real">|)}
    assert HTMLSpans.value(anchor, "href") == "real"
    assert closing.closing?
  end

  test "an ancestor closing tag cannot remove the current template scope" do
    source =
      ~s|<div><template></div><a href="inside">In</a></template><a href="outside">Out</a>|

    assert [inside, outside] = anchors(source)
    assert inside.in_template?
    refute outside.in_template?
  end

  test "closing a nested template leaves its outer template active" do
    source =
      ~s|<div><template><section><template></div></section><a href="inner">In</a>| <>
        ~s|</template><a href="outer">Outer</a></template><a href="outside">Out</a>|

    assert [inner, outer, outside] = anchors(source)
    assert inner.in_template?
    assert outer.in_template?
    refute outside.in_template?
  end

  test "a closing template token still closes the nearest template through table descendants" do
    source =
      ~s|<template><table><tr><td><a href="inside">In</a></template><a href="outside">Out</a>|

    assert [inside, outside] = anchors(source)
    assert inside.in_template?
    refute outside.in_template?
  end

  for {opening, closing} <- [
        {"<svg><foreignObject>", "</foreignObject></svg>"},
        {~s|<math><annotation-xml encoding="text/html">|, "</annotation-xml></math>"}
      ] do
    test "an outer foreign closing tag cannot cross a template inside #{opening}" do
      opening = unquote(opening)
      closing = unquote(closing)

      source =
        opening <>
          "<template>" <>
          closing <>
          ~s|<a href="inside">In</a>| <>
          "</template>" <> closing <> ~s|<a href="outside">Out</a>|

      assert [inside, outside] = anchors(source)
      assert inside.in_template?
      assert inside.namespace == :html
      refute outside.in_template?
      assert outside.namespace == :html
    end
  end

  test "a foreign template element closes before its enclosing HTML template" do
    source =
      ~s|<template><svg><template></template></svg><a href="inside">In</a>| <>
        ~s|</template><a href="outside">Out</a>|

    assert [inside, outside] = anchors(source)
    assert inside.in_template?
    refute outside.in_template?
  end

  for {namespace, barrier} <- [
        {:html, "object"},
        {:html, "table"},
        {:html, "select"},
        {:svg, "foreignobject"},
        {:math, "mtext"},
        {:math, "annotation-xml"}
      ] do
    test "an HTML ancestor is not in scope through #{namespace} #{barrier}" do
      stack = [node(unquote(barrier), unquote(namespace)), node("div", :html)]
      assert Context.advance(%{closing?: true, name: "div"}, :html, stack) == stack
    end
  end

  test "a foreign ancestor can close through other foreign elements" do
    stack = [node("title", :svg), node("svg", :svg), node("div", :html)]
    assert Context.namespace(%{closing?: true, name: "svg"}, stack) == :svg

    assert Context.advance(%{closing?: true, name: "svg"}, :svg, stack) ==
             [node("div", :html)]
  end

  test "table scope can close a table through a cell while retaining an outer template" do
    stack = [node("td", :html), node("table", :html), node("template", :html)]

    assert Context.advance(%{closing?: true, name: "table"}, :html, stack) ==
             [node("template", :html)]
  end

  defp anchors(source) do
    source
    |> HTMLSpans.tags()
    |> Enum.filter(&(&1.name == "a" and not &1.closing?))
  end

  defp node(name, namespace), do: %{name: name, namespace: namespace, html_children?: false}
end
