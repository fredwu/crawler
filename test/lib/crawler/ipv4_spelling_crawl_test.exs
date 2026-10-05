defmodule Crawler.IPv4SpellingCrawlTest do
  use Crawler.TestCase, async: false

  alias Crawler.RequestLog
  alias Crawler.Store
  alias Crawler.URL

  import Crawler.SnapshotHelpers

  test "IPv4 roots and links fetch each address once and open the saved files" do
    root_url = "http://127.0.0.1/hub"

    targets = %{
      "http://127.0.0.1/page" => [
        "http://127.1/page",
        "http://2130706433/page",
        "http://0x7f000001/page",
        "http://0177.0.0.1/page",
        "http://１２７。０。０。１/page",
        "http://127.0.0.1./page"
      ],
      "http://127.0.0.2/page" => ["http://127.2/page", "http://0x7f000002/page"]
    }

    invalid = ["http://127.0.0.256/page", "http://09/page", "http://example.42/page"]
    root = tmp("ipv4-spelling-crawl")
    scope = "ipv4-spelling-crawl"
    seen = RequestLog.new()

    adapter = fn request ->
      url = URI.to_string(request.url)
      RequestLog.record(seen, url)

      if url == root_url do
        links = (targets |> Map.values() |> List.flatten()) ++ invalid
        body = Enum.map_join(links, &~s(<a href="#{&1}">PAGE</a>))

        {request,
         Req.Response.new(status: 200, headers: [{"content-type", "text/html"}], body: body)}
      else
        assert Map.has_key?(targets, url)
        {request, Req.Response.new(status: 200, body: "PAGE #{url}")}
      end
    end

    {:ok, opts} =
      start_crawl("http://0x7f000001/hub",
        store: Store,
        scope: scope,
        workers: 2,
        save_to: root,
        req_options: [adapter: adapter, retry: false]
      )

    await_idle(opts)

    assert RequestLog.frequencies(seen) == Map.new([root_url | Map.keys(targets)], &{&1, 1})
    assert Store.find_processed({"http://0x7f000001/hub", scope})

    for {target, spellings} <- targets, spelling <- spellings do
      assert Store.find_processed({spelling, scope}).body == "PAGE #{target}"
      assert URL.normalize(spelling) == target
      assert_link_opens(root, root_url, spelling)
    end

    html = File.read!(saved(root, root_url))
    for link <- invalid, do: assert(html =~ link)

    refute File.read!(saved(root, "http://127.0.0.1/page")) ==
             File.read!(saved(root, "http://127.0.0.2/page"))
  end
end
