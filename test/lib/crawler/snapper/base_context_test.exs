defmodule Crawler.Snapper.BaseContextTest do
  use Crawler.OfflineLinkCase, async: true

  alias Crawler.Parser

  for container <- ["svg", "math", "template"] do
    test "a base inside #{container} neither sets the live base nor loses its source" do
      container = unquote(container)
      inactive = ~s|<#{container}><base href="https://wrong.test/docs/"></#{container}>|
      source = inactive <> ~s|<a href="next">go</a>|
      target = "http://example.com/blog/next"
      assert discovered(source) == [target]
      href = Linker.offline_link(@page, target)
      assert rewrite(source, @page) == inactive <> ~s|<a href="#{href}">go</a>|
    end
  end

  test "an inactive base matching a live link retains its href literally" do
    inactive = ~s|<template><base href="next"></template>|
    source = inactive <> ~s|<a href="next">go</a>|
    href = Linker.offline_link(@page, "http://example.com/blog/next")
    assert rewrite(source, @page) == inactive <> ~s|<a href="#{href}">go</a>|
  end

  test "the first active base with href wins after an inactive base and a target-only base" do
    inactive = ~s|<template><base href="https://wrong.test/"></template><base target="_blank">|
    source = inactive <> ~s|<base href="/docs/"><base href="/other/"><a href="next">go</a>|
    target = "http://example.com/docs/next"
    assert discovered(source) == [target]
    href = Linker.offline_link(@page, target)
    assert rewrite(source, @page) == inactive <> ~s|<a href="#{href}">go</a>|
  end

  for {opening, closing} <- [
        {"<svg><foreignObject>", "</foreignObject></svg>"},
        {~s|<math><annotation-xml encoding="text/html">|, "</annotation-xml></math>"}
      ] do
    test "an active HTML base at #{opening} uses the same eligibility for selection and removal" do
      opening = unquote(opening)
      closing = unquote(closing)
      source = opening <> ~s|<base href="/docs/">| <> closing <> ~s|<a href="next">go</a>|
      target = "http://example.com/docs/next"
      assert discovered(source) == [target]
      href = Linker.offline_link(@page, target)
      assert rewrite(source, @page) == opening <> closing <> ~s|<a href="#{href}">go</a>|
    end
  end

  test "an HTML integration point cannot activate a base inside template content" do
    inactive =
      ~s|<template><svg><foreignObject><base href="/wrong/"></foreignObject></svg></template>|

    source = inactive <> ~s|<a href="next">go</a>|
    target = "http://example.com/blog/next"
    assert discovered(source) == [target]
    href = Linker.offline_link(@page, target)
    assert rewrite(source, @page) == inactive <> ~s|<a href="#{href}">go</a>|
  end

  defp discovered(source) do
    source
    |> Parser.parse_links(
      %{
        url: @page,
        referrer_url: @page,
        content_type: "text/html",
        html_tag: "a",
        assets: [],
        depth: 1,
        max_depths: 3
      },
      fn
        {_attribute, url}, _opts -> url
        {"link", _raw, _attribute, url}, _opts -> url
      end
    )
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end
end
