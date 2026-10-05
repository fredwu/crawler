defmodule Crawler.Snapper.CssCommentsTest do
  use ExUnit.Case, async: true

  import Crawler.TestHelpers, only: [tmp: 1]
  import Crawler.SnapshotHelpers, only: [link_path: 1, saved: 2]

  alias Crawler.Linker
  alias Crawler.Linker.Snapshot
  alias Crawler.Parser.CssParser
  alias Crawler.Snapper
  alias Crawler.Snapper.LinkReplacer

  @page "http://example.com/css/app.css"

  test "HTML style attributes keep entity-quoted comment-like paths intact" do
    for {quote, normalized} <- [
          {"&quot;", "&quot;"},
          {"&#034;", "&#34;"},
          {"&#x022;", "&#x22;"},
          {"&apos;", "&apos;"},
          {"&#039;", "&#39;"},
          {"&#x027;", "&#x27;"}
        ] do
      source = ~s|<div style="background:image-set(#{quote}images/*draft.png#{quote} 1x)"></div>|

      assert {:ok, body} =
               LinkReplacer.replace_links(source, %{
                 url: @page,
                 html_tag: "a",
                 content_type: "text/html",
                 assets: ["css"]
               })

      assert body ==
               ~s|<div style="background:image-set(#{normalized}#{offline("images/*draft.png")}#{normalized} 1x)"></div>|
    end
  end

  test "entity-quoted image-set paths with parentheses open the saved images" do
    root = tmp("snapshot-css-entity-groups")
    page = "http://example.com/index.html"
    names = ["a)b.png", "a(b.png", "caf)é.png"]

    for name <- names do
      assert {:ok, _opts} =
               Snapper.snap("IMAGE #{name}", %{
                 url: "http://example.com/" <> name,
                 save_to: root,
                 html_tag: "img",
                 content_type: "image/png"
               })
    end

    for {opening, closing} <- [
          {"&quot;", "&quot;"},
          {"&#034;", "&#34;"},
          {"&#X0022;", "&#x22;"},
          {"&apos;", "&apos;"},
          {"&#039;", "&#39;"},
          {"&#X0027;", "&#x27;"}
        ] do
      candidates = Enum.map_join(names, ",", &"#{opening}#{&1}#{closing} 1x")
      source = ~s|<div style="background:image-set(#{candidates})"></div>|

      assert {:ok, _opts} =
               Snapper.snap(source, %{
                 url: page,
                 save_to: root,
                 html_tag: "a",
                 content_type: "text/html",
                 assets: ["css"]
               })

      hrefs =
        root
        |> saved(page)
        |> File.read!()
        |> Floki.parse_document!()
        |> Floki.attribute("div", "style")
        |> hd()
        |> CssParser.parse()
        |> Enum.map(fn {"link", [{"href", href}], []} -> href end)

      assert length(hrefs) == length(names)

      for {href, name} <- Enum.zip(hrefs, names) do
        target = "http://example.com/" <> name
        assert href == Linker.offline_link(page, target)
        opened = Path.expand(link_path(href), Path.dirname(saved(root, page)))
        assert opened == Path.expand(saved(root, target))
        assert File.read!(opened) == "IMAGE #{name}"
      end
    end
  end

  test "saved CSS keeps comment bytes and rewrites only live references" do
    comment = ~s|/* url("real.png"); @import "theme.css"; image-set("wide.png" 1x); café */|
    source = comment <> ~s| .x { background:url("real.png") } @import "theme.css";|

    expected =
      comment <>
        ~s| .x { background:url("#{offline("real.png")}") } @import "#{offline("theme.css")}";|

    assert snapshot(source, "snapshot-css-comment-bytes") == expected
  end

  test "saved CSS preserves comment separators and quoted comment-like paths" do
    source =
      ~s|@import/* keep */"theme.css"; .x { background: image-set(/* first */"images/*draft.png" 1x,/* next */narrow.png 2x); }|

    expected =
      ~s|@import/* keep */"#{offline("theme.css")}"; .x { background: image-set(/* first */"#{offline("images/*draft.png")}" 1x,/* next */#{offline("narrow.png")} 2x); }|

    assert snapshot(source, "snapshot-css-comment-separators") == expected
  end

  test "saved CSS uses URL token rules while preserving import and image-set comment trivia" do
    source =
      ~s|@import/* before import */"theme.css"/* after import */; .x { background:url(/* before URL */"real.png"/* after URL */),url(/* before bare */bare.png),image-set(/* before set */"wide.png"/* after set */ 1x); }|

    expected =
      ~s|@import/* before import */"#{offline("theme.css")}"/* after import */; .x { background:url(/* before URL */"real.png"/* after URL */),url(/* before bare */bare.png),image-set(/* before set */"#{offline("wide.png")}"/* after set */ 1x); }|

    assert snapshot(source, "snapshot-css-comments-within-values") == expected
  end

  test "saved CSS rewrites full comment-looking URL payloads and keeps bad URL tokens intact" do
    invalid = ~s|url(/*draft*/"hidden.png"),url(hidden.png /**/)|
    source = ~s|.x{background:url(/*draft*/image.png),url("real.png"/* after */),#{invalid}}|

    expected =
      ~s|.x{background:url(#{offline("/*draft*/image.png")}),url("#{offline("real.png")}"/* after */),#{invalid}}|

    assert snapshot(source, "snapshot-css-url-comment-payloads") == expected
  end

  test "saved CSS rewrites valid URLs at EOF while retaining omitted source delimiters" do
    for {source, expected} <- [
          {".a{background:url(image.png", ".a{background:url(#{offline("image.png")}"},
          {"@import url(theme.css \n", "@import url(#{offline("theme.css")} \n"},
          {~s|@import "theme.css|, ~s|@import "#{offline("theme.css")}|},
          {~s|.a{background:url("image.png|, ~s|.a{background:url("#{offline("image.png")}|},
          {~s|.a{background:url("image.png"/* after */|,
           ~s|.a{background:url("#{offline("image.png")}"/* after */|}
        ] do
      assert snapshot(source, "snapshot-css-url-eof") == expected
    end
  end

  test "saved CSS preserves escaped text, token-like whitespace, and unfinished comments" do
    escaped = ~S|.note { --text: \/*; }|
    whitespace = "\r\t\f\r\t\t\f"
    comment = ~s|/* url("real.png") @import "hidden.css"|
    source = escaped <> whitespace <> ~s| .x { background:url("real.png") } | <> comment

    expected =
      escaped <> whitespace <> ~s| .x { background:url("#{offline("real.png")}") } | <> comment

    assert snapshot(source, "snapshot-css-unfinished-comment") == expected
  end

  test "saved CSS retains escaped URL function names while rewriting their resource tokens" do
    for identifier <- [~S|\75rl|, ~S|u\72l|, ~S|\000075 rl|, ~S|\u\r\l|, "\\000075\r\nrl"] do
      escaped = ".a{background:#{identifier}(raw/*draft.png)} "
      source = escaped <> ~s|.b{background:url("real.png") }|

      expected =
        ".a{background:#{identifier}(#{offline("raw/*draft.png")})} " <>
          ~s|.b{background:url("#{offline("real.png")}") }|

      assert snapshot(source, "snapshot-css-escaped-identifiers") == expected
    end
  end

  test "saved CSS preserves an ordinary string containing a live resource spelling" do
    literal = ~s|.label{content:"url(real.png) @import 'theme.css'; image-set('wide.png' 1x)"}|
    source = literal <> ~s|.live{background:url(real.png)}|
    expected = literal <> ~s|.live{background:url(#{offline("real.png")})}|
    assert snapshot(source, "snapshot-css-ordinary-strings") == expected
  end

  test "saved CSS keeps hash payloads unchanged while rewriting adjacent URL functions" do
    opaque =
      ~S|.x{--opaque:#url(real.png);--escaped:#\75rl(hidden.png);--set:#image-set("hidden-set.png" 1x);}|

    source = opaque <> ~S|.live{background:u\72l(real.png)}|
    expected = opaque <> ~s|.live{background:u\\72l(#{offline("real.png")})}|
    assert snapshot(source, "snapshot-css-hash-tokens") == expected
  end

  test "saved CSS keeps Unicode lookalike functions while rewriting ASCII built-in names" do
    unknown =
      ~S|.unknown{background:-webKit-image-set("real.png" 1x),-web\212A it-image-set("hidden.png" 1x)}|

    source =
      ~S|@\49 MPORT "theme.css";| <>
        unknown <>
        ~S|.live{background:-WEB\4B IT-IMAGE-SET("real.png" 1x),U\52L(real.png)}|

    expected =
      ~s|@\\49 MPORT "#{offline("theme.css")}";| <>
        unknown <>
        ~s|.live{background:-WEB\\4B IT-IMAGE-SET("#{offline("real.png")}" 1x),U\\52L(#{offline("real.png")})}|

    assert snapshot(source, "snapshot-css-ascii-function-names") == expected
  end

  defp offline(link), do: Linker.offline_link(@page, link)

  defp snapshot(source, directory) do
    root = tmp(directory)

    assert {:ok, _opts} =
             Snapper.snap(source, %{
               url: @page,
               referrer_url: @page,
               save_to: root,
               html_tag: "link",
               content_type: "text/css"
             })

    File.read!(Path.join(root, Snapshot.path(@page)))
  end
end
