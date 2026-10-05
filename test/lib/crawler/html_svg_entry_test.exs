defmodule Crawler.HTMLSVGEntryTest do
  use ExUnit.Case, async: true

  alias Crawler.HTMLSpans

  for {opening, closing} <- [
        {"<math>", "</math>"},
        {"<math><mrow>", "</mrow></math>"},
        {"<math><annotation-xml><mrow>", "</mrow></annotation-xml></math>"},
        {~s|<math><annotation-xml encoding="application/xml"><mrow>|,
         "</mrow></annotation-xml></math>"}
      ] do
    test "#{opening} does not make its nested svg token enter the SVG namespace" do
      source =
        unquote(opening) <>
          ~s|<svg><image href="ignored.png"/><script/></svg>| <>
          unquote(closing) <> ~s|<a href="next">Out</a>|

      for opts <- [[], [attributes: false]] do
        tags = HTMLSpans.tags(source, opts)
        assert [%{namespace: :math}] = Enum.filter(tags, &(&1.name == "svg" and not &1.closing?))
        assert [%{namespace: :math}] = Enum.filter(tags, &(&1.name == "image"))

        assert [%{namespace: :math, content_span: nil}] =
                 Enum.filter(tags, &(&1.name == "script"))

        assert [%{namespace: :html}] = Enum.filter(tags, &(&1.name == "a" and not &1.closing?))
      end
    end
  end

  for {opening, closing} <- [
        {"", ""},
        {"<math><annotation-xml>", "</annotation-xml></math>"},
        {~s|<math><annotation-xml encoding="application/xml">|, "</annotation-xml></math>"},
        {~s|<math><annotation-xml encoding="text/html">|, "</annotation-xml></math>"},
        {~s|<math><annotation-xml encoding="application/xhtml+xml">|, "</annotation-xml></math>"},
        {"<math><mi>", "</mi></math>"},
        {"<math><mo>", "</mo></math>"},
        {"<math><mn>", "</mn></math>"},
        {"<math><ms>", "</ms></math>"},
        {"<math><mtext>", "</mtext></math>"},
        {"<svg><foreignObject>", "</foreignObject></svg>"},
        {"<svg><desc>", "</desc></svg>"},
        {"<svg><title>", "</title></svg>"}
      ] do
    test "#{opening} allows the following svg element to use SVG namespace" do
      source =
        unquote(opening) <>
          ~s|<svg><image href="image.png"/><script/></svg>| <>
          unquote(closing)

      for opts <- [[], [attributes: false]] do
        tags = HTMLSpans.tags(source, opts)
        svg = tags |> Enum.filter(&(&1.name == "svg" and not &1.closing?)) |> List.last()
        assert svg.namespace == :svg
        assert [%{namespace: :svg}] = Enum.filter(tags, &(&1.name == "image"))
        assert [%{namespace: :svg, content_span: nil}] = Enum.filter(tags, &(&1.name == "script"))
      end
    end
  end

  test "annotation-xml nested in MathML svg-shaped content still has its immediate svg exception" do
    source =
      ~s|<math><svg><annotation-xml><svg><image href="image.png"/></svg></annotation-xml></svg></math>|

    tags = HTMLSpans.tags(source)
    assert [outer, inner] = Enum.filter(tags, &(&1.name == "svg" and not &1.closing?))
    assert outer.namespace == :math
    assert inner.namespace == :svg
    assert [%{namespace: :svg}] = Enum.filter(tags, &(&1.name == "image"))
  end

  for closing <- ["p", "br"] do
    test "foreign </#{closing}> recovery still enables an SVG entry from HTML context" do
      source = ~s|<math><svg></#{unquote(closing)}><svg><image href="image.png"/></svg>|
      tags = HTMLSpans.tags(source)
      assert [math_svg, real_svg] = Enum.filter(tags, &(&1.name == "svg" and not &1.closing?))
      assert math_svg.namespace == :math
      assert real_svg.namespace == :svg
      assert [%{namespace: :svg}] = Enum.filter(tags, &(&1.name == "image"))
    end
  end
end
