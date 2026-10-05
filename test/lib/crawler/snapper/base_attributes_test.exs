defmodule Crawler.Snapper.BaseAttributesTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker
  alias Crawler.Parser
  alias Crawler.Snapper
  alias Crawler.Snapper.LinkReplacer

  import Crawler.SnapshotHelpers, only: [assert_link_opens: 3, saved: 2]
  import Crawler.TestHelpers, only: [tmp: 1, unique_scope: 1]

  @page "http://example.com/index.html"
  @target "http://example.com/docs/next.html"
  @opts %{url: @page, content_type: "text/html", html_tag: "a", assets: []}

  test "base href removal preserves the target and all unrelated source attributes" do
    source =
      ~s|<BASE data-note='a>b' HREF="/docs/" TARGET='_blank' href="/ignored/" /><a href="next.html">A</a>|

    assert discovered(source) == [@target]
    href = Linker.offline_link(@page, @target)
    assert {:ok, body} = LinkReplacer.replace_links(source, @opts)
    assert body == ~s|<BASE data-note='a>b' TARGET='_blank' /><a href="#{href}">A</a>|
  end

  test "later hrefs cannot reactivate after removal and their targets remain intact" do
    source =
      ~s|<base href="/docs/" target="_blank"><base href="/wrong/" target="frame"><a href="next.html">A</a>|

    assert discovered(source) == [@target]
    href = Linker.offline_link(@page, @target)
    assert {:ok, body} = LinkReplacer.replace_links(source, @opts)
    assert body == ~s|<base target="_blank"><base target="frame"><a href="#{href}">A</a>|
  end

  test "href-only tags are removed while target-only and inactive base tags retain their bytes" do
    inactive = ~s|<template><base href="/wrong/" target="wrong"></template><base target="_blank">|
    source = inactive <> ~s|<base href="/docs/" href="/ignored/"><a href="next.html">A</a>|
    href = Linker.offline_link(@page, @target)
    assert {:ok, body} = LinkReplacer.replace_links(source, @opts)
    assert body == inactive <> ~s|<a href="#{href}">A</a>|
  end

  test "saved HTML preserves its base target and opens the resource resolved against the removed href" do
    root = tmp(unique_scope("base-attributes"))
    on_exit(fn -> File.rm_rf(root) end)
    source = ~s|<base href="/docs/" target="_blank"><a href="next.html">A</a>|

    assert {:ok, _} =
             Snapper.snap("TARGET", %{
               url: @target,
               save_to: root,
               content_type: "text/plain",
               html_tag: "a"
             })

    assert {:ok, _} = Snapper.snap(source, Map.put(@opts, :save_to, root))
    href = Linker.offline_link(@page, @target)

    assert File.read!(saved(root, @page)) ==
             <<0xEF, 0xBB, 0xBF>> <> ~s|<base target="_blank"><a href="#{href}">A</a>|

    assert_link_opens(root, @page, @target)
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
