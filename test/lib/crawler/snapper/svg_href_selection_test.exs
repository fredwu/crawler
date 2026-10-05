defmodule Crawler.Snapper.SVGHrefSelectionTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker
  alias Crawler.Snapper.LinkReplacer

  @page "http://example.com/index.html"
  @opts %{url: @page, content_type: "text/html", html_tag: "a", assets: ["images", "css"]}

  for tag <- ["a", "image", "use"] do
    test "SVG #{tag} preserves ignored fallback and duplicate attribute bytes" do
      tag = unquote(tag)

      source =
        "<svg>" <>
          ~s|<#{tag} xlink:href='shared.svg' href="chosen.svg"/>| <>
          ~s|<#{tag} xlink:href="shared.svg" xlink:href='chosen.svg'/>| <>
          ~s|<#{tag} href="" href='chosen.svg' xlink:href='shared.svg' style="background:url(shared.svg)"/>| <>
          "</svg>"

      chosen = offline("chosen.svg")
      shared = offline("shared.svg")

      assert rewrite(source, @opts) ==
               "<svg>" <>
                 ~s|<#{tag} xlink:href='shared.svg' href="#{chosen}"/>| <>
                 ~s|<#{tag} xlink:href="#{shared}" xlink:href='chosen.svg'/>| <>
                 ~s|<#{tag} href="" href='chosen.svg' xlink:href='shared.svg' style="background:url(#{shared})"/>| <>
                 "</svg>"
    end
  end

  test "disabled SVG image links retain their bytes while CSS still rewrites" do
    source =
      ~s|<svg><image href="shared.svg" xlink:href="shared.svg" style="background:url(shared.svg)"/>| <>
        ~s|<use xlink:href="shared.svg"/></svg>|

    assert rewrite(source, %{@opts | assets: ["css"]}) ==
             ~s|<svg><image href="shared.svg" xlink:href="shared.svg" style="background:url(#{offline("shared.svg")})"/>| <>
               ~s|<use xlink:href="shared.svg"/></svg>|
  end

  defp rewrite(source, opts) do
    assert {:ok, body} = LinkReplacer.replace_links(source, opts)
    body
  end

  defp offline(path), do: Linker.offline_link(@page, "http://example.com/" <> path)
end
