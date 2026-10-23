defmodule Crawler.CrawlSVGHrefSelectionTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  test "SVG href authority prevents fallback requests and preserves saved source", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("svg-href-selection")
    root = Path.join(tmp(), scope <> "-#{Base.encode16(:crypto.strong_rand_bytes(6))}")
    on_exit(fn -> File.rm_rf(root) end)
    page = url <> "/index.html"

    source =
      "<svg>" <>
        ~s|<a xlink:href="ignored.svg" href="shared.svg"/>| <>
        ~s|<image href="shared.svg" xlink:href="ignored.svg"/>| <>
        ~s|<use xlink:href="shared.svg"/>| <>
        ~s|<a href="" xlink:href="ignored.svg"/>| <>
        ~s|<image href="" href="ignored.svg" xlink:href="ignored.svg"/>| <>
        ~s|<use href="" xlink:href="ignored.svg"/>| <>
        "</svg>"

    ReqTestSite.expect_once(site, "GET", "/index.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, source)
    end)

    requests = :counters.new(1, [:atomics])

    ReqTestSite.expect(site, "GET", "/shared.svg", fn conn ->
      :counters.add(requests, 1, 1)

      conn
      |> Plug.Conn.put_resp_header("content-type", "image/svg+xml")
      |> Plug.Conn.resp(200, "<svg/>")
    end)

    {:ok, opts} =
      start_crawl(page,
        scope: scope,
        workers: 2,
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        retries: 0,
        max_depths: 2,
        assets: ["images"],
        store: Store,
        save_to: root,
        req_options: req_options
      )

    export = ready_export(opts)
    assert :counters.get(requests, 1) == 2
    source_resource = resource_for_url(export, page)
    shared = url <> "/shared.svg"

    edges =
      export.manifest["references"]
      |> Enum.filter(&(&1["from"] == source_resource["id"] and &1["url"] == shared))
      |> Enum.sort_by(& &1["edge"])

    assert [document_edge, image_edge, use_edge] = edges
    document = edge_target(export, source_resource, document_edge["edge"])
    image = edge_target(export, source_resource, image_edge["edge"])
    use = edge_target(export, source_resource, use_edge["edge"])
    document_href = relative_reference(source_resource, document)
    image_href = relative_reference(source_resource, image)
    use_href = relative_reference(source_resource, use)

    expected =
      "<svg>" <>
        ~s|<a xlink:href="ignored.svg" href="#{document_href}"/>| <>
        ~s|<image href="#{image_href}" xlink:href="ignored.svg"/>| <>
        ~s|<use xlink:href="#{use_href}"/>| <>
        ~s|<a href="" xlink:href="ignored.svg"/>| <>
        ~s|<image href="" href="ignored.svg" xlink:href="ignored.svg"/>| <>
        ~s|<use href="" xlink:href="ignored.svg"/>| <>
        "</svg>"

    assert read_resource(export, source_resource) == <<0xEF, 0xBB, 0xBF>> <> expected
    refute Store.find({url <> "/ignored.svg", scope})
    assert Store.find_processed({shared, scope})

    for {target, href} <- [{document, document_href}, {image, image_href}, {use, use_href}] do
      assert_opens(export, source_resource, target, href)
      assert read_resource(export, target) == "<svg/>"
    end
  end
end
