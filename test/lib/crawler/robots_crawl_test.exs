defmodule Crawler.RobotsCrawlTest do
  use Crawler.TestCase, async: false

  import Plug.Conn

  alias Crawler.Robots
  alias Crawler.Store

  test "query rules and end anchors follow the real URL", context do
    page = "#{context.url}/home"
    php = "#{context.url}/file.php"
    php_query = "#{context.url}/file.php?x=1"
    search = "#{context.url}/search"
    search_query = "#{context.url}/search?q=1"
    search_empty = "#{context.url}/search?"

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, """
      User-agent: *
      Disallow: /*.php$
      Disallow: /search?
      """)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/home", fn conn ->
      html(
        conn,
        ~s|<a href="/file.php">p</a><a href="/file.php?x=1">q</a><a href="/search">s</a><a href="/search?q=1">1</a><a href="/search?">e</a>|
      )
    end)

    ReqTestSite.expect_once(context.site, "GET", "/file.php", &html(&1, "php"))
    ReqTestSite.expect_once(context.site, "GET", "/search", &html(&1, "search"))

    opts = crawl(page, context)

    assert Store.find_processed({page, opts.scope})
    assert Store.find_processed({php_query, opts.scope}).body == "php"
    assert Store.find_processed({search, opts.scope}).body == "search"
    refute Store.find({php, opts.scope})
    refute Store.find({search_query, opts.scope})
    refute Store.find({search_empty, opts.scope})
    refute Store.find({"#{context.url}/robots.txt", opts.scope})
  end

  test "the last queue releases robots receipts and preserves completed pages", context do
    url = context.url <> "/robots-retained-page"
    body = "completed page remains readable"

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, "User-agent: *\nAllow: /\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/robots-retained-page", &html(&1, body))

    opts =
      crawl(url, context,
        respect_robots: true,
        store: Store,
        max_body: 1_024,
        max_analysis_bytes: 2_097_152
      )

    on_exit(fn -> Store.dispose_scope(opts.scope) end)
    key = {url, opts.scope}
    run = {opts.scope, opts.generation}
    origin = Crawler.Site.origin(url)
    store = Process.whereis(Store)
    assert %{body: ^body, opts: page_opts} = completed = Store.find_processed(key)

    receipts =
      [page_opts[:page_resource], page_opts[:body_resource]]
      |> Enum.filter(&is_reference/1)
      |> Enum.uniq()

    assert [_ | _] = receipts
    state = :sys.get_state(Store)
    robots_receipt = state.robots_receipts |> Map.fetch!(run) |> Map.fetch!(origin)
    assert is_reference(robots_receipt)
    assert state.resources.receipts[robots_receipt].run === run
    assert Map.has_key?(state.resources.receipts[robots_receipt].holders, store)
    assert Map.has_key?(state.retained_pages[opts.scope].members, robots_receipt)

    assert :gb_sets.is_member(
             {:grant, robots_receipt},
             state.resources.holders[store].entries
           )

    assert [_] = :ets.lookup(Crawler.Store.Resources, {:grant, robots_receipt, store})
    refute MapSet.member?(state.persistent_resources, robots_receipt)
    refute robots_receipt in receipts
    counts = Map.take(state.persistent_counts, receipts)
    assert map_size(counts) == length(receipts)

    for receipt <- receipts do
      assert Map.fetch!(counts, receipt) > 0
      assert MapSet.member?(state.persistent_resources, receipt)
      assert Map.has_key?(state.resources.receipts[receipt].holders, store)
    end

    assert :ok = Crawler.Queue.stop(opts.queue_owner)
    refute Process.alive?(opts.queue)
    assert Store.queue_scopes(opts.queue) == []

    for release <- [:initial, :repeated] do
      if release == :repeated, do: assert(:ok = Store.release_queue(opts.queue))

      wait(fn ->
        state = :sys.get_state(Store)
        refute Map.has_key?(state.robots_receipts, run)
        refute Map.has_key?(state.robots, opts.scope)
        refute Map.has_key?(state.resources.receipts, robots_receipt)
        refute Map.has_key?(state.retained_pages[opts.scope].members, robots_receipt)

        refute :gb_sets.is_member(
                 {:grant, robots_receipt},
                 state.resources.holders[store].entries
               )

        assert :ets.lookup(Crawler.Store.Resources, {:grant, robots_receipt, store}) == []
        assert Store.find_processed(key) === completed
        assert Store.find_processed(key).body === body
        assert Map.take(state.persistent_counts, receipts) === counts

        for receipt <- receipts do
          assert MapSet.member?(state.persistent_resources, receipt)
          assert Map.has_key?(state.retained_pages[opts.scope].members, receipt)
          assert Map.has_key?(state.resources.receipts[receipt].holders, store)
        end
      end)
    end
  end

  test "a run deadline releases robots custody without removing completed pages", context do
    url = context.url <> "/robots-deadline-page"
    body = "completed page survives its run deadline"

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, "User-agent: *\nAllow: /\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/robots-deadline-page", &html(&1, body))

    opts =
      crawl(url, context,
        respect_robots: true,
        store: Store,
        max_body: 1_024,
        max_analysis_bytes: 2_097_152,
        run_timeout: 2_000
      )

    on_exit(fn -> Store.dispose_scope(opts.scope) end)
    key = {url, opts.scope}
    run = {opts.scope, opts.generation}
    origin = Crawler.Site.origin(url)
    store = Process.whereis(Store)
    assert %{body: ^body, opts: page_opts} = completed = Store.find_processed(key)

    receipts =
      [page_opts[:page_resource], page_opts[:body_resource]]
      |> Enum.filter(&is_reference/1)
      |> Enum.uniq()

    assert [_ | _] = receipts
    state = :sys.get_state(Store)
    assert state.scopes[opts.scope].outcome == :open
    assert is_reference(state.scopes[opts.scope].run_timer)
    assert Store.current?(opts.scope, opts.generation, opts.queue)
    assert Process.alive?(opts.queue)
    assert Process.alive?(opts.queue_owner)
    assert {:ready, rules} = get_in(state.robots, [opts.scope, origin])
    assert Robots.allowed?(rules, url, opts.user_agent)
    robots_receipt = state.robots_receipts |> Map.fetch!(run) |> Map.fetch!(origin)
    assert state.resources.receipts[robots_receipt].run === run
    assert Map.has_key?(state.resources.receipts[robots_receipt].holders, store)
    assert Map.has_key?(state.retained_pages[opts.scope].members, robots_receipt)

    assert :gb_sets.is_member(
             {:grant, robots_receipt},
             state.resources.holders[store].entries
           )

    assert [_] = :ets.lookup(Crawler.Store.Resources, {:grant, robots_receipt, store})
    refute MapSet.member?(state.persistent_resources, robots_receipt)
    refute robots_receipt in receipts
    counts = Map.take(state.persistent_counts, receipts)
    assert map_size(counts) == length(receipts)

    for receipt <- receipts do
      assert Map.fetch!(counts, receipt) > 0
      assert MapSet.member?(state.persistent_resources, receipt)
      assert Map.has_key?(state.resources.receipts[receipt].holders, store)
    end

    wait(fn ->
      state = :sys.get_state(Store)
      assert state.scopes[opts.scope].outcome == {:limited, {:deadline, :run}}
      assert Store.generation(opts.scope) === opts.generation
      refute Store.current?(opts.scope, opts.generation, opts.queue)
      assert Process.alive?(opts.queue)
      assert Process.alive?(opts.queue_owner)
      assert Store.queue_scopes(opts.queue) == [opts.scope]
      refute Map.has_key?(Map.get(state.robots, opts.scope, %{}), origin)
      refute Map.has_key?(state.robots_receipts, run)
      refute Map.has_key?(state.resources.receipts, robots_receipt)
      refute Map.has_key?(state.retained_pages[opts.scope].members, robots_receipt)

      refute :gb_sets.is_member(
               {:grant, robots_receipt},
               state.resources.holders[store].entries
             )

      assert :ets.lookup(Crawler.Store.Resources, {:grant, robots_receipt, store}) == []
      assert Store.find_processed(key) === completed
      assert Store.find_processed(key).body === body
      assert Map.take(state.persistent_counts, receipts) === counts

      for receipt <- receipts do
        assert MapSet.member?(state.persistent_resources, receipt)
        assert Map.has_key?(state.retained_pages[opts.scope].members, receipt)
        assert Map.has_key?(state.resources.receipts[receipt].holders, store)
        assert [_] = :ets.lookup(Crawler.Store.Resources, {:grant, receipt, store})
      end
    end)
  end

  test "a query wildcard blocks only URLs that have a query", context do
    page = "#{context.url}/docs"
    queried = "#{context.url}/docs?x=1"

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, "User-agent: *\nDisallow: /*?\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/docs", fn conn ->
      html(conn, ~s|<a href="/docs?x=1">q</a><a href="/plain">p</a>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/plain", &html(&1, "plain"))

    opts = crawl(page, context)

    assert Store.find_processed({page, opts.scope})
    assert Store.find_processed({"#{context.url}/plain", opts.scope})
    refute Store.find({queried, opts.scope})
  end

  test "encoded robots paths block every spelling of that path", context do
    page = "#{context.url}/home"

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, """
      User-agent: *
      Disallow: /foo/%62%61%7A
      Disallow: /bar/%E3%83%84
      Disallow: /a%2Fb
      Disallow: /star/%2A
      Disallow: /price/%24
      """)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/home", fn conn ->
      html(
        conn,
        ~s|<a href="/foo/baz">b</a><a href="/bar/ツ">t</a><a href="/a/b">a</a><a href="/a%2fb">s</a><a href="/star/other">o</a><a href="/star/*">*</a><a href="/price/end">e</a><a href="/price/$">$</a><a href="/price/%24">d</a>|
      )
    end)

    ReqTestSite.expect_once(context.site, "GET", "/a/b", &html(&1, "ab"))
    ReqTestSite.expect_once(context.site, "GET", "/star/other", &html(&1, "other"))
    ReqTestSite.expect_once(context.site, "GET", "/price/end", &html(&1, "end"))

    opts = crawl(page, context)

    assert Store.find_processed({"#{context.url}/a/b", opts.scope}).body == "ab"
    assert Store.find_processed({"#{context.url}/star/other", opts.scope})
    assert Store.find_processed({"#{context.url}/price/end", opts.scope})
    refute Store.find({"#{context.url}/foo/baz", opts.scope})
    refute Store.find({"#{context.url}/bar/ツ", opts.scope})
    refute Store.find({"#{context.url}/a%2fb", opts.scope})
    refute Store.find({"#{context.url}/star/*", opts.scope})
    refute Store.find({"#{context.url}/price/$", opts.scope})
    refute Store.find({"#{context.url}/price/%24", opts.scope})
  end

  test "a robots redirect on another host applies to the original site", context do
    page = "#{context.url}/docs"
    public = "#{context.url}/public"
    private = "#{context.url}/private"

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      conn
      |> put_resp_header("location", "#{context.url2}/rules.txt")
      |> resp(302, "")
    end)

    ReqTestSite.expect_once(context.site2, "GET", "/rules.txt", fn conn ->
      resp(conn, 200, "User-agent: *\nDisallow: /private\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/docs", fn conn ->
      html(conn, ~s|<a href="/private">p</a><a href="/public">u</a>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/public", &html(&1, "public"))

    opts = crawl(page, context)

    assert Store.find_processed({page, opts.scope})
    assert Store.find_processed({public, opts.scope}).body == "public"
    refute Store.find({private, opts.scope})
    refute Store.find({"#{context.url}/robots.txt", opts.scope})
    refute Store.find({"#{context.url2}/rules.txt", opts.scope})
    assert Store.ops_count(opts.scope) == 2
  end

  test "a script asks for robots first and the redirect still limits the original site",
       context do
    scope = unique_scope("script-robots")
    script = "#{context.url}/app.js"
    page = "#{context.url}/docs"
    private = "#{context.url}/private"

    ReqTestSite.expect_once(context.site2, "GET", "/holder", fn conn ->
      html(conn, ~s|<script src="#{script}"></script>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      conn
      |> put_resp_header("location", "#{context.url2}/script-rules.txt")
      |> resp(302, "")
    end)

    ReqTestSite.expect_once(context.site2, "GET", "/script-rules.txt", fn conn ->
      resp(conn, 200, "User-agent: *\nDisallow: /private\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/app.js", fn conn ->
      conn |> put_resp_header("content-type", "text/javascript") |> resp(200, "js")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/docs", fn conn ->
      html(conn, ~s|<a href="/private">p</a>|)
    end)

    first = crawl("#{context.url2}/holder", context, assets: ["js"], scope: scope)
    assert Store.find_processed({script, first.scope}).body == "js"

    opts = crawl(page, context, scope: scope)
    assert Store.find_processed({page, opts.scope})
    refute Store.find({private, opts.scope})
    refute Store.find({"#{context.url2}/script-rules.txt", opts.scope})
  end

  test "an unreadable robots file blocks this fetch and is requested again", context do
    calls = :counters.new(1, [:atomics])

    ReqTestSite.stub(context.site, "GET", "/robots.txt", fn conn ->
      :counters.add(calls, 1, 1)
      resp(conn, 200, <<0xFF>>)
    end)

    page = "#{context.url}/blocked"
    opts = crawl(page, context)
    refute Store.find({page, opts.scope})
    assert :counters.get(calls, 1) == 1

    crawl(page, context, scope: opts.scope, force: true)
    refute Store.find({page, opts.scope})
    assert :counters.get(calls, 1) == 2
  end

  test "an oversized robots response reports the root body limit", context do
    page = context.url <> "/robots-body-limit"
    max_body = 1_000
    body = "User-agent: *\nAllow: /\n" <> String.duplicate("#", 2_000)
    calls = :counters.new(1, [:atomics])

    assert byte_size(body) > max_body

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", &resp(&1, 200, body))

    ReqTestSite.stub(context.site, "GET", "/robots-body-limit", fn conn ->
      :counters.add(calls, 1, 1)
      html(conn, "root must stay unfetched")
    end)

    opts =
      crawl(page, context,
        max_body: max_body,
        max_control_bytes: 16_384,
        max_analysis_bytes: 2_097_152
      )

    assert opts.max_control_bytes > byte_size(body)

    assert %{status: :limited, reason: {:limit, :max_body}} =
             Store.target_outcome(opts.target_handle)

    assert {:ok,
            %{
              state: :limited,
              root_status: :limited,
              reported_limit: {:limit, :max_body},
              reason: {:limit, :max_body},
              terminal?: true,
              pending: 0,
              inflight: 0
            }} = Crawler.run_status(opts)

    assert :counters.get(calls, 1) == 0
    assert Store.ops_count(opts.scope) == 0
    refute Store.find({page, opts.scope})
    refute Store.find({context.url <> "/robots.txt", opts.scope})
    assert_robots_failure_cleanup(opts, Crawler.Site.origin(page))
    assert :sys.get_state(Store).scopes[opts.scope].control_bytes <= opts.max_control_bytes
  end

  test "a subresource redirect preserves the destination robots body limit", context do
    root = context.url <> "/redirect-limit-root"
    script = context.url <> "/redirect-limit.js"
    destination = context.url2 <> "/redirect-limit-destination.js"
    oversized = "User-agent: *\nAllow: /\n" <> String.duplicate("#", 2_000)
    destination_calls = :counters.new(1, [:atomics])

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, "User-agent: *\nAllow: /\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/redirect-limit-root", fn conn ->
      html(conn, ~s|<script src="/redirect-limit.js"></script>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/redirect-limit.js", fn conn ->
      conn |> put_resp_header("location", destination) |> resp(302, "")
    end)

    ReqTestSite.expect_once(context.site2, "GET", "/robots.txt", &resp(&1, 200, oversized))

    ReqTestSite.stub(context.site2, "GET", "/redirect-limit-destination.js", fn conn ->
      :counters.add(destination_calls, 1, 1)
      conn |> put_resp_header("content-type", "text/javascript") |> resp(200, "blocked")
    end)

    opts =
      crawl(root, context,
        assets: ["js"],
        max_body: 1_000,
        max_control_bytes: 16_384,
        max_analysis_bytes: 2_097_152
      )

    assert byte_size(oversized) > opts.max_body
    assert opts.max_control_bytes > byte_size(oversized)
    assert Crawler.Site.origin(root) != Crawler.Site.origin(destination)
    assert Store.find_processed({root, opts.scope})
    refute Store.find({script, opts.scope})
    refute Store.find({destination, opts.scope})
    assert :counters.get(destination_calls, 1) == 0
    run = {opts.scope, opts.generation}
    state = :sys.get_state(Store)

    assert [{_, %{outcome: %{status: :limited, reason: {:limit, :max_body}}}}] =
             Enum.filter(state.scheduler.frontier.jobs, fn {_ref, record} ->
               record.job.logical_key == script and Crawler.Frontier.run_key(record.job) == run
             end)

    assert {:ok,
            %{
              state: :limited,
              root_status: :succeeded,
              reported_limit: {:limit, :max_body},
              reason: {:limit, :max_body},
              terminal?: true,
              pending: 0,
              inflight: 0
            }} = Crawler.run_status(opts)

    refute Map.has_key?(Map.get(state.robots, opts.scope, %{}), Crawler.Site.origin(destination))

    refute Map.has_key?(
             Map.get(state.robots_receipts, run, %{}),
             Crawler.Site.origin(destination)
           )

    assert state.scopes[opts.scope].control_bytes <= opts.max_control_bytes
  end

  for {failure, reason} <- [
        overflow: {:limit, :max_body},
        expiry: {:deadline, :attempt}
      ] do
    test "a robots owner #{failure} reaches its waiting target", context do
      scope = unique_scope("robots-waiter-#{unquote(failure)}")
      observer = self()
      calls = :counters.new(2, [:atomics])
      origin = Crawler.Site.origin(context.url)
      body = "User-agent: *\nAllow: /\n" <> String.duplicate("#", 2_000)
      reason = unquote(Macro.escape(reason))

      ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
        :counters.add(calls, 1, 1)
        send(observer, {:robots_response_held, self()})

        receive do
          :release_robots_response -> resp(conn, 200, body)
        end
      end)

      for path <- ["/robots-owner", "/robots-waiter"] do
        ReqTestSite.stub(context.site, "GET", path, fn conn ->
          :counters.add(calls, 2, 1)
          html(conn, "root must stay unfetched")
        end)
      end

      assert {:ok, first} =
               start_crawl(context.url <> "/robots-owner",
                 scope: scope,
                 workers: 2,
                 store: Store,
                 retries: 0,
                 respect_robots: true,
                 max_body: 1_000,
                 max_control_bytes: 16_384,
                 max_analysis_bytes: 2_097_152,
                 attempt_timeout: 2_000,
                 run_timeout: 10_000,
                 req_options: context.req_options
               )

      assert_receive {:robots_response_held, handler}, 2_000
      on_exit(fn -> send(handler, :release_robots_response) end)

      assert {:loading, _, owner, queue, []} =
               get_in(:sys.get_state(Store).robots, [scope, origin])

      monitor = Process.monitor(owner)

      assert {:ok, second} =
               start_crawl(
                 context.url <> "/robots-waiter",
                 Map.put(first, :attempt_timeout, 5_000)
               )

      assert second.generation === first.generation
      assert second.queue === queue
      refute second.target_handle === first.target_handle

      waiter_deadline =
        wait(fn ->
          state = :sys.get_state(Store)

          assert {:loading, _, ^owner, ^queue, [{{waiter, _}, ^queue}]} =
                   get_in(state.robots, [scope, origin])

          owner_lease = Map.fetch!(state.execution_workers, owner)
          waiter_lease = Map.fetch!(state.execution_workers, waiter)
          owner_deadline = state.executions[owner_lease].deadline
          waiter_deadline = state.executions[waiter_lease].deadline
          assert owner_deadline.at < waiter_deadline.at
          assert Crawler.Deadline.check(owner_deadline) == :ok
          waiter_deadline
        end)

      if unquote(failure) == :overflow, do: send(handler, :release_robots_response)
      assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 5_000

      wait(fn ->
        for opts <- [first, second] do
          assert %{status: :limited, reason: ^reason} = Store.target_outcome(opts.target_handle)

          assert {:ok,
                  %{
                    state: :limited,
                    root_status: :limited,
                    reported_limit: ^reason,
                    reason: ^reason,
                    terminal?: true,
                    pending: 0,
                    inflight: 0
                  }} = Crawler.run_status(opts)
        end
      end)

      assert Crawler.Deadline.check(waiter_deadline) == :ok
      assert :counters.get(calls, 1) == 1
      assert :counters.get(calls, 2) == 0
      assert Store.ops_count(scope) == 0
      refute Store.find({first.url, scope})
      refute Store.find({second.url, scope})
      assert_robots_failure_cleanup(first, origin)
    end
  end

  test "a gzip sitemap above the body cap is not a page", context do
    page = "#{context.url}/start"
    listed = "#{context.url}/from-sitemap"
    xml = "<urlset><url><loc>#{listed}</loc></url></urlset>" <> String.duplicate(" ", 5_000)
    gzip = :zlib.gzip(xml)
    max_body = 1_000

    assert byte_size(gzip) < max_body
    assert byte_size(xml) > max_body

    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, "User-agent: *\nSitemap: #{context.url}/big.xml\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/start", &html(&1, "start"))
    ReqTestSite.expect_once(context.site, "GET", "/big.xml", &resp(&1, 200, gzip))

    opts = crawl(page, context, max_body: max_body)

    assert Store.find_processed({page, opts.scope}).body == "start"
    refute Store.find({listed, opts.scope})
    refute Store.find({"#{context.url}/big.xml", opts.scope})
  end

  test "a missing robots file still allows a private path", context do
    page = "#{context.url}/open"
    private = "#{context.url}/private"

    ReqTestSite.expect_once(context.site, "GET", "/open", fn conn ->
      html(conn, ~s|<a href="/private">p</a>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/private", &html(&1, "private"))

    opts = crawl(page, context)
    assert Store.find_processed({private, opts.scope}).body == "private"
  end

  test "a dead robots owner does not allow a page that was waiting" do
    scope = unique_scope("robots-owner")
    origin = "http://robots-owner.test"
    generation = Store.generation(scope)
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:claimed, Store.claim_robots(scope, origin, generation)})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:claimed, :owner}, 1_000

    waiter = Task.async(fn -> Store.claim_robots(scope, origin, generation) end)
    wait(2_000, fn -> assert waiting_robots?(scope, origin) end)
    Process.exit(owner, :kill)

    assert {:ready, rules} = Task.await(waiter, 2_000)
    refute Robots.allowed?(rules, origin <> "/private", "Crawler/1")
    assert Store.claim_robots(scope, origin, generation) == :owner
    assert Store.finish_robots(scope, origin, Robots.allow_all(), generation) == :ok
  end

  test "a sitemap on another host lists only same-site pages" do
    hosts = ReqTestSite.open(hosts: 3)
    [cdn, other] = Enum.take(hosts.sites, -2)
    page = "#{hosts.url}/start"
    listed = "#{hosts.url}/from-sitemap?a=1&b=2"
    secret = "#{hosts.url}/secret"

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
      <url>
        <loc>#{String.replace(listed, "&", "&amp;")}</loc>
        <lastmod>2020-01-01</lastmod>
        <priority>0.8</priority>
        <image:image><image:loc>#{cdn.url}/pic.jpg</image:loc></image:image>
      </url>
      <url><loc>#{secret}</loc></url>
      <url><loc>#{other.url}/out</loc></url>
    </urlset>
    """

    index = """
    <sitemapindex>
      <sitemap><loc>#{cdn.url}/child.xml</loc></sitemap>
    </sitemapindex>
    """

    ReqTestSite.expect_once(hosts.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, """
      User-agent: *
      Disallow: /secret
      Sitemap: #{cdn.url}/index.xml
      """)
    end)

    ReqTestSite.expect_once(hosts.site, "GET", "/start", &html(&1, "start"))
    ReqTestSite.expect_once(cdn, "GET", "/index.xml", &resp(&1, 200, index))

    ReqTestSite.expect_once(cdn, "GET", "/child.xml", fn conn ->
      resp(conn, 200, :zlib.gzip(xml))
    end)

    ReqTestSite.expect_once(hosts.site, "GET", "/from-sitemap", &html(&1, "listed"))

    opts = crawl(page, hosts)

    assert Store.find_processed({page, opts.scope}).body == "start"
    assert Store.find_processed({listed, opts.scope}).body == "listed"
    refute Store.find({secret, opts.scope})
    refute Store.find({"#{other.url}/out", opts.scope})
    refute Store.find({"#{cdn.url}/index.xml", opts.scope})
    refute Store.find({"#{cdn.url}/child.xml", opts.scope})
    refute Store.find({"#{cdn.url}/pic.jpg", opts.scope})
    assert Store.ops_count(opts.scope) == 2
  end

  test "respect_robots false does not fetch a sitemap", context do
    calls = :counters.new(1, [:atomics])

    ReqTestSite.stub(context.site, "GET", "/robots.txt", fn conn ->
      :counters.add(calls, 1, 1)
      resp(conn, 200, "User-agent: *\nSitemap: #{context.url2}/sitemap.xml\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/quiet", &html(&1, "quiet"))

    opts = crawl("#{context.url}/quiet", context, respect_robots: false)
    assert Store.find_processed({"#{context.url}/quiet", opts.scope})
    assert :counters.get(calls, 1) == 0
  end

  test "a redirect into a disallowed path is not fetched", context do
    ReqTestSite.expect_once(context.site, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, "User-agent: *\nDisallow: /private\n")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/start", fn conn ->
      html(conn, ~s|<a href="/go">g</a><script src="/app.js"></script>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/go", fn conn ->
      conn
      |> put_resp_header("location", "/private")
      |> resp(302, ~s|<a href="/after">x</a>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/app.js", fn conn ->
      conn
      |> put_resp_header("content-type", "text/javascript")
      |> put_resp_header("location", "/private/app.js")
      |> resp(302, "")
    end)

    opts = crawl("#{context.url}/start", context, assets: ["js"])

    assert Store.find_processed({"#{context.url}/start", opts.scope})
    refute Store.find({"#{context.url}/private", opts.scope})
    refute Store.find({"#{context.url}/after", opts.scope})
    refute Store.find({"#{context.url}/private/app.js", opts.scope})
  end

  test "respect_robots false still follows a redirect", context do
    ReqTestSite.expect_once(context.site, "GET", "/start", fn conn ->
      html(conn, ~s|<a href="/go">g</a><script src="/app.js"></script>|)
    end)

    ReqTestSite.expect_once(context.site, "GET", "/go", fn conn ->
      conn
      |> put_resp_header("location", "/private")
      |> resp(302, "")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/private", &html(&1, "private"))

    ReqTestSite.expect_once(context.site, "GET", "/app.js", fn conn ->
      conn
      |> put_resp_header("content-type", "text/javascript")
      |> put_resp_header("location", "/private/app.js")
      |> resp(302, "")
    end)

    ReqTestSite.expect_once(context.site, "GET", "/private/app.js", fn conn ->
      conn |> put_resp_header("content-type", "text/javascript") |> resp(200, "js")
    end)

    opts =
      crawl("#{context.url}/start", context, assets: ["js"], respect_robots: false)

    assert Store.find_processed({"#{context.url}/private", opts.scope}).body == "private"
    assert Store.find_processed({"#{context.url}/private/app.js", opts.scope}).body == "js"
  end

  test "an asset on another host does not import that host's sitemaps" do
    hosts = ReqTestSite.open(hosts: 2)
    cdn = hosts.site2

    ReqTestSite.expect_once(cdn, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, """
      User-agent: *
      Sitemap: #{cdn.url}/list.xml
      """)
    end)

    ReqTestSite.expect_once(hosts.site, "GET", "/start", fn conn ->
      html(conn, """
      <iframe src="#{cdn.url}/widget"></iframe>
      <script src="#{cdn.url}/app.js"></script>
      <img src="#{cdn.url}/pic.png">
      """)
    end)

    ReqTestSite.expect_once(cdn, "GET", "/widget", &html(&1, "widget"))

    ReqTestSite.expect_once(cdn, "GET", "/app.js", fn conn ->
      conn |> put_resp_header("content-type", "text/javascript") |> resp(200, "app")
    end)

    ReqTestSite.expect_once(cdn, "GET", "/pic.png", fn conn ->
      conn |> put_resp_header("content-type", "image/png") |> resp(200, "png")
    end)

    opts = crawl("#{hosts.url}/start", hosts, assets: ["js", "images"])

    assert Store.find_processed({"#{cdn.url}/widget", opts.scope}).body == "widget"
    assert Store.find_processed({"#{cdn.url}/app.js", opts.scope}).body == "app"
    assert Store.find_processed({"#{cdn.url}/pic.png", opts.scope})
    refute Store.find({"#{hosts.url}/injected", opts.scope})
    refute Store.find({"#{cdn.url}/only-on-cdn", opts.scope})
  end

  test "a disallowed asset on another host is not fetched and its sitemaps stay unread" do
    hosts = ReqTestSite.open(hosts: 2)
    cdn = hosts.site2

    ReqTestSite.expect_once(cdn, "GET", "/robots.txt", fn conn ->
      resp(conn, 200, """
      User-agent: *
      Disallow: /widget
      Sitemap: #{cdn.url}/list.xml
      """)
    end)

    ReqTestSite.expect_once(hosts.site, "GET", "/start", fn conn ->
      html(conn, """
      <iframe src="#{cdn.url}/widget"></iframe>
      <script src="#{cdn.url}/app.js"></script>
      """)
    end)

    ReqTestSite.expect_once(cdn, "GET", "/app.js", fn conn ->
      conn |> put_resp_header("content-type", "text/javascript") |> resp(200, "app")
    end)

    opts = crawl("#{hosts.url}/start", hosts, assets: ["js"])

    assert Store.find_processed({"#{cdn.url}/app.js", opts.scope}).body == "app"
    refute Store.find({"#{cdn.url}/widget", opts.scope})
    refute Store.find({"#{hosts.url}/injected", opts.scope})
  end

  defp assert_robots_failure_cleanup(opts, origin) do
    run = {opts.scope, opts.generation}

    wait(fn ->
      state = :sys.get_state(Store)
      refute Map.has_key?(Map.get(state.robots, opts.scope, %{}), origin)
      refute Map.has_key?(state.robots_receipts, run)
      refute Map.has_key?(state.resources.runs, run)
      refute Enum.any?(state.resources.receipts, fn {_ref, receipt} -> receipt.run == run end)
      refute Enum.any?(state.scheduler.claims, fn {_ref, claim} -> claim.run == run end)

      refute Enum.any?(state.executions, fn {_ref, record} ->
               {record.opts.scope, record.opts.generation} == run
             end)
    end)
  end

  defp waiting_robots?(scope, origin) do
    state = :sys.get_state(Store)
    match?({:loading, _, _, _, [_ | _]}, get_in(state.robots, [scope, origin]))
  end

  defp crawl(url, context, extra \\ []) do
    scope = extra[:scope] || unique_scope("robots-crawl")

    opts =
      Keyword.merge(
        [
          store: Store,
          workers: 1,
          scope: scope,
          retries: 0,
          max_depths: 3,
          user_agent: "Crawler/1.5.0 (test)",
          req_options: context.req_options
        ],
        extra
      )

    {:ok, opts} = start_crawl(url, opts)
    await_idle(opts)
    opts
  end

  defp html(conn, body) do
    conn
    |> put_resp_header("content-type", "text/html")
    |> resp(200, body)
  end
end
