defmodule Crawler.HostSpellingCrawlTest do
  use Crawler.TestCase, async: false

  alias Crawler.RequestLog
  alias Crawler.Store

  import Crawler.SnapshotHelpers

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

    spellings = targets |> Map.values() |> List.flatten()
    root = tmp("host-spelling-crawl")
    scope = "host-spelling-crawl"
    seen = RequestLog.new()

    adapter = fn request ->
      url = URI.to_string(request.url)
      RequestLog.record(seen, url)

      if url == root_url do
        body = Enum.map_join(spellings, &~s(<a href="#{&1}">PAGE</a>))

        {request,
         Req.Response.new(status: 200, headers: [{"content-type", "text/html"}], body: body)}
      else
        target = Map.fetch!(wire_targets, url)
        {request, Req.Response.new(status: 200, body: "PAGE #{target}")}
      end
    end

    {:ok, opts} =
      start_crawl("http://ＦＯＯ．ＣＯＭ/hub",
        store: Store,
        scope: scope,
        workers: 2,
        save_to: root,
        respect_robots: false,
        url_filter: Crawler.AllowFilter,
        req_options: [adapter: adapter, retry: false]
      )

    await_idle(opts)

    assert RequestLog.frequencies(seen) == Map.new([root_url | Map.keys(wire_targets)], &{&1, 1})
    assert Store.find_processed({"http://ＦＯＯ．ＣＯＭ/hub", scope})

    for {target, variants} <- targets, spelling <- variants do
      assert Store.find_processed({spelling, scope}).body == "PAGE #{target}"
      assert_link_opens(root, root_url, spelling)
    end

    assert File.read!(saved(root, distinct)) != File.read!(saved(root, non_transitional))
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
    root = tmp("invalid-authority-crawl")
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
        save_to: root,
        respect_robots: false,
        req_options: [adapter: adapter, retry: false]
      )

    await_idle(opts)

    assert RequestLog.frequencies(seen) == %{page => 1}
    assert Store.ops_count(scope) == 1
    html = File.read!(saved(root, page))
    for link <- invalid, do: assert(html =~ link)
    refute html =~ "target/__index.html"
  end
end
