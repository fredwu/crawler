defmodule Crawler.Snapper.JavascriptSourceGoalTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker
  alias Crawler.Snapper.LinkReplacer

  @page "http://example.com/dir/page"
  @source ~S|const n=await /g;var await=4;import(".\/hidden.js");const m=g/g;import("./real.js");|

  test "identical inline source rewrites imports and preserves module regexp bytes" do
    source = ~s|<script>#{@source}</script><script type="module">#{@source}</script>|

    expected =
      ~s|<script>#{expected(:script)}</script><script type="module">#{expected(:module)}</script>|

    assert {:ok, ^expected} =
             LinkReplacer.replace_links(source, %{
               url: @page,
               content_type: "text/html",
               html_tag: "a",
               assets: ["js"],
               javascript_goal: :script
             })
  end

  test "direct JavaScript discovery and saved source use the supplied exact goal" do
    for goal <- [:script, :module] do
      assert {:ok, body} =
               LinkReplacer.replace_links(@source, %{
                 url: @page,
                 content_type: "application/javascript",
                 html_tag: "script",
                 javascript_goal: goal
               })

      assert body == expected(goal)
    end

    assert {:ok, body} =
             LinkReplacer.replace_links(@source, %{
               url: @page,
               content_type: "application/javascript",
               html_tag: "script"
             })

    assert body == expected(:module)
  end

  defp expected(goal) do
    source =
      String.replace(
        @source,
        ~s|"./real.js"|,
        ~s|"#{Linker.offline_link(@page, "http://example.com/dir/real.js")}"|
      )

    if goal == :script do
      String.replace(
        source,
        ~S|".\/hidden.js"|,
        ~s|"#{Linker.offline_link(@page, "http://example.com/dir/hidden.js")}"|
      )
    else
      source
    end
  end
end
