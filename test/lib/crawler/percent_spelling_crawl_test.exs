defmodule Crawler.PercentSpellingCrawlTest do
  use Crawler.TestCase, async: false

  alias Crawler.RequestLog
  alias Crawler.Store

  test "equivalent ASCII spellings use one request and one page budget slot" do
    hub = "http://example.com/hub"
    last = "http://example.com/last"

    targets = %{
      "http://example.com/a%7cb" => ["/a|b", "/a%7Cb"],
      "http://example.com/a%25ZZ" => ["/a%ZZ", "/a%25ZZ"],
      "http://example.com/search?q=%7b%7d%60%7c" => [
        "/search?q={}`|",
        "/search?q=%7B%7D%60%7C"
      ]
    }

    seen = RequestLog.new()
    scope = unique_scope("percent-spelling-budget")
    links = (targets |> Map.values() |> List.flatten()) ++ [last]
    body = Enum.map_join(links, &~s(<a href="#{&1}">PAGE</a>))

    adapter = fn request ->
      url = URI.to_string(request.url)
      RequestLog.record(seen, url)

      if url == hub do
        {request,
         Req.Response.new(status: 200, headers: [{"content-type", "text/html"}], body: body)}
      else
        assert Map.has_key?(targets, url) or url == last
        {request, Req.Response.new(status: 200, body: "PAGE #{url}")}
      end
    end

    {:ok, opts} =
      start_crawl(hub,
        store: Store,
        scope: scope,
        workers: 1,
        max_depths: 2,
        max_pages: map_size(targets) + 2,
        respect_robots: false,
        req_options: [adapter: adapter, retry: false]
      )

    await_idle(opts)

    assert RequestLog.frequencies(seen) == Map.new([hub, last | Map.keys(targets)], &{&1, 1})
    assert Store.ops_count(scope) == map_size(targets) + 2
    assert Store.find_processed({last, scope})

    for {target, spellings} <- targets, spelling <- spellings do
      assert Store.find_processed({"http://example.com" <> spelling, scope}).body ==
               "PAGE #{target}"
    end
  end
end
