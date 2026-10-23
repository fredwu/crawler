defmodule Crawler.AliasSettlementPrivacyTest do
  use Crawler.TestCase, async: false

  import Crawler.ManagedSnapshotHelpers
  alias Crawler.Store

  @secret "private-settlement-callback-secret"
  @userinfo "private-settlement-user:private-settlement-password"

  defmodule RaisingStore do
    def add_page_data({url, _scope}, _body, opts) do
      if url == opts[:landing_url], do: raise(opts[:private_message]), else: :ok
    end
  end

  for failure <- [:storage, :publication] do
    test "a #{failure} settlement failure returns safely and releases all work", context do
      root = Path.join(tmp(unique_scope("settlement-privacy")), "archive")
      scope = unique_scope("settlement-privacy")
      source = credentialed(context.url <> "/settlement/old.bin")
      landing = credentialed(context.url <> "/settlement/landing/page.bin")
      requests = :counters.new(1, [:atomics])
      observer = self()
      failure = unquote(failure)
      on_exit(fn -> File.rm_rf(Path.dirname(root)) end)

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

      assert {:ok, opts} =
               start_crawl(landing,
                 scope: scope,
                 workers: 2,
                 max_body: 1_048_576,
                 max_analysis_bytes: 16_000_000,
                 max_css_work: 5_000,
                 max_css_pictures: 1_000,
                 retries: 0,
                 store: if(failure == :storage, do: RaisingStore, else: Store),
                 save_to: if(failure == :publication, do: root),
                 private_message: @secret,
                 landing_url: landing,
                 req_options: context.req_options
               )

      on_exit(fn -> Crawler.stop(opts) end)
      assert_receive {:held_landing, holder}, 2_000
      on_exit(fn -> send(holder, :release) end)
      assert {:ok, _} = start_crawl(source, opts)
      wait(fn -> assert Store.find_processed({source, scope}) end)

      if failure == :storage do
        Crawler.pause(opts)
        assert {:paused, _, _} = OPQ.info(opts.queue)
      else
        File.mkdir_p!(root)
        File.write!(Path.join(root, "complete.bin"), "PREVIOUS COMPLETE")
      end

      send(holder, :release)

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          if failure == :storage, do: Crawler.resume(opts)
          wait(fn -> assert_settled(scope) end)

          if failure == :publication do
            wait(fn ->
              assert {:ok, %{state: :failed, ready?: false}} = Crawler.export_status(opts)
            end)
          end
        end)

      if failure == :storage do
        assert log =~ "Alias settlement failed for #{context.url}/settlement/landing/page.bin"
        assert log =~ "RuntimeError"
        assert log =~ "Crawler.Fetcher.AliasSettlement.store/2"
        refute Store.find({landing, scope})
      else
        assert File.read!(Path.join(root, "complete.bin")) == "PREVIOUS COMPLETE"
        assert File.ls!(root) == ["complete.bin"]
        assert {:ok, status} = Crawler.export_status(opts)
        refute inspect(status) =~ @secret
        refute inspect(status) =~ @userinfo
      end

      refute log =~ @secret
      refute log =~ "private-settlement-user"
      refute log =~ "private-settlement-password"
      refute log =~ "Task "
      assert_settled(scope)
      assert Process.alive?(opts.queue)

      retry_scope = if failure == :publication, do: unique_scope("publication-retry"), else: scope
      retry_opts = opts |> Map.put(:store, Store) |> Map.put(:scope, retry_scope)

      retry_opts =
        if failure == :publication,
          do: Map.put(retry_opts, :save_to, root <> "-retry"),
          else: retry_opts

      assert {:ok, retry} = start_crawl(landing, retry_opts)

      if failure == :publication do
        export = ready_export(retry)
        target = resource_for_url(export, landing)
        assert read_resource(export, target) == "RETRY"
        assert target["content_type"] == "application/octet-stream"
        assert is_nil(URI.parse(target["url"]).userinfo)
        refute target["path"] =~ "private-settlement"
        assert File.read!(Path.join(root, "complete.bin")) == "PREVIOUS COMPLETE"
      else
        await_idle(retry)
      end

      assert Store.find_processed({landing, retry_scope}).body == "RETRY"
      assert :counters.get(requests, 1) == 3
      assert_settled(scope)
      assert_settled(retry_scope)
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
