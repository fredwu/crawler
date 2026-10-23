defmodule Crawler.Snapper.BaseAttributesTest do
  use ExUnit.Case, async: false

  alias Crawler.ManagedSnapshotHelpers, as: Managed
  alias Crawler.Parser
  alias Crawler.Snapper
  alias Crawler.Snapper.LinkReplacer

  import Crawler.SnapshotHelpers, only: [saved_artifact: 2]
  import Crawler.TestHelpers, only: [tmp: 1, unique_scope: 1]

  @page "http://example.com/index.html"
  @target "http://example.com/docs/next.html"
  @opts %{url: @page, content_type: "text/html", html_tag: "a", assets: []}

  test "base href removal preserves the target and all unrelated source attributes" do
    source =
      ~s|<BASE data-note='a>b' HREF="/docs/" TARGET='_blank' href="/ignored/" /><a href="next.html">A</a>|

    assert discovered(source) == [@target]
    href = @target
    assert {:ok, body} = LinkReplacer.replace_links(source, @opts)
    assert body == ~s|<BASE data-note='a>b' TARGET='_blank' /><a href="#{href}">A</a>|
  end

  test "later hrefs cannot reactivate after removal and their targets remain intact" do
    source =
      ~s|<base href="/docs/" target="_blank"><base href="/wrong/" target="frame"><a href="next.html">A</a>|

    assert discovered(source) == [@target]
    href = @target
    assert {:ok, body} = LinkReplacer.replace_links(source, @opts)
    assert body == ~s|<base target="_blank"><base target="frame"><a href="#{href}">A</a>|
  end

  test "href-only tags become inert while target-only and inactive base tags retain their bytes" do
    inactive = ~s|<template><base href="/wrong/" target="wrong"></template><base target="_blank">|
    source = inactive <> ~s|<base href="/docs/" href="/ignored/"><a href="next.html">A</a>|
    href = @target
    assert {:ok, body} = LinkReplacer.replace_links(source, @opts)
    assert body == inactive <> ~s|<base><a href="#{href}">A</a>|
  end

  test "saved HTML preserves its base target and opens the resource resolved against the removed href" do
    root = tmp(unique_scope("base-attributes"))
    on_exit(fn -> File.rm_rf(root) end)
    source = ~s|<base href="/docs/" target="_blank"><a href="next.html">A</a>|

    export = managed_export(root, @page, source, [{@target, "TARGET", "text/plain"}])
    page = Managed.resource_for_url(export, @page)
    target = Managed.reference_target(export, page, @target)
    href = Managed.relative_reference(page, target)

    assert Managed.read_resource(export, page) ==
             <<0xEF, 0xBB, 0xBF>> <> ~s|<base target="_blank"><a href="#{href}">A</a>|

    Managed.assert_opens(export, page, target, href)
    assert Managed.read_resource(export, target) == "TARGET"
  end

  test "standalone public ID acknowledgements preserve base targets and resolved online source" do
    root = tmp(unique_scope("standalone-base-ack-source"))
    on_exit(fn -> File.rm_rf(root) end)
    source = ~s|<base href="/docs/" target="_blank"><a href="next.html">A</a>|
    target_id = "standalone000000000005001"
    page_id = "standalone000000000005002"

    assert {:ok, %{public_id: ^target_id} = target} =
             Snapper.snap("TARGET", %{
               public_id: target_id,
               url: @target,
               save_to: root,
               content_type: "text/plain",
               html_tag: "a"
             })

    assert {:ok, %{public_id: ^page_id} = page} =
             Snapper.snap(source, Map.merge(@opts, %{public_id: page_id, save_to: root}))

    assert File.read!(saved_artifact(root, target)) == "TARGET"

    assert File.read!(saved_artifact(root, page)) ==
             <<0xEF, 0xBB, 0xBF>> <> ~s|<base target="_blank"><a href="#{@target}">A</a>|
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

  defp managed_export(root, page, source, targets) do
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
             Crawler.crawl(page,
               scope: Crawler.TestHelpers.unique_scope("managed-snapshot"),
               save_to: root,
               store: nil,
               workers: 1,
               max_body: 1_048_576,
               max_analysis_bytes: 16_777_216,
               max_depths: 3,
               respect_robots: false,
               req_options: [plug: plug, retry: false]
             )

    on_exit(fn ->
      Crawler.stop(opts)
      File.rm_rf!(root)
    end)

    export = Managed.ready_export(opts)

    assert Crawler.RequestLog.frequencies(requests) ==
             Map.new(routes, fn {url, _} -> {url, 1} end)

    export
  end
end
