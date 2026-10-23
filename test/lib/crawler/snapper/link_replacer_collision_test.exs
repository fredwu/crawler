defmodule Crawler.Snapper.LinkReplacerCollisionTest do
  use ExUnit.Case, async: true

  alias Crawler.Snapper.LinkReplacer
  alias Crawler.StandaloneRewriteHelpers

  @page "http://ex.com/index.html"
  @relative "../ex.com/foo.html"
  @absolute "http://ex.com/foo.html"

  for {name, content_type, template} <- [
        {"quoted attributes", "text/html", ~s|<a href="FIRST">one</a><a href="SECOND">two</a>|},
        {"unquoted attributes", "text/html", "<a href=FIRST>one</a><a href=SECOND>two</a>"},
        {"srcset", "text/html", ~s|<img srcset="FIRST 1x, SECOND 2x">|},
        {"imagesrcset", "text/html",
         ~s|<link rel="preload" as="image" imagesrcset="FIRST 1x, SECOND 2x">|},
        {"refresh", "text/html",
         ~s|<meta http-equiv="refresh" content="0; url=FIRST"><meta http-equiv="refresh" content="0; url=SECOND">|},
        {"style attributes", "text/html",
         ~s|<div style='background:url("FIRST"),url("SECOND")'></div>|},
        {"raw styles", "text/html", ~s|<style>.x{background:url("FIRST"),url("SECOND")}</style>|},
        {"module scripts", "text/html",
         ~s|<script type="module">import "FIRST";import "SECOND";</script>|},
        {"CSS URLs", "text/css", ~s|.x{background:url("FIRST"),url("SECOND")}|},
        {"CSS imports", "text/css", ~s|@import "FIRST";@import "SECOND";|},
        {"CSS image-set", "text/css", ~s|.x{background:image-set("FIRST" 1x,"SECOND" 2x)}|},
        {"JavaScript", "application/javascript", ~s|import "FIRST";import "SECOND";|}
      ] do
    test "rewrites original #{name} once when an output matches another input" do
      template = unquote(template)
      source = render(template, @relative, @absolute)
      relative_output = "fixtures/first.html"
      absolute_output = @relative

      assert {:ok, body} =
               StandaloneRewriteHelpers.replace_bound(
                 source,
                 opts(unquote(content_type)),
                 fn
                   %{value: @relative} -> :first
                   %{value: @absolute} -> :second
                 end,
                 %{first: {:ok, relative_output}, second: {:ok, absolute_output}}
               )

      assert body == render(template, relative_output, absolute_output)
    end
  end

  test "preserves source text that resembles replacement tokens" do
    literal = <<0>> <> "L0" <> <<0>> <> " " <> <<0>> <> "LL0" <> <<0>>
    source = "<!-- " <> literal <> " -->" <> ~s|<a href="#{@absolute}">one</a>|

    assert {:ok, body} = LinkReplacer.replace_links(source, opts("text/html"))

    assert body ==
             "<!-- " <>
               literal <>
               " -->" <>
               ~s|<a href="#{@absolute}">one</a>|
  end

  test "preserves raw text protection tokens in markup and raw text" do
    literal = <<0>> <> "R0" <> <<0>> <> " " <> <<0>> <> "RR0" <> <<0>>

    source =
      "<p>" <>
        literal <>
        "</p>" <>
        ~s|<style>.x{background:url("a.png")}/* | <>
        literal <>
        " */</style>" <>
        "<textarea>" <> literal <> "</textarea>"

    assert {:ok, body} = LinkReplacer.replace_links(source, opts("text/html"))

    assert body ==
             String.replace(
               source,
               ~s|url("a.png")|,
               ~s|url("http://ex.com/a.png")|
             )
  end

  test "preserves data protection tokens in CSS and in data URLs" do
    literal = <<0>> <> "D0" <> <<0>> <> " " <> <<0>> <> "DD0" <> <<0>>
    data = ~s|"data:image/svg+xml,<svg>#{literal}a.png</svg>"|
    source = ~s|.x{background:url(#{data}),url("a.png")}/* #{literal} */|

    assert {:ok, body} = LinkReplacer.replace_links(source, opts("text/css"))

    assert body ==
             String.replace(
               source,
               ~s|url("a.png")|,
               ~s|url("http://ex.com/a.png")|
             )
  end

  defp render(template, first, second) do
    template |> String.replace("FIRST", first) |> String.replace("SECOND", second)
  end

  defp opts(content_type) do
    %{
      url: @page,
      referrer_url: @page,
      content_type: content_type,
      html_tag: "a",
      assets: ["images", "css", "js"],
      depth: 1,
      max_depths: 3
    }
  end
end
