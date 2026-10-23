defmodule Crawler.SitemapAsyncTest do
  use Crawler.TestCase, async: false

  import Plug.Conn

  alias Crawler.Store

  defmodule HeldControlModifier do
    @behaviour Crawler.Fetcher.Modifier.Spec

    def opts(opts) do
      if opts[:sitemap_fetch] do
        send(opts.test_owner, {:control_preparation, self(), opts.url})

        receive do
          :release_control -> :ok
        end
      end

      []
    end

    def headers(_opts), do: []
  end

  test "one worker fetches the seed before a held control modifier", context do
    owner = self()
    robots(context, "/root.xml")

    ReqTestSite.expect_once(context.site, "GET", "/start", fn conn ->
      send(owner, :seed_requested)
      html(conn, "seed")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/root.xml", fn conn ->
      resp(conn, 200, "<urlset/>")
    end)

    {:ok, opts} =
      start_crawl(
        context.url <> "/start",
        options(context,
          modifier: HeldControlModifier,
          test_owner: owner
        )
      )

    assert_receive :seed_requested, 2_000
    assert_receive {:control_preparation, executor, url}, 2_000
    assert url == context.url <> "/root.xml"
    send(executor, :release_control)
    await_idle(opts)
    assert Store.find_processed({context.url <> "/start", opts.scope})
    refute_received {:control_preparation, _, _}
  end

  test "a page-free chain stops at the control document budget", context do
    owner = self()
    robots(context, "/map-0.xml")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "seed"))

    for index <- 0..5 do
      ReqTestSite.stub(context.site, "GET", "/map-#{index}.xml", fn conn ->
        send(owner, {:control_requested, index})

        resp(conn, 200, """
        <sitemapindex><sitemap><loc>/map-#{index + 1}.xml</loc></sitemap></sitemapindex>
        """)
      end)
    end

    {:ok, opts} =
      start_crawl(context.url <> "/start", options(context, max_control_documents: 4))

    await_idle(opts)
    assert Store.find_processed({context.url <> "/start", opts.scope})
    assert_received {:control_requested, 0}
    assert_received {:control_requested, 1}
    assert_received {:control_requested, 2}
    refute_received {:control_requested, 3}
    assert :sys.get_state(Store).scopes[opts.scope].control_documents == 4
    assert Store.ops_count(opts.scope) == 1
  end

  test "control depth is independent from page depth", context do
    owner = self()
    robots(context, "/root.xml")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "seed"))

    ReqTestSite.expect_once(context.site, "GET", "/root.xml", fn conn ->
      resp(conn, 200, "<sitemapindex><sitemap><loc>/child.xml</loc></sitemap></sitemapindex>")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/child.xml", fn conn ->
      resp(conn, 200, """
      <urlset><url><loc>/page</loc></url><sitemap><loc>/too-deep.xml</loc></sitemap></urlset>
      """)
    end)

    ReqTestSite.stub(context.site, "GET", "/too-deep.xml", fn conn ->
      send(owner, :too_deep_requested)
      resp(conn, 200, "<urlset/>")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/page", &html(&1, "page"))

    {:ok, opts} =
      start_crawl(
        context.url <> "/start",
        options(context, max_control_depth: 1, max_depths: 2)
      )

    await_idle(opts)
    assert Store.find_processed({context.url <> "/page", opts.scope})
    refute_received :too_deep_requested
  end

  test "stop cancels a held control before it can admit children", context do
    owner = self()
    robots(context, "/root.xml")
    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "seed"))

    ReqTestSite.expect_once(context.site, "GET", "/root.xml", fn conn ->
      send(owner, {:control_response_held, self()})

      receive do
        :release_response -> :ok
      end

      resp(conn, 200, "<urlset><url><loc>/retired</loc></url></urlset>")
    end)

    ReqTestSite.stub(context.site, "GET", "/retired", fn conn ->
      send(owner, :retired_page_requested)
      html(conn, "retired")
    end)

    {:ok, opts} = start_crawl(context.url <> "/start", options(context, []))
    assert_receive {:control_response_held, executor}, 2_000
    monitor = Process.monitor(executor)
    assert Crawler.stop(opts) == :ok
    send(executor, :release_response)
    assert_receive {:DOWN, ^monitor, :process, ^executor, _reason}, 2_000
    refute Crawler.running?(opts)
    refute Store.find({context.url <> "/retired", opts.scope})
    refute_received :retired_page_requested
  end

  defp options(context, extra) do
    Keyword.merge(
      [
        scope: unique_scope("sitemap-async"),
        store: Store,
        workers: 1,
        retries: 0,
        req_options: context.req_options
      ],
      extra
    )
  end

  defp robots(context, sitemap) do
    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, "User-agent: *\nSitemap: #{context.url}#{sitemap}\n")
    end)
  end

  defp html(conn, body) do
    conn |> put_resp_header("content-type", "text/html") |> resp(200, body)
  end
end
