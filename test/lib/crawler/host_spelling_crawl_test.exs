defmodule Crawler.HostSpellingCrawlTest do
  use Crawler.TestCase, async: false

  alias Crawler.RequestLog
  alias Crawler.Store

  import Crawler.ManagedSnapshotHelpers

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
  end

  test "Unicode roots and links fetch normalized domains and open the saved files" do
    root_url = "http://foo.com/hub"
    ideographic = "http://xn--fsq.com/page"
    encoded = "http://example.com/page"
    distinct = "http://fass.de/page"
    non_transitional = "http://xn--fa-hia.de/page"
    unicode_path = "http://example.com/café?q=é"

    targets = %{
      ideographic => ["http://例。com/page", "http://例．com/page", "http://例.com/page"],
      encoded => ["http://e%78ample.com/page", "http://EXAMPLE.COM/page"],
      distinct => ["http://fass.de/page"],
      non_transitional => ["http://faß.de/page"],
      unicode_path => ["http://example.com/café?q=é", "http://example.com/caf%C3%A9?q=%C3%A9"]
    }

    wire_targets =
      targets
      |> Map.keys()
      |> Map.new(&{&1, &1})
      |> Map.delete(unicode_path)
      |> Map.put("http://example.com/caf%c3%a9?q=%c3%a9", unicode_path)

    root = Path.join(tmp("host-spelling-crawl"), "archive")
    seen = RequestLog.new()
    groups = Enum.group_by(targets, fn {target, _variants} -> Crawler.Site.origin(target) end)
    groups = [{"http://foo.com", []} | Enum.sort(groups)]

    exports =
      groups
      |> Enum.with_index()
      |> Map.new(fn {{origin, entries}, group_index} ->
        hub = origin <> "/hub"
        scope = "host-spelling-crawl-#{group_index}"
        spellings = Enum.flat_map(entries, fn {_target, variants} -> variants end)

        adapter = fn request ->
          url = URI.to_string(request.url)
          RequestLog.record(seen, url)

          if url == hub do
            body = Enum.map_join(spellings, &~s(<a href="#{&1}">PAGE</a>))

            {request,
             Req.Response.new(status: 200, headers: [{"content-type", "text/html"}], body: body)}
          else
            target = Map.fetch!(wire_targets, url)
            assert Crawler.Site.same_site?(hub, target)
            {request, Req.Response.new(status: 200, body: "PAGE #{target}")}
          end
        end

        seed = if hub == root_url, do: "http://ＦＯＯ．ＣＯＭ/hub", else: hub

        {:ok, opts} =
          start_crawl(seed,
            store: Store,
            scope: scope,
            workers: 2,
            max_body: 1_048_576,
            max_analysis_bytes: 16_000_000,
            max_css_work: 5_000,
            max_css_pictures: 1_000,
            save_to: root <> "-#{group_index}",
            respect_robots: false,
            req_options: plug_options(adapter)
          )

        export = ready_export(opts)
        assert Store.find_processed({seed, scope})
        source = resource_for_url(export, hub)
        hrefs = Floki.attribute(Floki.parse_document!(read_resource(export, source)), "a", "href")
        assert length(hrefs) == length(spellings)

        targets_by_identity =
          for {{href, spelling}, index} <- Enum.with_index(Enum.zip(hrefs, spellings)) do
            target = edge_target(export, source, index)
            assert target["url"] == Crawler.URL.normalize(spelling)
            assert_opens(export, source, target, href)
            assert read_resource(export, target) == "PAGE #{target["url"]}"
            {target["url"], target["id"]}
          end

        for {_url, ids} <- Enum.group_by(targets_by_identity, &elem(&1, 0), &elem(&1, 1)) do
          assert length(Enum.uniq(ids)) == 1
        end

        for {target, variants} <- entries, spelling <- variants do
          assert Store.find_processed({spelling, scope}).body == "PAGE #{target}"
        end

        {origin, export}
      end)

    hubs = Enum.map(groups, fn {origin, _entries} -> origin <> "/hub" end)
    assert RequestLog.frequencies(seen) == Map.new(hubs ++ Map.keys(wire_targets), &{&1, 1})
    distinct_export = Map.fetch!(exports, Crawler.Site.origin(distinct))
    non_transitional_export = Map.fetch!(exports, Crawler.Site.origin(non_transitional))

    assert read_resource(distinct_export, resource_for_url(distinct_export, distinct)) !=
             read_resource(
               non_transitional_export,
               resource_for_url(non_transitional_export, non_transitional)
             )
  end

  test "malformed discovered authorities are not fetched or rewritten as valid targets" do
    page = "http://example.com/hub"

    invalid = [
      "http://example.com:bad/target",
      "//example.com:65536/target",
      "http://[bad]/target",
      "http:///target"
    ]

    seen = RequestLog.new()
    root = Path.join(tmp("invalid-authority-crawl"), "archive")
    scope = "invalid-authority-crawl"

    adapter = fn request ->
      url = URI.to_string(request.url)
      RequestLog.record(seen, url)
      assert url == page
      body = Enum.map_join(invalid, &~s(<a href="#{&1}">INVALID</a>))

      {request,
       Req.Response.new(status: 200, headers: [{"content-type", "text/html"}], body: body)}
    end

    {:ok, opts} =
      start_crawl(page,
        store: Store,
        scope: scope,
        workers: 1,
        max_body: 1_048_576,
        max_analysis_bytes: 16_000_000,
        max_css_work: 5_000,
        max_css_pictures: 1_000,
        save_to: root,
        respect_robots: false,
        req_options: plug_options(adapter)
      )

    export = ready_export(opts)

    assert RequestLog.frequencies(seen) == %{page => 1}
    assert Store.ops_count(scope) == 1
    html = read_resource(export, resource_for_url(export, page))
    for link <- invalid, do: assert(html =~ link)
    assert Floki.attribute(Floki.parse_document!(html), "a", "href") == invalid
  end

  defp plug_options(adapter) do
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      request =
        Req.new(
          url: %URI{
            scheme: Atom.to_string(conn.scheme),
            host: conn.host,
            port: conn.port,
            path: conn.request_path,
            query: if(conn.query_string == "", do: nil, else: conn.query_string)
          },
          headers: conn.req_headers
        )

      {_request, response} = adapter.(request)
      conn = %{conn | resp_headers: Req.get_headers_list(response)}
      Plug.Conn.send_resp(conn, response.status, response.body || "")
    end)

    [plug: {Req.Test, name}, retry: false]
  end
end
