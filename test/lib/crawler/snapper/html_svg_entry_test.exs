defmodule Crawler.Snapper.HTMLSVGEntryTest do
  use Crawler.OfflineLinkCase, async: true

  import Crawler.SnapshotHelpers, only: [saved: 2]
  import Crawler.TestHelpers, only: [tmp: 1]

  alias Crawler.Parser
  alias Crawler.Snapper

  for {opening, closing} <- [
        {"<math>", "</math>"},
        {"<math><mrow>", "</mrow></math>"},
        {"<math><annotation-xml><mrow>", "</mrow></annotation-xml></math>"},
        {~s|<math><annotation-xml encoding="application/xml"><mrow>|,
         "</mrow></annotation-xml></math>"}
      ] do
    test "#{opening} keeps MathML image-shaped references unchanged in the saved source" do
      source =
        unquote(opening) <> ~s|<svg><image href="ignored.png"/></svg>| <> unquote(closing)

      root = tmp("snapshot-svg-entry-math-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(root) end)
      assert discovered(source) == []
      assert rewrite(source, @page) == source
      save(source, root)
      assert File.read!(saved(root, @page)) == <<0xEF, 0xBB, 0xBF>> <> source
    end
  end

  for {opening, closing} <- [
        {"", ""},
        {"<math><annotation-xml>", "</annotation-xml></math>"},
        {~s|<math><annotation-xml encoding="application/xml">|, "</annotation-xml></math>"},
        {"<math><mtext>", "</mtext></math>"},
        {"<svg><foreignObject>", "</foreignObject></svg>"},
        {"<svg><desc>", "</desc></svg>"},
        {"<svg><title>", "</title></svg>"}
      ] do
    test "#{opening} discovers and saves its real SVG image reference" do
      source =
        unquote(opening) <> ~s|<svg><image href="image.png"/></svg>| <> unquote(closing)

      root = tmp("snapshot-svg-entry-image-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(root) end)
      target = "http://example.com/blog/image.png"
      href = Linker.offline_link(@page, target)
      expected = String.replace(source, ~s|href="image.png"|, ~s|href="#{href}"|)

      assert discovered(source) == [target]
      assert rewrite(source, @page) == expected
      save(source, root)
      assert File.read!(saved(root, @page)) == <<0xEF, 0xBB, 0xBF>> <> expected
    end
  end

  test "a valid SVG entry inside template content remains inert beside a live image" do
    inert =
      ~s|<template><math><annotation-xml><svg><image href="image.png"/></svg></annotation-xml></math></template>|

    active = ~s|<svg><image href="image.png"/></svg>|
    target = "http://example.com/blog/image.png"
    href = Linker.offline_link(@page, target)

    assert discovered(inert <> active) == [target]
    assert rewrite(inert <> active, @page) == inert <> ~s|<svg><image href="#{href}"/></svg>|
  end

  test "an ignored MathML image cannot hide a real HTML reference after the container closes" do
    inert = ~s|<math><svg><image href="next"/></svg></math>|
    source = inert <> ~s|<a href="next">Out</a>|
    target = "http://example.com/blog/next"
    href = Linker.offline_link(@page, target)
    assert discovered(source) == [target]
    assert rewrite(source, @page) == inert <> ~s|<a href="#{href}">Out</a>|
  end

  defp save(source, root) do
    assert {:ok, _opts} =
             Snapper.snap(source, %{
               url: @page,
               save_to: root,
               content_type: "text/html",
               html_tag: "a",
               assets: ["images"],
               depth: 1,
               max_depths: 3
             })
  end

  defp discovered(source) do
    source
    |> Parser.parse_links(
      %{
        url: @page,
        referrer_url: @page,
        content_type: "text/html",
        html_tag: "a",
        assets: ["images"],
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
