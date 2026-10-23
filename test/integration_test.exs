defmodule IntegrationTest do
  use Crawler.TestCase, async: false

  import Plug.Conn
  import Crawler.ManagedSnapshotHelpers

  defmodule AllowHosts do
    @behaviour Crawler.Fetcher.UrlFilter.Spec

    def filter(_url, _opts), do: {:ok, true}
  end

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "integration", %{
    site: site,
    url: url,
    site2: site2,
    url2: url2,
    req_options: req_options
  } do
    linked_url1 = "#{url}/page1.html"
    linked_url2 = "#{url}/dir/page2.html"
    linked_url3 = "#{url2}/page3.html"

    page1_raw = "<html><a href='#{linked_url2}'>2</a> <a href='#{linked_url3}'>3</a></html>"
    page2_raw = "<html><a href='#{linked_url3}'>3</a></html>"
    page3_raw = "<html><a href='dir/page4'>4</a> <a href='/dir/page4'>4</a></html>"

    page4_raw =
      "<html><head><script type='text/javascript' src='/javascript.js'></script><link rel='stylesheet' href='../styles.css' /></head><a href='../page5.html'>5</a> <img src='../image1.png' /></html>"

    page5_raw = "<html><a href='/page6'>6</a> <img src='/image2.png' /></html>"
    css_raw = "img { url(image3.png); }"

    for {site, path, type, bytes, count} <- [
          {site, "/page1.html", "text/html", page1_raw, 1},
          {site, "/dir/page2.html", "text/html", page2_raw, 1},
          {site2, "/page3.html", "text/html", page3_raw, 2},
          {site2, "/dir/page4", "text/html", page4_raw, 4},
          {site2, "/page5.html", "text/html", page5_raw, 2},
          {site2, "/image1.png", "image/png", "png", 4},
          {site2, "/image2.png", "image/png", "png", 2},
          {site2, "/image3.png", "image/png", "png", 4},
          {site2, "/styles.css", "text/css", css_raw, 4},
          {site2, "/javascript.js", "application/javascript", "js", 4}
        ] do
      expect_requests(site, path, type, bytes, count)
    end

    {:ok, opts} =
      start_crawl(linked_url1,
        save_to: Path.join(tmp(unique_scope("integration")), "archive"),
        workers: 1,
        max_body: 1_048_576,
        max_analysis_bytes: 16_777_216,
        max_manifest_bytes: 16_777_216,
        max_depths: 4,
        assets: ["js", "css", "images"],
        url_filter: AllowHosts,
        req_options: req_options
      )

    export = ready_export(opts)

    first = resource_for_url(export, linked_url1)
    [second] = bound_targets(export, first, linked_url2, 1)
    [direct_third] = bound_targets(export, first, linked_url3, 1)
    [indirect_third] = bound_targets(export, second.resource, linked_url3, 2)
    thirds = [direct_third, indirect_third]

    fourths =
      Enum.flat_map(thirds, fn third ->
        targets = bound_targets(export, third.resource, url2 <> "/dir/page4", third.depth + 1)
        assert [_, _] = targets
        targets
      end)

    fifths =
      Enum.flat_map(fourths, fn fourth ->
        if fourth.depth + 1 < opts.max_depths do
          [fifth] =
            bound_targets(export, fourth.resource, url2 <> "/page5.html", fourth.depth + 1)

          [fifth]
        else
          assert fourth.depth + 1 == opts.max_depths
          []
        end
      end)

    for {bindings, url, count} <- [
          {thirds, linked_url3, 2},
          {fourths, url2 <> "/dir/page4", 4},
          {fifths, url2 <> "/page5.html", 2}
        ] do
      actual = bindings |> Enum.map(& &1.resource["id"]) |> Enum.sort()

      emitted =
        export.manifest["resources"]
        |> Enum.filter(&(&1["url"] == url))
        |> Enum.map(& &1["id"])
        |> Enum.sort()

      assert length(actual) == count
      assert Enum.uniq(actual) == actual
      assert actual == emitted
    end

    pages =
      [
        {%{resource: first, depth: 0}, page1_raw, [linked_url2, linked_url3]},
        {second, page2_raw, [linked_url3]}
      ] ++
        Enum.map(thirds, &{&1, page3_raw, [url2 <> "/dir/page4", url2 <> "/dir/page4"]}) ++
        Enum.map(fourths, fn resource ->
          {resource, page4_raw,
           [
             url2 <> "/javascript.js",
             url2 <> "/styles.css",
             url2 <> "/page5.html",
             url2 <> "/image1.png"
           ]}
        end) ++
        Enum.map(fifths, &{&1, page5_raw, [url2 <> "/page6", url2 <> "/image2.png"]})

    for {page, raw, links} <- pages do
      source = page.resource
      body = read_resource(export, source)

      originals =
        List.flatten(Regex.scan(~r/(?:href|src)='([^']+)'/, raw, capture: :all_but_first))

      actual =
        List.flatten(Regex.scan(~r/(?:href|src)='([^']+)'/, body, capture: :all_but_first))

      assert length(actual) == length(links)

      expected =
        Enum.reduce(Enum.zip([originals, actual, links]), raw, fn {old, href, target_url}, text ->
          depth_limited? =
            page.depth + 1 == opts.max_depths and
              {source["url"], target_url} in [
                {url2 <> "/dir/page4", url2 <> "/page5.html"},
                {url2 <> "/page5.html", url2 <> "/page6"}
              ]

          if depth_limited? do
            assert [edge] = reference_edges(export, source, target_url)
            assert edge["outcome"] == "rejected"
            assert edge["target"] == nil
            assert href == target_url
            String.replace(text, "'" <> old <> "'", "'" <> target_url <> "'")
          else
            target = target_for_reference(export, source, target_url, href)
            assert_opens(export, source, target, href)

            String.replace(
              text,
              "'" <> old <> "'",
              "'" <> relative_reference(source, target) <> "'"
            )
          end
        end)

      assert body == @utf8_bom <> expected
    end

    for {path, type, bytes} <- [
          {"/image1.png", "image/png", "png"},
          {"/image2.png", "image/png", "png"},
          {"/image3.png", "image/png", "png"},
          {"/javascript.js", "application/javascript", "js"}
        ] do
      resources = Enum.filter(export.manifest["resources"], &(&1["url"] == url2 <> path))
      assert resources != []

      for resource <- resources do
        assert resource["content_type"] == type
        assert read_resource(export, resource) == bytes
      end
    end

    stylesheets = Enum.filter(export.manifest["resources"], &(&1["url"] == url2 <> "/styles.css"))
    assert stylesheets != []

    for css <- stylesheets do
      image = reference_target(export, css, url2 <> "/image3.png")
      assert css["content_type"] == "text/css"
      assert [_, href] = Regex.run(~r/url\(([^)]+)\)/, read_resource(export, css))
      assert_opens(export, css, image, href)
      assert read_resource(export, css) == "img { url(#{relative_reference(css, image)}); }"
    end
  end

  defp expect_requests(site, path, type, bytes, count) do
    hits = :counters.new(1, [:atomics])
    on_exit(fn -> assert :counters.get(hits, 1) == count end)

    ReqTestSite.expect(site, "GET", path, fn conn ->
      :counters.add(hits, 1, 1)
      assert :counters.get(hits, 1) <= count
      conn |> put_resp_header("content-type", type) |> resp(200, bytes)
    end)
  end

  defp bound_targets(export, source, url, depth) do
    for edge <- reference_edges(export, source, url) do
      %{
        source: source,
        edge: edge,
        resource: edge_target(export, source, edge["edge"]),
        depth: depth
      }
    end
  end

  defp reference_edges(export, source, url) do
    edges =
      export.manifest["references"]
      |> Enum.filter(&(&1["from"] == source["id"] and &1["url"] == url))
      |> Enum.sort_by(& &1["edge"])

    assert edges != []
    edges
  end

  defp target_for_reference(export, source, url, href) do
    edges = reference_edges(export, source, url)
    assert Enum.all?(edges, &(&1["outcome"] == "succeeded"))

    targets =
      edges
      |> Enum.map(&edge_target(export, source, &1["edge"]))
      |> Enum.uniq_by(& &1["id"])
      |> Enum.filter(&(relative_reference(source, &1) == href))

    assert [target] = targets
    target
  end
end
