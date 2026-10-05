defmodule Crawler.Snapper.JavascriptMimeTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker
  alias Crawler.Snapper.LinkReplacer

  @page "http://example.com/dir/page"
  @javascript ~w(
    application/ecmascript application/javascript application/x-ecmascript
    application/x-javascript text/ecmascript text/javascript text/javascript1.0
    text/javascript1.1 text/javascript1.2 text/javascript1.3 text/javascript1.4
    text/javascript1.5 text/jscript text/livescript text/x-ecmascript text/x-javascript
  )

  test "all executable aliases rewrite external and inline sources for saving" do
    external = Linker.offline_link(@page, "http://example.com/dir/external.js")
    chunk = Linker.offline_link(@page, "http://example.com/dir/chunk.js")

    for type <- @javascript do
      source =
        ~s|<script type="#{type}" src="external.js" integrity="remove">import('./ignored.js');</script>| <>
          ~s|<script type="#{type}">import('./chunk.js');</script>|

      expected =
        ~s|<script type="#{type}" src="#{external}">import('./ignored.js');</script>| <>
          ~s|<script type="#{type}">import('#{chunk}');</script>|

      assert rewrite(source, "text/html") == expected
    end
  end

  test "data types and MIME parameters keep script source bytes intact" do
    for type <- ["text/javascript1.6", "application/json", "text/jscript; charset=utf-8"] do
      source =
        ~s|<script type="#{type}" language="javascript" src="external.js" integrity="keep">import('./chunk.js');</script>| <>
          ~s|<script type="#{type}">import('./chunk.js');</script>|

      assert rewrite(source, "text/html") == source
    end
  end

  test "all JavaScript response aliases rewrite their dependency sources" do
    chunk = Linker.offline_link(@page, "http://example.com/dir/chunk.js")

    for type <- @javascript do
      assert rewrite(~s|import('./chunk.js');|, type <> "; charset=utf-8") ==
               ~s|import('#{chunk}');|
    end
  end

  defp rewrite(source, type) do
    assert {:ok, body} =
             LinkReplacer.replace_links(source, %{
               url: @page,
               referrer_url: @page,
               content_type: type,
               html_tag: "a",
               assets: ["js"]
             })

    body
  end
end
