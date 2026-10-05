defmodule Crawler.Snapper.LinkReplacerIntegrityTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker
  alias Crawler.Snapper.LinkReplacer

  @page "http://example.com/index.html"
  @script "http://example.com/app.js"
  @stylesheet "http://example.com/app.css"
  @integrity "sha256-valid-original-hash"

  test "rewrites a sole modulepreload reference and removes its integrity" do
    source = ~s|<link rel="ModulePreload" href="only.js" integrity="#{@integrity}">|

    assert {:ok, body} = LinkReplacer.replace_links(source, opts())

    assert body ==
             ~s|<link rel="ModulePreload" href="#{Linker.offline_link(@page, "only.js")}">|
  end

  for {as, file} <- [{"script", "app.js"}, {"style", "app.css"}],
      rel <- ["preload", "alternate PreLoad"] do
    test "removes integrity from a rewritten #{rel} reference with as=#{as}" do
      source =
        ~s|<link rel="#{unquote(rel)}" as="#{String.upcase(unquote(as))}" href="#{unquote(file)}" integrity="#{@integrity}">|

      assert {:ok, body} = LinkReplacer.replace_links(source, opts())

      assert body ==
               source
               |> String.replace(~s| integrity="#{@integrity}"|, "")
               |> String.replace(unquote(file), Linker.offline_link(@page, unquote(file)))
    end
  end

  test "preserves integrity on untouched script and style preload references" do
    source = """
    <link rel="preload" as="script" href="app.js" integrity="#{@integrity}">
    <link rel="preload" as="style" href="app.css" integrity="#{@integrity}">
    """

    assert {:ok, ^source} = LinkReplacer.replace_links(source, %{opts() | assets: []})

    inline = """
    <link rel="preload" as="script" href="data:text/javascript,void(0)" integrity="#{@integrity}">
    <link rel="preload" as="style" href="data:text/css,body{}" integrity="#{@integrity}">
    """

    assert {:ok, ^inline} = LinkReplacer.replace_links(inline, opts())
  end

  test "preserves integrity on rewritten image, font and icon references" do
    source = """
    <link rel="preload" as="image" href="photo.png" integrity="#{@integrity}">
    <link rel="preload" as="font" href="font.woff2" integrity="#{@integrity}">
    <link rel="icon" href="icon.png" integrity="#{@integrity}">
    """

    assert {:ok, body} = LinkReplacer.replace_links(source, %{opts() | assets: ["css", "images"]})

    expected =
      Enum.reduce(["photo.png", "font.woff2", "icon.png"], source, fn file, body ->
        String.replace(body, file, Linker.offline_link(@page, file))
      end)

    assert body == expected
  end

  for template <- [
        ~s|<script src="app.js" integrity="HASH"></script>|,
        ~s|<SCRIPT INTEGRITY='HASH' SRC=app.js></SCRIPT>|,
        ~s|<script data-integrity="keep" title="fake integrity='keep'" src="app.js" integrity=HASH></script>|,
        ~s|<script integrity="HASH" src="app.js" data-note="integrity='keep'"></script>|
      ] do
    test "removes the actual integrity attribute from #{template}" do
      source = String.replace(unquote(template), "HASH", @integrity)
      assert {:ok, body} = LinkReplacer.replace_links(source, opts())

      expected =
        source
        |> String.replace(
          ~r/ INTEGRITY='[^']*'| integrity="[^"]*"| integrity=sha256-valid-original-hash/,
          ""
        )
        |> String.replace("app.js", Linker.offline_link(@page, @script))

      assert body == expected
    end
  end

  test "removes stylesheet and modulepreload integrity after their references are rewritten" do
    source = """
    <script src="app.js"></script>
    <link rel="modulepreload" href="app.js" integrity="#{@integrity}">
    <link rel="alternate StyleSheet" href="app.css" integrity="#{@integrity}">
    """

    assert {:ok, body} = LinkReplacer.replace_links(source, opts())

    assert body ==
             source
             |> String.replace(~s| integrity="#{@integrity}"|, "")
             |> String.replace("app.js", Linker.offline_link(@page, @script))
             |> String.replace("app.css", Linker.offline_link(@page, @stylesheet))
  end

  test "preserves integrity on untouched references and in inline content" do
    source = """
    <script src="data:text/javascript,void(0)" integrity="#{@integrity}"></script>
    <script src="app.js" integrity="#{@integrity}"></script>
    <link rel="stylesheet" href="app.css" integrity="#{@integrity}">
    <script>const note = '<script integrity="#{@integrity}">';</script>
    <div title="<script integrity='#{@integrity}'>"></div>
    """

    assert {:ok, unchanged} =
             LinkReplacer.replace_links(source, %{opts() | assets: []})

    assert unchanged == source

    assert {:ok, rewritten} = LinkReplacer.replace_links(source, opts())
    assert rewritten =~ ~s|src="data:text/javascript,void(0)" integrity="#{@integrity}"|
    assert rewritten =~ ~s|const note = '<script integrity="#{@integrity}">';|
    assert rewritten =~ ~s|<div title="<script integrity='#{@integrity}'>"></div>|
  end

  test "requires a supported resource relation and preload destination" do
    source = """
    <link rel="stylesheet" href="app.css">
    <link data-rel="stylesheet" href="app.css" integrity="#{@integrity}">
    <link rel="icon" title="rel='stylesheet'" href="app.css" integrity="#{@integrity}">
    <link rel="preload" data-as="style" href="app.css" integrity="#{@integrity}">
    <link rel="preload" title="as='style'" href="app.css" integrity="#{@integrity}">
    """

    assert {:ok, body} = LinkReplacer.replace_links(source, opts())

    assert body ==
             String.replace(
               source,
               ~s|<link rel="stylesheet" href="app.css">|,
               ~s|<link rel="stylesheet" href="#{Linker.offline_link(@page, @stylesheet)}">|
             )
  end

  defp opts do
    %{
      url: @page,
      referrer_url: @page,
      content_type: "text/html",
      html_tag: "a",
      assets: ["css", "js"],
      depth: 1,
      max_depths: 3
    }
  end
end
