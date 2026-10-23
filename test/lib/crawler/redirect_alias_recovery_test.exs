defmodule Crawler.RedirectAliasRecoveryTest do
  use Crawler.TestCase, async: false

  alias Crawler.RequestLog
  alias Crawler.Store
  alias Crawler.Store.Page

  defmodule CapturingStore do
    def add_page_data({url, scope} = key, body, opts) do
      send(opts[:storage_owner], {:stored, key, body})

      if opts[:storage_retire_url] == url do
        send(opts[:storage_owner], {:retiring_alias, self(), opts[:execution_lease]})
        Store.drop_scope(scope)
      end

      if opts[:storage_error_url] == url,
        do: {:error, opts[:storage_error]},
        else: :ok
    end
  end

  for store <- [nil, Store, CapturingStore] do
    test "a successful redirect completes a failed landing with #{inspect(store)}", context do
      store = unquote(store)
      scope = unique_scope("redirect-alias-recovery")

      %{hub: hub, old: old, landing: landing, body: body, requests: requests} =
        serve_recovery(context, scope)

      {:ok, opts} =
        start_crawl(hub,
          workers: 1,
          retries: 0,
          store: store,
          storage_owner: self(),
          scope: scope,
          req_options: context.req_options
        )

      await_idle(opts)
      assert %Page{processed: true} = page = Store.find({landing, scope})
      assert Store.find_processed({old, scope})
      assert Store.ops_count(scope) == 2

      if store == Store do
        assert page.body == body
        assert page.opts.url == landing
      else
        assert page.body == nil
        assert page.opts == nil
      end

      if store == CapturingStore do
        assert_receive {:stored, {^hub, ^scope}, _}
        assert_receive {:stored, {^old, ^scope}, ^body}
        assert_receive {:stored, {^landing, ^scope}, ^body}
        refute_receive {:stored, _, _}
      end

      {:ok, again} = Crawler.crawl_reference(landing, opts)

      await_idle(again)

      assert RequestLog.frequencies(requests) == %{
               "/recovery/hub" => 1,
               "/recovery/landing" => 2,
               "/recovery/old" => 1
             }
    end
  end

  for reason <- [:storage_failed, :stale] do
    test "a reused alias survives a #{reason} storage error", context do
      scope = unique_scope("redirect-alias-error")
      landing = "#{context.url}/reused/landing"
      held = hold_landing(context, scope, landing)
      generation = held.generation
      queue = held.queue
      original = Store.find({landing, scope})
      serve_redirect(context, landing)

      with_reused_fetch(
        held,
        %{
          url: "#{context.url}/reused/old",
          scope: scope,
          generation: generation,
          queue: queue,
          retries: 0,
          store: CapturingStore,
          storage_owner: self(),
          storage_error_url: landing,
          storage_error: unquote(reason),
          req_options: context.req_options
        },
        fn task ->
          expected =
            if unquote(reason) == :stale, do: {:warn, :stale}, else: {:error, unquote(reason)}

          worker = task.pid
          assert_receive {:reused_fetch_result, ^worker, ^expected}, 2_000
          assert Store.find({landing, scope}) == original
          refute Store.find_processed({landing, scope})
          send(worker, :finish)
          assert Task.await(task, 2_000) == expected
        end
      )
    end
  end

  test "scope retirement during reused alias storage revokes execution without completing pages",
       context do
    scope = unique_scope("redirect-alias-retired")
    landing = "#{context.url}/reused/landing"
    held = hold_landing(context, scope, landing)
    generation = held.generation
    queue = held.queue
    serve_redirect(context, landing)

    with_reused_fetch(
      held,
      %{
        url: "#{context.url}/reused/old",
        scope: scope,
        generation: generation,
        queue: queue,
        retries: 0,
        store: CapturingStore,
        storage_owner: self(),
        storage_retire_url: landing,
        req_options: context.req_options
      },
      fn task ->
        assert_receive {:retiring_alias, executor, lease}, 2_000
        assert is_reference(lease)
        assert {:exit, :killed} = Task.yield(task, 2_000)
        wait(fn -> refute Process.alive?(executor) end)
        refute Crawler.Store.Authority.execution_current?(lease)
      end
    )

    refute Store.generation(scope) == generation
    refute Store.find({landing, scope})
    refute Store.find({"#{context.url}/reused/old", scope})
  end

  defp serve_recovery(context, scope) do
    hub = "#{context.url}/recovery/hub"
    old = "#{context.url}/recovery/old"
    landing = "#{context.url}/recovery/landing"
    body = "<p>RECOVERED</p>"
    hits = :counters.new(1, [:atomics])
    requests = RequestLog.new()

    ReqTestSite.expect_once(context.site, "GET", "/recovery/hub", fn conn ->
      RequestLog.record(requests, conn.request_path)

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, ~s|<a href="#{landing}">landing</a><a href="#{old}">old</a>|)
    end)

    ReqTestSite.expect(context.site, "GET", "/recovery/landing", fn conn ->
      RequestLog.record(requests, conn.request_path)
      :counters.add(hits, 1, 1)

      if :counters.get(hits, 1) == 1 do
        Plug.Conn.resp(conn, 500, "FAILED")
      else
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.resp(200, body)
      end
    end)

    ReqTestSite.expect_once(context.site, "GET", "/recovery/old", fn conn ->
      RequestLog.record(requests, conn.request_path)
      assert %Page{processed: processed} = Store.find({landing, scope})
      refute processed

      conn
      |> Plug.Conn.put_resp_header("location", landing)
      |> Plug.Conn.resp(302, "")
    end)

    %{hub: hub, old: old, landing: landing, body: body, requests: requests}
  end

  defp serve_redirect(context, landing) do
    ReqTestSite.expect_once(context.site, "GET", "/reused/old", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", landing)
      |> Plug.Conn.resp(302, "")
    end)
  end

  defp hold_landing(context, scope, landing) do
    owner = self()
    hits = :counters.new(1, [:atomics])

    ReqTestSite.expect(context.site, "GET", "/reused/landing", fn conn ->
      :counters.add(hits, 1, 1)

      if :counters.get(hits, 1) == 1 do
        send(owner, {:landing_held, self()})

        receive do
          :release -> Plug.Conn.resp(conn, 500, "FAILED")
        end
      else
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.resp(200, "RECOVERED")
      end
    end)

    assert {:ok, opts} =
             start_crawl(landing,
               workers: 2,
               retries: 0,
               store: nil,
               scope: scope,
               req_options: context.req_options
             )

    assert_receive {:landing_held, request}, 2_000

    on_exit(fn ->
      send(request, :release)
      Crawler.stop(opts)
    end)

    assert %Page{processed: processed} = Store.find({landing, scope})
    refute processed
    Map.put(opts, :held_request, request)
  end

  defp with_reused_fetch(held, opts, callback) do
    OPQ.pause(held.queue)
    assert {:paused, _, _} = OPQ.info(held.queue)
    opts = opts |> Map.put(:respect_robots, false) |> Crawler.Options.assign_defaults()
    assert {:ok, _} = Crawler.crawl(opts.url, opts)
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        assert {:ok, claim, :fetch, admitted} = Store.checkout_job(held.queue)
        send(parent, {:reused_claimed, self()})

        receive do
          :fetch -> :ok
        end

        result = Crawler.Fetcher.fetch(admitted)
        send(parent, {:reused_fetch_result, self(), result})

        receive do
          :finish -> :ok
        end

        Store.complete_job(claim, Crawler.Job.Outcome.from_result(result))
        result
      end)

    worker = task.pid
    assert_receive {:reused_claimed, ^worker}, 2_000
    send(held.held_request, :release)
    wait(fn -> assert %{status: :failed} = Store.target_outcome(held.target_handle) end)
    send(worker, :fetch)

    try do
      callback.(task)
    after
      send(worker, :finish)
      if Process.alive?(worker), do: Task.shutdown(task, 2_000)
    end
  end
end
