defmodule Crawler.Snapper.CssCommentsTest do
  use ExUnit.Case, async: false

  import Crawler.TestHelpers, only: [tmp: 1]
  import Crawler.SnapshotHelpers, only: [saved_artifact: 2]

  alias Crawler.Linker
  alias Crawler.ManagedSnapshotHelpers, as: Managed
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
               ~s|<div style="background:image-set(#{normalized}http://example.com/css/images/*draft.png#{normalized} 1x)"></div>|
    end
  end

  test "entity-quoted image-set paths with parentheses open the saved images" do
    root = tmp("snapshot-css-entity-groups")
    page = "http://example.com/index.html"
    names = ["a)b.png", "a(b.png", "caf)é.png"]

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

      destination = Path.join(root, Integer.to_string(System.unique_integer([:positive])))
      File.mkdir_p!(destination)

      targets =
        for name <- names, do: {"http://example.com/" <> name, "IMAGE #{name}", "image/png"}

      {export, opts} =
        managed_export(destination, page, source, targets, assets: ["images", "css"])

      try do
        from = Managed.resource_for_url(export, page)

        hrefs =
          export
          |> Managed.read_resource(from)
          |> Floki.parse_document!()
          |> Floki.attribute("div", "style")
          |> hd()
          |> CssParser.parse()
          |> Enum.map(fn {"link", [{"href", href}], []} -> href end)

        assert length(hrefs) == length(names)

        for {href, name} <- Enum.zip(hrefs, names) do
          target = "http://example.com/" <> name
          to = Managed.reference_target(export, from, target)
          Managed.assert_opens(export, from, to, href)
          assert Managed.read_resource(export, to) == "IMAGE #{name}"
        end
      after
        Crawler.stop(opts)
        Crawler.Store.dispose_scope(opts.scope)
      end
    end
  end

  test "standalone public ID acknowledgements preserve entity-quoted image-set URLs and image bytes" do
    root = tmp("standalone-css-image-set-ack-source")
    page_url = "http://example.com/index.html"

    targets = [
      {"a)b.png", "standalone000000000010001"},
      {"a(b.png", "standalone000000000010002"},
      {"caf)é.png", "standalone000000000010003"}
    ]

    for {name, id} <- targets do
      assert {:ok, %{public_id: ^id} = artifact} =
               Snapper.snap("IMAGE #{name}", %{
                 public_id: id,
                 url: "http://example.com/" <> name,
                 save_to: root,
                 html_tag: "img",
                 content_type: "image/png"
               })

      assert File.read!(saved_artifact(root, artifact)) == "IMAGE #{name}"
    end

    for {opening, closing, id} <- [
          {"&quot;", "&quot;", "standalone000000000010004"},
          {"&#034;", "&#34;", "standalone000000000010005"},
          {"&#X0022;", "&#x22;", "standalone000000000010006"},
          {"&apos;", "&apos;", "standalone000000000010007"},
          {"&#039;", "&#39;", "standalone000000000010008"},
          {"&#X0027;", "&#x27;", "standalone000000000010009"}
        ] do
      candidates =
        Enum.map_join(targets, ",", fn {name, _id} -> "#{opening}#{name}#{closing} 1x" end)

      source = ~s|<div style="background:image-set(#{candidates})"></div>|

      assert {:ok, %{public_id: ^id} = artifact} =
               Snapper.snap(source, %{
                 public_id: id,
                 url: page_url,
                 save_to: root,
                 html_tag: "a",
                 content_type: "text/html",
                 assets: ["css"]
               })

      expected =
        Enum.map_join(targets, ",", fn {name, _id} ->
          "#{closing}http://example.com/#{name}#{closing} 1x"
        end)

      body = File.read!(saved_artifact(root, artifact))

      assert body ==
               <<0xEF, 0xBB, 0xBF>> <> ~s|<div style="background:image-set(#{expected})"></div>|

      [style] = body |> Floki.parse_document!() |> Floki.attribute("div", "style")

      hrefs =
        style |> CssParser.parse() |> Enum.map(fn {"link", [{"href", href}], []} -> href end)

      assert hrefs == Enum.map(targets, fn {name, _id} -> "http://example.com/" <> name end)
    end
  end

  test "saved CSS keeps comment bytes and rewrites only live references" do
    comment = ~s|/* url("real.png"); @import "theme.css"; image-set("wide.png" 1x); café */|
    source = comment <> ~s| .x { background:url("real.png") } @import "theme.css";|

    expected =
      comment <>
        ~s| .x { background:url("#{online("real.png")}") } @import "theme.css";|

    assert snapshot(source, "snapshot-css-comment-bytes") == expected
  end

  test "saved CSS preserves comment separators and quoted comment-like paths" do
    source =
      ~s|@import/* keep */"theme.css"; .x { background: image-set(/* first */"images/*draft.png" 1x,/* next */narrow.png 2x); }|

    expected =
      ~s|@import/* keep */"#{online("theme.css")}"; .x { background: image-set(/* first */"#{online("images/*draft.png")}" 1x,/* next */#{online("narrow.png")} 2x); }|

    assert snapshot(source, "snapshot-css-comment-separators") == expected
  end

  test "saved CSS uses URL token rules while preserving import and image-set comment trivia" do
    source =
      ~s|@import/* before import */"theme.css"/* after import */; .x { background:url(/* before URL */"real.png"/* after URL */),url(/* before bare */bare.png),image-set(/* before set */"wide.png"/* after set */ 1x); }|

    expected =
      ~s|@import/* before import */"#{online("theme.css")}"/* after import */; .x { background:url(/* before URL */"real.png"/* after URL */),url(/* before bare */bare.png),image-set(/* before set */"#{online("wide.png")}"/* after set */ 1x); }|

    assert snapshot(source, "snapshot-css-comments-within-values") == expected
  end

  test "saved CSS rewrites full comment-looking URL payloads and keeps bad URL tokens intact" do
    invalid = ~s|url(/*draft*/"hidden.png"),url(hidden.png /**/)|
    source = ~s|.x{background:url(/*draft*/image.png),url("real.png"/* after */),#{invalid}}|

    expected =
      ~s|.x{background:url(#{online("/*draft*/image.png")}),url("#{online("real.png")}"/* after */),#{invalid}}|

    assert snapshot(source, "snapshot-css-url-comment-payloads") == expected
  end

  test "saved CSS rewrites valid URLs at EOF while retaining omitted source delimiters" do
    for {source, expected} <- [
          {".a{background:url(image.png", ".a{background:url(#{online("image.png")}"},
          {"@import url(theme.css \n", "@import url(#{online("theme.css")} \n"},
          {~s|@import "theme.css|, ~s|@import "#{online("theme.css")}|},
          {~s|.a{background:url("image.png|, ~s|.a{background:url("#{online("image.png")}|},
          {~s|.a{background:url("image.png"/* after */|,
           ~s|.a{background:url("#{online("image.png")}"/* after */|}
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
      escaped <> whitespace <> ~s| .x { background:url("#{online("real.png")}") } | <> comment

    assert snapshot(source, "snapshot-css-unfinished-comment") == expected
  end

  test "saved CSS retains escaped URL function names while rewriting their resource tokens" do
    for identifier <- [~S|\75rl|, ~S|u\72l|, ~S|\000075 rl|, ~S|\u\r\l|, "\\000075\r\nrl"] do
      escaped = ".a{background:#{identifier}(raw/*draft.png)} "
      source = escaped <> ~s|.b{background:url("real.png") }|

      expected =
        ".a{background:#{identifier}(#{online("raw/*draft.png")})} " <>
          ~s|.b{background:url("#{online("real.png")}") }|

      assert snapshot(source, "snapshot-css-escaped-identifiers") == expected
    end
  end

  test "saved CSS preserves an ordinary string containing a live resource spelling" do
    literal = ~s|.label{content:"url(real.png) @import 'theme.css'; image-set('wide.png' 1x)"}|
    source = literal <> ~s|.live{background:url(real.png)}|
    expected = literal <> ~s|.live{background:url(#{online("real.png")})}|
    assert snapshot(source, "snapshot-css-ordinary-strings") == expected
  end

  test "saved CSS keeps hash payloads unchanged while rewriting adjacent URL functions" do
    opaque =
      ~S|.x{--opaque:#url(real.png);--escaped:#\75rl(hidden.png);--set:#image-set("hidden-set.png" 1x);}|

    source = opaque <> ~S|.live{background:u\72l(real.png)}|
    expected = opaque <> ~s|.live{background:u\\72l(#{online("real.png")})}|
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
      ~s|@\\49 MPORT "#{online("theme.css")}";| <>
        unknown <>
        ~s|.live{background:-WEB\\4B IT-IMAGE-SET("#{online("real.png")}" 1x),U\\52L(#{online("real.png")})}|

    assert snapshot(source, "snapshot-css-ascii-function-names") == expected
  end

  defp online(link), do: Linker.url(@page, link)

  defp snapshot(source, directory) do
    root = tmp(directory)

    assert {:ok, artifact} =
             Snapper.snap(source, %{
               url: @page,
               referrer_url: @page,
               save_to: root,
               public_id: "csscomments000000000000001",
               html_tag: "link",
               content_type: "text/css"
             })

    File.read!(saved_artifact(root, artifact))
  end

  defp managed_export(root, page, source, targets, options) do
    File.rmdir!(root)
    root = root <> "-#{System.pid()}-#{System.unique_integer([:positive])}"
    requests = Crawler.RequestLog.new()

    route_key = fn url ->
      uri = url |> Crawler.URL.canonical() |> URI.parse()
      URI.to_string(%{uri | query: uri.query || ""})
    end

    routes =
      Map.new([{page, source, "text/html"} | targets], fn {url, body, type} ->
        {route_key.(url), {body, type}}
      end)

    plug = fn conn ->
      key = conn |> Plug.Conn.request_url() |> route_key.()
      Crawler.RequestLog.record(requests, key)
      {body, type} = Map.fetch!(routes, key)
      conn |> Plug.Conn.put_resp_header("content-type", type) |> Plug.Conn.resp(200, body)
    end

    assert {:ok, opts} =
             Crawler.crawl(
               page,
               Keyword.merge(
                 [
                   scope: Crawler.TestHelpers.unique_scope("managed-snapshot"),
                   save_to: root,
                   store: nil,
                   workers: 1,
                   max_body: 1_048_576,
                   max_analysis_bytes: 16_777_216,
                   max_css_work: 5_000,
                   max_css_pictures: 1_000,
                   max_depths: 3,
                   respect_robots: false,
                   req_options: [plug: plug, retry: false]
                 ],
                 options
               )
             )

    on_exit(fn ->
      Crawler.stop(opts)
      Crawler.Store.dispose_scope(opts.scope)
      File.rm_rf!(root)
    end)

    export = Managed.ready_export(opts)

    assert Crawler.RequestLog.frequencies(requests) ==
             Map.new(routes, fn {url, _} -> {url, 1} end)

    {export, opts}
  end
end
