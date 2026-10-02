defmodule Crawler.Snapper.LinkReplacerIntegrityTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker
  alias Crawler.Snapper.LinkReplacer

  @page "http://example.com/index.html"
  @script "http://example.com/app.js"
  @stylesheet "http://example.com/app.css"
  @integrity "sha256-valid-original-hash"

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

  test "requires an actual stylesheet or modulepreload relation" do
    source = """
    <link rel="stylesheet" href="app.css">
    <link data-rel="stylesheet" href="app.css" integrity="#{@integrity}">
    <link rel="icon" title="rel='stylesheet'" href="app.css" integrity="#{@integrity}">
    """

    assert {:ok, body} = LinkReplacer.replace_links(source, opts())
    assert body == String.replace(source, "app.css", Linker.offline_link(@page, @stylesheet))
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
