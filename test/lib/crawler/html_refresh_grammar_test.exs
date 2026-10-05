defmodule Crawler.HTMLRefreshGrammarTest do
  use ExUnit.Case, async: true

  alias Crawler.HTMLRefresh
  alias Crawler.Linker
  alias Crawler.Parser
  alias Crawler.Snapper.LinkReplacer

  @page "http://example.com/dir/page"

  for {content, target} <- [
        {"0; /landing?url=/other", "/landing?url=/other"},
        {"0; /landing", "/landing"},
        {" 0.5, URL = '/landing?url=/other' trailing", "/landing?url=/other"},
        {"0 /landing?x=1&y=2", "/landing?x=1&y=2"},
        {".5; url=\"/landing\"", "/landing"},
        {"0; '/landing", "/landing"}
      ] do
    test "discovers and rewrites the complete refresh target in #{content}" do
      content = unquote(content)
      target = unquote(target)
      %{span: {at, length}, url: ^target} = HTMLRefresh.target(content)
      assert binary_part(content, at, length) == target
      encoded = content |> String.replace("&", "&amp;") |> String.replace("\"", "&quot;")
      source = ~s|<meta http-equiv="refresh" content="#{encoded}">|
      opts = %{url: @page, content_type: "text/html", html_tag: "a", assets: []}

      assert [{"link", ^target, "content", resolved}] =
               Parser.parse_links(source, opts, fn element, _opts -> element end)

      assert {:ok, body} = LinkReplacer.replace_links(source, opts)
      offline = Linker.offline_link(@page, resolved)
      encoded_target = String.replace(target, "&", "&amp;")
      assert body == String.replace(source, encoded_target, offline)
    end
  end

  for content <- ["0", "0;", "0; URL=", "invalid; URL=/next", "0x; URL=/next"] do
    test "rejects a missing or invalid refresh destination in #{content}" do
      content = unquote(content)
      assert HTMLRefresh.target(content) == nil
    end
  end

  test "does not replace a query substring or a non-refresh content attribute" do
    source =
      ~s|<meta http-equiv="refresh" content="0; /landing?url=/other">| <>
        ~s|<meta content="0; /landing?url=/other">|

    opts = %{url: @page, content_type: "text/html", html_tag: "a", assets: []}
    assert {:ok, body} = LinkReplacer.replace_links(source, opts)
    assert body =~ ~s|<meta content="0; /landing?url=/other">|
    assert body =~ "?url=/other"
  end
end
