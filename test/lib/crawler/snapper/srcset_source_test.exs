defmodule Crawler.Snapper.SrcsetSourceTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker
  alias Crawler.Parser
  alias Crawler.Snapper.LinkReplacer

  @page "http://example.com/index.html"
  @opts %{url: @page, content_type: "text/html", html_tag: "a", assets: ["images"]}

  for {tag, name} <- [{"img", "srcset"}, {~s|link rel="preload" as="image"|, "imagesrcset"}] do
    test "#{name} discovery and rewrite agree on encoded whitespace and comma boundaries" do
      tag = unquote(tag)
      name = unquote(name)
      source = ~s|<#{tag} #{name}="a.png&#32;1x&#44;&#x20;b.png&#x09;2x">|
      assert discovered(source) == ["http://example.com/a.png", "http://example.com/b.png"]
      a = Linker.offline_link(@page, "http://example.com/a.png")
      b = Linker.offline_link(@page, "http://example.com/b.png")
      assert {:ok, body} = LinkReplacer.replace_links(source, @opts)
      assert body == ~s|<#{tag} #{name}="#{a}&#32;1x&#44;&#x20;#{b}&#x09;2x">|
    end
  end

  test "an encoded comma inside a URL is not mistaken for a candidate delimiter" do
    source = ~s|<img srcset="a&#44;b.png&#32;1x&#44; next.png&#32;2x">|
    assert discovered(source) == ["http://example.com/a,b.png", "http://example.com/next.png"]
    comma = Linker.offline_link(@page, "http://example.com/a,b.png")
    next = Linker.offline_link(@page, "http://example.com/next.png")
    assert {:ok, body} = LinkReplacer.replace_links(source, @opts)
    assert body == ~s|<img srcset="#{comma}&#32;1x&#44; #{next}&#32;2x">|
  end

  test "inactive duplicate attributes and data candidates preserve exact source bytes" do
    source =
      ~s|<img srcset="data:image/png;base64,AAAA&#32;1x&#44; a.png&#32;2x" srcset="a.png&#32;1x">|

    assert discovered(source) == ["http://example.com/a.png"]
    a = Linker.offline_link(@page, "http://example.com/a.png")
    assert {:ok, body} = LinkReplacer.replace_links(source, @opts)

    assert body ==
             ~s|<img srcset="data:image/png;base64,AAAA&#32;1x&#44; #{a}&#32;2x" srcset="a.png&#32;1x">|

    assert {:ok, ^source} = LinkReplacer.replace_links(source, %{@opts | assets: []})
  end

  defp discovered(source) do
    source
    |> Parser.parse_links(@opts, fn
      {_, _, _, url}, _opts -> url
      {_, url}, _opts -> url
    end)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end
end
