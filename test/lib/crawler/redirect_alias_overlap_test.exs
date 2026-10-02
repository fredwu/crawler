defmodule Crawler.RedirectAliasOverlapTest do
  use Crawler.TestCase, async: false

  alias Crawler.SnapshotHelpers
  alias Crawler.Store
  alias Crawler.Store.Page

  defmodule CapturingStore do
    def add_page_data(key, body, opts) do
      send(opts[:observer], {:stored, key, body})
      :ok
    end
  end

  defmodule GatedParser do
    def parse(%Page{opts: opts} = page) do
      if opts[:url] == opts[:gated_url] do
        send(opts[:observer], {:parsed, self()})

        receive do
          :release -> :ok
        end
      end

      if opts[:source_failure] && opts[:url] == opts[:gated_url],
        do: {:error, :source_failed},
        else: {:ok, page}
    end

    def parse(other), do: Crawler.Parser.parse(other)
  end

  defmodule GatedStore do
    def add_page_data({url, _scope}, body, opts) do
      if url == opts[:landing_url] && body == "REDIRECT" do
        send(opts[:observer], {:settlement, self()})

        receive do
          {:release_settlement, :ok} ->
            :ok

          {:release_settlement, :error} ->
            {:error, :storage_failed}

          {:release_settlement, :raise} ->
            raise "settlement failed"

          {:release_settlement, :linked_exit} ->
            spawn_link(fn -> exit(:settlement_failed) end)

            receive do
              :never -> :ok
            end
        end
      else
        :ok
      end
    end
  end

  for store <- [nil, Store, CapturingStore],
      result <- [:failure, :success],
      order <- [:redirect_first, :landing_first] do
    test "#{inspect(store)} keeps a successful landing after #{result}, #{order}", context do
      exercise_overlap(context, unquote(store), unquote(result), unquote(order))
    end
  end

  defp exercise_overlap(context, store, result, order) do
    %{
      scope: scope,
      old: old,
      landing: landing,
      opts: opts,
      direct: direct,
      redirected: redirected,
      hits: hits
    } = start_overlap(context, store, result)

    case order do
      :redirect_first ->
        send(redirected, :release)
        wait(fn -> assert Store.find_processed({old, scope}) end)
        send(direct, :release)

      :landing_first ->
        send(direct, :release)
        wait(fn -> assert Store.inflight_count(scope) == 1 end)
        send(redirected, :release)
    end

    await_idle(opts)
    assert %Page{processed: true} = page = Store.find_processed({landing, scope})
    assert Store.find_processed({old, scope})
    expected = if result == :success, do: "DIRECT", else: "REDIRECT"
    assert page.body == if(store == Store, do: expected)
    assert Store.ops_count(scope) == if(result == :success, do: 2, else: 1)
    assert_settled(scope)

    if store == CapturingStore do
      assert_receive {:stored, {^old, ^scope}, "REDIRECT"}
      assert_receive {:stored, {^landing, ^scope}, ^expected}
      refute_receive {:stored, {^landing, ^scope}, _}
    end

    assert {:ok, again} = start_crawl(landing, opts)
    await_idle(again)
    assert :counters.get(hits, 1) == 2
    assert Store.find_processed({landing, scope})
  end

  test "retains one completed fallback while many redirects share a held landing", context do
    rig = start_overlap(context, Store, :failure, multiple_redirects: true)
    send(rig.redirected, :release)
    wait(fn -> assert Store.find_processed({rig.old, rig.scope}) end)

    ReqTestSite.expect(context.site, "GET", "/overlap/more", fn conn ->
      conn |> Plug.Conn.put_resp_header("location", rig.landing) |> Plug.Conn.resp(302, "")
    end)

    for index <- 1..12 do
      url = context.url <> "/overlap/more?i=#{index}"
      assert {:ok, _} = start_crawl(url, %{rig.opts | max_pages: :infinity})
      wait(fn -> assert Store.find_processed({url, rig.scope}) end)
      assert map_size(:sys.get_state(Store).settlements.candidates) == 1
    end

    send(rig.direct, :release)
    await_idle(rig.opts)
    assert %Page{body: "REDIRECT"} = Store.find_processed({rig.landing, rig.scope})
    assert_settled(rig.scope)
  end

  for action <- [:error, :raise, :linked_exit] do
    test "a #{action} settlement callback releases its monitored work and permits retry",
         context do
      rig = start_overlap(context, GatedStore, :failure, allow_retry: true)
      send(rig.redirected, :release)
      wait(fn -> assert Store.find_processed({rig.old, rig.scope}) end)
      send(rig.direct, :release)
      assert_receive {:settlement, callback}, 2_000
      on_exit(fn -> send(callback, {:release_settlement, :ok}) end)
      monitor = Process.monitor(callback)
      assert Process.alive?(rig.opts.queue)
      assert Store.pending_count(rig.scope) == 1
      assert Store.inflight_count(rig.scope) == 0
      assert Store.generation(rig.scope) == rig.opts.generation
      send(callback, {:release_settlement, unquote(action)})
      assert_receive {:DOWN, ^monitor, _, _, _}, 2_000
      await_idle(rig.opts)
      refute Store.find({rig.landing, rig.scope})
      assert Store.find_processed({rig.old, rig.scope})
      assert Process.alive?(rig.opts.queue)
      assert_settled(rig.scope)

      assert {:ok, again} = start_crawl(rig.landing, rig.opts)
      await_idle(again)
      assert Store.find_processed({rig.landing, rig.scope})
      assert :counters.get(rig.hits, 1) == 3
    end
  end

  for result <- [:failure, :success] do
    test "saved landing bytes preserve the successful result after #{result}", context do
      root = tmp(unique_scope("alias-overlap-snapshot"))
      rig = start_overlap(context, Store, unquote(result), save_to: root)
      send(rig.redirected, :release)
      wait(fn -> assert Store.find_processed({rig.old, rig.scope}) end)
      send(rig.direct, :release)
      await_idle(rig.opts)
      expected = if unquote(result) == :success, do: "DIRECT", else: "REDIRECT"
      assert File.read!(SnapshotHelpers.saved(root, rig.landing)) == expected
      assert File.read!(SnapshotHelpers.saved(root, rig.old)) == "REDIRECT"
      assert_settled(rig.scope)
    end
  end

  for event <- [:scope_drop, :feeder_death, :fresh_generation] do
    test "#{event} retires a running callback without overwriting a new landing", context do
      root = tmp(unique_scope("alias-settlement-retirement"))
      rig = start_overlap(context, GatedStore, :failure, allow_retry: true, save_to: root)
      send(rig.redirected, :release)
      wait(fn -> assert Store.find_processed({rig.old, rig.scope}) end)
      send(rig.direct, :release)
      assert_receive {:settlement, callback}, 2_000
      on_exit(fn -> send(callback, {:release_settlement, :ok}) end)
      monitor = Process.monitor(callback)
      assert Store.pending_count(rig.scope) == 1

      fresh_opts = %{rig.opts | store: Store}

      fresh_opts =
        case unquote(event) do
          :scope_drop ->
            Store.drop_scope(rig.scope)
            Map.delete(fresh_opts, :generation)

          :feeder_death ->
            Process.exit(rig.opts.queue, :kill)
            wait(fn -> refute Process.alive?(rig.opts.queue) end)
            wait(fn -> assert_settled(rig.scope) end)

            fresh_opts
            |> Map.put(:queue, nil)
            |> Map.delete(:queue_owner)
            |> Map.delete(:generation)

          :fresh_generation ->
            %{fresh_opts | force: true}
        end

      assert {:ok, fresh} = start_crawl(rig.landing, fresh_opts)
      await_idle(fresh)
      assert Store.find_processed({rig.landing, rig.scope}).body == "RETRY"
      assert File.read!(SnapshotHelpers.saved(root, rig.landing)) == "RETRY"
      send(callback, {:release_settlement, :ok})
      assert_receive {:DOWN, ^monitor, _, _, _}, 2_000
      assert Store.find_processed({rig.landing, rig.scope}).body == "RETRY"
      assert File.read!(SnapshotHelpers.saved(root, rig.landing)) == "RETRY"
      assert_settled(rig.scope)
      on_exit(fn -> Crawler.stop(fresh) end)
    end
  end

  for event <- [:scope_stop, :feeder_death] do
    test "#{event} discards waiting candidates without late promotion", context do
      rig = start_overlap(context, Store, :failure)
      send(rig.redirected, :release)
      wait(fn -> assert Store.find_processed({rig.old, rig.scope}) end)
      assert map_size(:sys.get_state(Store).settlements.candidates) == 1

      case unquote(event) do
        :scope_stop -> Crawler.stop(rig.opts)
        :feeder_death -> Process.exit(rig.opts.queue, :kill)
      end

      wait(fn -> refute Process.alive?(rig.opts.queue) end)
      send(rig.direct, :release)
      wait(fn -> assert_settled(rig.scope) end)
      refute Store.find({rig.landing, rig.scope})
    end
  end

  test "a failed redirect source discards its provisional landing body", context do
    rig = start_overlap(context, Store, :failure, source_failure: true)
    send(rig.redirected, :release)
    wait(fn -> assert Store.inflight_count(rig.scope) == 1 end)
    assert :sys.get_state(Store).settlements.candidates == %{}
    send(rig.direct, :release)
    await_idle(rig.opts)
    refute Store.find({rig.old, rig.scope})
    refute Store.find({rig.landing, rig.scope})
    assert Store.ops_count(rig.scope) == 0
    assert_settled(rig.scope)
  end

  test "a fresh generation discards waiting fallback bodies and keeps the new page", context do
    rig = start_overlap(context, Store, :failure, allow_retry: true)
    send(rig.redirected, :release)
    wait(fn -> assert Store.find_processed({rig.old, rig.scope}) end)
    assert {:ok, fresh} = start_crawl(rig.landing, %{rig.opts | force: true})
    await_idle(fresh)
    send(rig.direct, :release)
    assert %Page{body: "RETRY"} = Store.find_processed({rig.landing, rig.scope})
    assert Store.generation(rig.scope) == rig.opts.generation + 1
    assert Store.ops_count(rig.scope) == 1
    assert_settled(rig.scope)
  end

  defp start_overlap(context, store, result, extra \\ []) do
    scope = unique_scope("alias-overlap")
    old = context.url <> "/overlap/old"
    landing = context.url <> "/overlap/landing"
    observer = self()
    hits = :counters.new(1, [:atomics])

    ReqTestSite.expect_once(context.site, "GET", "/overlap/old", fn conn ->
      conn |> Plug.Conn.put_resp_header("location", landing) |> Plug.Conn.resp(302, "")
    end)

    ReqTestSite.expect(context.site, "GET", "/overlap/landing", fn conn ->
      landing_response(conn, hits, result, extra, observer)
    end)

    assert {:ok, opts} =
             start_crawl(
               landing,
               Keyword.merge(
                 [
                   scope: scope,
                   workers: 2,
                   max_pages: 2,
                   retries: 0,
                   parser: GatedParser,
                   gated_url: old,
                   landing_url: landing,
                   observer: observer,
                   store: store,
                   req_options: context.req_options
                 ],
                 extra
               )
             )

    on_exit(fn -> Crawler.stop(opts) end)
    assert_receive {:landing_request, direct}, 2_000
    on_exit(fn -> send(direct, :release) end)
    assert {:ok, _redirect} = start_crawl(old, opts)
    assert_receive {:parsed, redirected}, 2_000
    on_exit(fn -> send(redirected, :release) end)

    %{
      opts: opts,
      scope: scope,
      old: old,
      landing: landing,
      direct: direct,
      redirected: redirected,
      hits: hits
    }
  end

  defp landing_response(conn, hits, result, extra, observer) do
    conn = Plug.Conn.put_resp_header(conn, "content-type", "text/plain")
    :counters.add(hits, 1, 1)

    case :counters.get(hits, 1) do
      1 -> held_response(conn, result, observer)
      2 -> Plug.Conn.resp(conn, 200, "REDIRECT")
      _ -> later_response(conn, extra)
    end
  end

  defp held_response(conn, result, observer) do
    send(observer, {:landing_request, self()})

    receive do
      :release ->
        if result == :success,
          do: Plug.Conn.resp(conn, 200, "DIRECT"),
          else: Plug.Conn.resp(conn, 500, "FAILED")
    end
  end

  defp later_response(conn, extra) do
    cond do
      extra[:multiple_redirects] -> Plug.Conn.resp(conn, 200, "REDIRECT")
      extra[:allow_retry] -> Plug.Conn.resp(conn, 200, "RETRY")
      true -> flunk("a successful landing was fetched again")
    end
  end

  defp assert_settled(scope) do
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
    assert :sys.get_state(Store).settlements.candidates == %{}
  end
end
