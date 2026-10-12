defmodule Crawler.PercentSpellingCrawlTest do
  use Crawler.TestCase, async: false

  alias Crawler.RequestLog
  alias Crawler.Store

  test "browser spellings use a separate request and page for each address" do
    hub = "http://example.com/hub"

    links = [
      "/a|b",
      "/a%7Cb",
      "/a%ZZ",
      "/a%25ZZ",
      ~s(/search?q=`{}|\\^),
      "/search?q=%60%7B%7D%7C%5C%5E",
      "/foo%2ehtml",
      "/foo.html",
      "/a?q=%2e%2e",
      "/a?q=..",
      "/a/%2e%2e/next",
      "http://example.com./dotted",
      "http://example.com%2e/also",
      "http://user@example.com@evil.com/secret",
      "http://user:a#b@example.com/a",
      "http://user:a/b@example.com/a",
      "/ok"
    ]

    expected = [
      hub,
      "http://example.com/a|b",
      "http://example.com/a%7cb",
      "http://example.com/a%ZZ",
      "http://example.com/a%25ZZ",
      "http://example.com/search?q=`{}|\\^",
      "http://example.com/search?q=%60%7b%7d%7c%5c%5e",
      "http://example.com/foo%2ehtml",
      "http://example.com/foo.html",
      "http://example.com/a?q=%2e%2e",
      "http://example.com/a?q=..",
      "http://example.com/next",
      "http://example.com/ok"
    ]

    seen = RequestLog.new()
    scope = unique_scope("percent-spelling-budget")
    body = Enum.map_join(links, &~s|<a href="#{&1}">PAGE</a>|)

    adapter = fn request ->
      url = URI.to_string(request.url)
      RequestLog.record(seen, url)

      if url == hub do
        {request,
         Req.Response.new(status: 200, headers: [{"content-type", "text/html"}], body: body)}
      else
        {request, Req.Response.new(status: 200, body: "PAGE #{url}")}
      end
    end

    {:ok, opts} =
      start_crawl(hub,
        store: Store,
        scope: scope,
        workers: 1,
        max_depths: 2,
        max_pages: length(expected),
        respect_robots: false,
        req_options: [adapter: adapter, retry: false]
      )

    await_idle(opts)

    assert RequestLog.frequencies(seen) == Map.new(expected, &{&1, 1})
    assert Store.ops_count(scope) == length(expected)

    for url <- expected, url != hub do
      assert Store.find_processed({url, scope}).body == "PAGE #{url}"
    end

    refute Store.find_processed({"http://user:a", scope})
    refute Store.find_processed({"http://user:a#b@example.com/a", scope})

    refute Store.find_processed({"http://example.com/foo.html", scope}).body ==
             "PAGE http://example.com/foo%2ehtml"
  end

  test "a seed keeps a trailing dot or encoded userinfo on the request" do
    for {seed, expected} <- [
          {"http://example.com./a", "http://example.com./a"},
          {"http://example.com%2e/a", "http://example.com./a"},
          {"http://user@example.com@evil.com/secret",
           "http://user%40example.com@evil.com/secret"},
          {"http://us er:pa ss@example.com/a", "http://us%20er:pa%20ss@example.com/a"}
        ] do
      assert crawl_requests(seed) == [expected]
    end
  end

  test "a rejected authority seed makes no request" do
    for seed <- [
          "http://user:a#b@example.com/a",
          "http://user:a/b@example.com/a"
        ] do
      assert crawl_requests(seed) == []
    end
  end

  defp crawl_requests(seed) do
    seen = RequestLog.new()
    scope = unique_scope("browser-address")

    adapter = fn request ->
      RequestLog.record(seen, URI.to_string(request.url))
      {request, Req.Response.new(status: 200, body: "OK")}
    end

    {:ok, opts} =
      start_crawl(seed,
        store: Store,
        scope: scope,
        workers: 1,
        max_depths: 1,
        max_pages: 1,
        respect_robots: false,
        req_options: [adapter: adapter, retry: false]
      )

    await_idle(opts)
    seen |> RequestLog.frequencies() |> Map.keys()
  end
end
