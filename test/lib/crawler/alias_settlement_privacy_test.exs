defmodule Crawler.AliasSettlementPrivacyTest do
  use Crawler.TestCase, async: false

  alias Crawler.Fetcher.AliasSettlement
  alias Crawler.SnapshotHelpers
  alias Crawler.Store
  alias Crawler.Worker

  @secret "private-settlement-callback-secret"
  @userinfo "private-settlement-user:private-settlement-password"

  defmodule RaisingStore do
    def add_page_data({url, _scope}, _body, opts) do
      if url == opts[:landing_url], do: raise(opts[:private_message]), else: :ok
    end
  end

  for failure <- [:storage, :publication] do
    test "a #{failure} settlement failure returns safely and releases all work", context do
      root = tmp(unique_scope("settlement-privacy"))
      scope = unique_scope("settlement-privacy")
      source = credentialed(context.url <> "/settlement/old.bin")
      landing = credentialed(context.url <> "/settlement/landing/page.bin")
      file = SnapshotHelpers.saved(root, landing)
      requests = :counters.new(1, [:atomics])
      observer = self()
      failure = unquote(failure)
      on_exit(fn -> File.rm_rf(root) end)

      ReqTestSite.expect_once(context.site, "GET", "/settlement/old.bin", fn conn ->
        conn |> Plug.Conn.put_resp_header("location", landing) |> Plug.Conn.resp(302, "")
      end)

      ReqTestSite.expect(context.site, "GET", "/settlement/landing/page.bin", fn conn ->
        :counters.add(requests, 1, 1)
        conn = Plug.Conn.put_resp_header(conn, "content-type", "application/octet-stream")

        case :counters.get(requests, 1) do
          1 ->
            send(observer, {:held_landing, self()})

            receive do
              :release -> Plug.Conn.resp(conn, 500, "FAILED")
            end

          2 ->
            Plug.Conn.resp(conn, 200, "REDIRECT")

          3 ->
            Plug.Conn.resp(conn, 200, "RETRY")
        end
      end)

      before_publish = fn ->
        if Path.wildcard(Path.join(Path.dirname(file), ".crawler-*.tmp"), match_dot: true) != [],
          do: raise(@secret)
      end

      assert {:ok, opts} =
               start_crawl(landing,
                 scope: scope,
                 workers: 2,
                 retries: 0,
                 store: if(failure == :storage, do: RaisingStore, else: Store),
                 save_to: if(failure == :publication, do: root),
                 before_publish: before_publish,
                 private_message: @secret,
                 landing_url: landing,
                 req_options: context.req_options
               )

      on_exit(fn -> Crawler.stop(opts) end)
      assert_receive {:held_landing, holder}, 2_000
      on_exit(fn -> send(holder, :release) end)
      assert {:ok, _} = start_crawl(source, opts)
      wait(fn -> assert Store.find_processed({source, scope}) end)
      Crawler.pause(opts)
      assert {:paused, _, _} = OPQ.info(opts.queue)
      send(holder, :release)

      wait(fn ->
        assert Store.inflight_count(scope) == 0

        assert [{_, %{status: :queued}}] =
                 Map.to_list(:sys.get_state(Store).settlements.candidates)
      end)

      [{ref, _}] = Map.to_list(:sys.get_state(Store).settlements.candidates)
      job = %AliasSettlement{ref: ref, queue: opts.queue}

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          task = Task.async(fn -> Worker.run(job) end)
          assert {:error, {:error, %RuntimeError{message: @secret}}} = Task.await(task)
        end)

      assert log =~ "Alias settlement failed for #{context.url}/settlement/landing/page.bin"
      assert log =~ "RuntimeError"
      assert log =~ "Crawler.Fetcher.AliasSettlement.run/1"
      if failure == :publication, do: assert(log =~ "Crawler.Snapper.publish/3")
      refute log =~ @secret
      refute log =~ "private-settlement-user"
      refute log =~ "private-settlement-password"
      refute log =~ "Task "
      assert_settled(scope)
      refute Store.find({landing, scope})
      refute File.exists?(file)
      assert Path.wildcard(Path.join(root, "**/.crawler-*.tmp"), match_dot: true) == []
      assert Process.alive?(opts.queue)

      Crawler.resume(opts)
      retry_opts = opts |> Map.put(:store, Store) |> Map.delete(:before_publish)
      assert {:ok, retry} = start_crawl(landing, retry_opts)
      await_idle(retry)
      assert Store.find_processed({landing, scope}).body == "RETRY"
      assert :counters.get(requests, 1) == 3
      assert_settled(scope)
    end
  end

  defp credentialed(url),
    do: url |> URI.parse() |> Map.put(:userinfo, @userinfo) |> URI.to_string()

  defp assert_settled(scope) do
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
    assert :sys.get_state(Store).settlements.candidates == %{}
    assert :sys.get_state(Store).claims.active == %{}
  end
end
