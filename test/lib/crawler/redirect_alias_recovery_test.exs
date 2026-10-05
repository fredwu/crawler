defmodule Crawler.RedirectAliasRecoveryTest do
  use Crawler.TestCase, async: false

  alias Crawler.RequestLog
  alias Crawler.Store
  alias Crawler.Store.Page

  import Crawler.RedirectHelpers, only: [fetcher: 1]

  defmodule CapturingStore do
    def add_page_data({url, scope} = key, body, opts) do
      send(opts[:storage_owner], {:stored, key, body})

      if opts[:storage_retire_url] == url, do: Store.drop_scope(scope)

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

      {:ok, again} =
        start_crawl(landing,
          queue: opts.queue,
          scope: scope,
          store: store,
          req_options: context.req_options
        )

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
      generation = Store.generation(scope)
      landing = "#{context.url}/reused/landing"
      queue = self()
      assert :ok = Store.note_enqueued(scope, generation, queue)
      assert {:ok, _} = Store.add({landing, scope}, generation, queue)
      original = Store.find({landing, scope})
      serve_redirect(context, landing)

      result =
        fetcher(%{
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
        })

      expected =
        if unquote(reason) == :stale, do: {:warn, :stale}, else: {:error, unquote(reason)}

      assert result == expected
      assert Store.find({landing, scope}) == original
      refute Store.find_processed({landing, scope})
    end
  end

  test "scope retirement during reused alias storage returns stale without completing pages",
       context do
    scope = unique_scope("redirect-alias-retired")
    generation = Store.generation(scope)
    landing = "#{context.url}/reused/landing"
    queue = self()
    assert :ok = Store.note_enqueued(scope, generation, queue)
    assert {:ok, _} = Store.add({landing, scope}, generation, queue)
    serve_redirect(context, landing)

    assert {:warn, :stale} =
             fetcher(%{
               url: "#{context.url}/reused/old",
               scope: scope,
               generation: generation,
               queue: queue,
               retries: 0,
               store: CapturingStore,
               storage_owner: self(),
               storage_retire_url: landing,
               req_options: context.req_options
             })

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

    ReqTestSite.expect_once(context.site, "GET", "/reused/landing", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "RECOVERED")
    end)
  end
end
