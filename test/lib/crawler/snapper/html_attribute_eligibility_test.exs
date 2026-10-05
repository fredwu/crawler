defmodule Crawler.Snapper.HTMLAttributeEligibilityTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker
  alias Crawler.Snapper.LinkReplacer

  @page "http://example.com/index.html"
  @opts %{url: @page, content_type: "text/html", html_tag: "a", assets: ["images", "css", "js"]}

  test "ignored imagesrcset retains matching source bytes beside enabled image references" do
    ignored =
      ~s|<img imagesrcset="shared.png&#32;1x">| <>
        ~s|<source imagesrcset="shared.png 1x">| <>
        ~s|<link imagesrcset="shared.png 1x">| <>
        ~s|<link rel="icon" as="image" imagesrcset="shared.png 1x">| <>
        ~s|<link rel="preload" as=" image " imagesrcset="shared.png 1x">| <>
        ~s|<link rel="preload" as="&#160;image&#160;" imagesrcset="shared.png 1x">| <>
        ~s|<link rel="&#160;preload&#160;" as="image" imagesrcset="shared.png 1x">|

    source =
      ignored <>
        ~s|<img src="shared.png" srcset="shared.png 1x" imagesrcset="shared.png 1x">| <>
        ~s|<source src="shared.png" srcset="shared.png 1x" imagesrcset="shared.png 1x">| <>
        ~s|<link rel="alternate&#9;PRELOAD" as="IM&#65;GE" imagesrcset="shared.png&#32;1x">|

    target = offline("shared.png")

    assert rewrite(source) ==
             ignored <>
               ~s|<img src="#{target}" srcset="#{target} 1x" imagesrcset="shared.png 1x">| <>
               ~s|<source src="#{target}" srcset="#{target} 1x" imagesrcset="shared.png 1x">| <>
               ~s|<link rel="alternate&#9;PRELOAD" as="IM&#65;GE" imagesrcset="#{target}&#32;1x">|

    assert rewrite(source, %{@opts | assets: []}) == source
  end

  test "ignored rel and enum spellings retain URLs and integrity beside eligible resources" do
    ignored =
      ~s|<link rel="&#160;stylesheet&#160;" href="shared" integrity="keep">| <>
        ~s|<link rel="preload" as=" script " href="shared" integrity="keep">| <>
        ~s|<link rel="preload" as="&#160;style&#160;" href="shared" integrity="keep">| <>
        ~s|<meta http-equiv=" refresh " content="0; shared">| <>
        ~s|<meta http-equiv="&#160;refresh&#160;" content="0; shared">|

    source =
      ignored <>
        ~s|<link rel="&#9;STYLESHEET&#10;" href="shared" integrity="remove">| <>
        ~s|<link rel="preload" as="SCRIPT" href="shared" integrity="remove">| <>
        ~s|<meta http-equiv="ReFrEsH" content="0; shared">|

    target = offline("shared")

    assert rewrite(source) ==
             ignored <>
               ~s|<link rel="&#9;STYLESHEET&#10;" href="#{target}">| <>
               ~s|<link rel="preload" as="SCRIPT" href="#{target}">| <>
               ~s|<meta http-equiv="ReFrEsH" content="0; #{target}">|
  end

  defp rewrite(source, opts \\ @opts) do
    assert {:ok, body} = LinkReplacer.replace_links(source, opts)
    body
  end

  defp offline(path), do: Linker.offline_link(@page, "http://example.com/" <> path)
end
