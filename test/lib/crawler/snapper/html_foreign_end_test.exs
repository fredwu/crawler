defmodule Crawler.Snapper.HTMLForeignEndTest do
  use Crawler.OfflineLinkCase, async: true

  import Crawler.SnapshotHelpers, only: [saved: 2]
  import Crawler.TestHelpers, only: [tmp: 1]

  alias Crawler.Parser
  alias Crawler.Parser.HtmlParser
  alias Crawler.Snapper

  for foreign <- ["svg", "math"], closing <- ["p", "br"] do
    test "#{foreign} </#{closing}> preserves apparent links as script text in the saved source" do
      foreign = unquote(foreign)
      closing = unquote(closing)
      root = tmp("snapshot-foreign-end-#{foreign}-#{closing}")

      source =
        "<#{foreign}></#{closing}><script/>" <>
          ~s|<base href="/wrong/"><a href="next">literal</a>|

      assert discovered(source) == []
      assert HtmlParser.parse(source, %{}) == []
      assert rewrite(source, @page) == source

      assert {:ok, _opts} =
               Snapper.snap(source, %{
                 url: @page,
                 save_to: root,
                 content_type: "text/html",
                 html_tag: "a",
                 assets: [],
                 depth: 1,
                 max_depths: 3
               })

      assert File.read!(saved(root, @page)) == <<0xEF, 0xBB, 0xBF>> <> source
    end

    test "#{foreign} </#{closing}> rewrites only real links after the script closes" do
      literal =
        "<#{unquote(foreign)}></#{unquote(closing)}><script/>" <>
          ~s|<base href="/wrong/"><a href="next">Literal</a></script>|

      source = literal <> ~s|<base href="/docs/"><a href="next">Out</a>|
      target = "http://example.com/docs/next"
      href = Linker.offline_link(@page, target)

      assert discovered(source) == [target]
      assert rewrite(source, @page) == literal <> ~s|<a href="#{href}">Out</a>|
    end

    test "#{foreign} </#{closing}> recovery keeps template links inert" do
      inert =
        "<template><#{unquote(foreign)}></#{unquote(closing)}><script/>" <>
          ~s|<a href="next">Literal</a></script><a href="next">In</a></template>|

      source = inert <> ~s|<a href="next">Out</a>|
      target = "http://example.com/blog/next"
      href = Linker.offline_link(@page, target)

      assert discovered(source) == [target]
      assert rewrite(source, @page) == inert <> ~s|<a href="#{href}">Out</a>|
    end
  end

  defp discovered(source) do
    source
    |> Parser.parse_links(
      %{
        url: @page,
        referrer_url: @page,
        content_type: "text/html",
        html_tag: "a",
        assets: [],
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
