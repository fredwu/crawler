defmodule Crawler.IPv4SpellingCrawlTest do
  use Crawler.TestCase, async: false

  alias Crawler.RequestLog
  alias Crawler.Store
  alias Crawler.URL

  import Crawler.ManagedSnapshotHelpers

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
  end

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
    root = Path.join(tmp("ipv4-spelling-crawl"), "archive")
    scope = "ipv4-spelling-crawl"
    seen = RequestLog.new()

    pages =
      targets
      |> Enum.sort()
      |> Enum.with_index()
      |> Map.new(fn {{page, spellings}, group_index} ->
        hub = Crawler.Site.origin(page) <> "/hub"
        group_scope = scope <> "-#{group_index}"

        adapter = fn request ->
          url = URI.to_string(request.url)
          RequestLog.record(seen, url)

          if url == hub do
            body = Enum.map_join(spellings ++ invalid, &~s(<a href="#{&1}">PAGE</a>))

            {request,
             Req.Response.new(status: 200, headers: [{"content-type", "text/html"}], body: body)}
          else
            assert url == page
            {request, Req.Response.new(status: 200, body: "PAGE #{url}")}
          end
        end

        seed = if hub == root_url, do: "http://0x7f000001/hub", else: "http://127.2/hub"

        {:ok, opts} =
          start_crawl(seed,
            store: Store,
            scope: group_scope,
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
        assert Store.find_processed({seed, group_scope})
        source = resource_for_url(export, hub)
        html = read_resource(export, source)
        hrefs = Floki.attribute(Floki.parse_document!(html), "a", "href")
        assert length(hrefs) == length(spellings) + length(invalid)

        target_ids =
          for {{href, spelling}, index} <- Enum.with_index(Enum.zip(hrefs, spellings)) do
            target = edge_target(export, source, index)
            assert target["url"] == URL.normalize(spelling)
            assert_opens(export, source, target, href)
            assert read_resource(export, target) == "PAGE #{target["url"]}"
            target["id"]
          end

        assert length(Enum.uniq(target_ids)) == 1

        for spelling <- spellings do
          assert Store.find_processed({spelling, group_scope}).body == "PAGE #{page}"
          assert URL.normalize(spelling) == page
        end

        for link <- invalid, do: assert(html =~ link)
        assert Enum.take(hrefs, -length(invalid)) == invalid
        {page, read_resource(export, resource_for_url(export, page))}
      end)

    hubs = targets |> Map.keys() |> Enum.map(&(Crawler.Site.origin(&1) <> "/hub"))
    assert RequestLog.frequencies(seen) == Map.new(hubs ++ Map.keys(targets), &{&1, 1})
    refute pages["http://127.0.0.1/page"] == pages["http://127.0.0.2/page"]
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
