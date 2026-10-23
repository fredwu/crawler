defmodule Crawler.QueueOwnerAuthorityTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  for target <- [:creator, :other] do
    test "copied options borrowing the #{target} queue cannot stop either creator", context do
      exercise_copied_options(unquote(target), context)
    end
  end

  test "stale stop preserves a held successor on the same owned queue", context do
    scope = unique_scope("stale-owned-stop")
    old_url = context.url <> "/authority/old-stop"
    fresh_url = context.url <> "/authority/fresh-stop"

    for {path, body} <- [{"/authority/old-stop", "OLD"}, {"/authority/fresh-stop", "FRESH"}] do
      ReqTestSite.expect_once(context.site, "GET", path, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.resp(200, body)
      end)
    end

    old = crawl(old_url, scope, context.req_options)
    await_idle(old)
    assert Store.find_processed({old_url, scope}).body == "OLD"

    assert {:ok, fresh} =
             start_crawl(
               fresh_url,
               Map.merge(old, %{
                 force: true,
                 parser: Crawler.HeldParser,
                 hold_parser_url: fresh_url,
                 parser_observer: self()
               })
             )

    assert_receive {:parser_held, worker, _page}, 2_000
    on_exit(fn -> send(worker, :release_parser) end)
    assert fresh.queue == old.queue
    assert fresh.queue_owner == old.queue_owner
    refute fresh.generation == old.generation
    page = Store.find({fresh_url, scope})
    assert page.body == "FRESH"
    assert :stale = Store.dispose_scope(scope, old.generation)
    assert :stale = Store.dispose_scope(scope, nil)
    assert :ok = Crawler.stop(old)
    assert Store.current?(scope, fresh.generation, fresh.queue)
    assert Store.find({fresh_url, scope}) == page
    assert Process.alive?(worker)
    assert Process.alive?(fresh.queue)
    assert Process.alive?(fresh.queue_owner)
    assert Store.target_outcome(fresh.target_handle) == nil
    send(worker, :release_parser)
    await_idle(fresh)
    assert Store.find_processed({fresh_url, scope}).body == "FRESH"
    assert Store.ops_count(scope) == 1
    assert :ok = Crawler.stop(fresh)
    refute Store.current?(scope, fresh.generation)
    refute Store.find({fresh_url, scope})
    refute Process.alive?(fresh.queue)
    refute Process.alive?(fresh.queue_owner)
  end

  test "exact generation disposal removes a deadline-limited scope" do
    scope = unique_scope("limited-scope-disposal")
    on_exit(fn -> Store.dispose_scope(scope) end)
    bound = Store.bind_run(scope: scope, run_timeout: 1)

    wait(fn ->
      assert :sys.get_state(Store).scopes[scope].outcome == {:limited, {:deadline, :run}}
    end)

    refute Store.current?(scope, bound.generation)
    assert :ok = Store.dispose_scope(scope, bound.generation)
    refute Map.has_key?(:sys.get_state(Store).scopes, scope)
  end

  defp exercise_copied_options(target, %{site: site, url: url, req_options: req_options}) do
    parent = self()
    creator_scope = System.unique_integer([:positive])
    guest_scope = creator_scope * 1.0
    other_scope = unique_scope("other-queue-creator")
    install_blocked_route(site, parent, "/authority/creator", :creator)
    install_blocked_route(site, parent, "/authority/other", :other)
    install_blocked_route(site, parent, "/authority/guest", :guest)

    ReqTestSite.expect_once(site, "GET", "/authority/guest-progress", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "guest progress")
    end)

    creator = crawl(url <> "/authority/creator", creator_scope, req_options)
    other = crawl(url <> "/authority/other", other_scope, req_options)
    assert_receive {:blocked, :creator, creator_handler}, 2_000
    assert_receive {:blocked, :other, other_handler}, 2_000
    on_exit(fn -> send(creator_handler, :release) end)
    on_exit(fn -> send(other_handler, :release) end)
    queue = if target == :creator, do: creator[:queue], else: other[:queue]
    copied = creator |> Map.put(:scope, guest_scope) |> Map.put(:queue, queue)
    assert copied[:queue_owner] == creator[:queue_owner]
    assert {:ok, guest} = start_crawl(url <> "/authority/guest", copied)
    assert_receive {:blocked, :guest, guest_handler}, 2_000
    on_exit(fn -> send(guest_handler, :release) end)

    assert :ok = Crawler.stop(copied)
    assert Store.current?(guest_scope, guest.generation, guest.queue)
    assert Store.find({url <> "/authority/guest", guest_scope})
    assert :ok = Crawler.stop(guest)
    assert Process.alive?(creator[:queue])
    assert Process.alive?(creator[:queue_owner])
    assert Process.alive?(other[:queue])
    assert Process.alive?(other[:queue_owner])
    assert guest[:queue_owner] == nil
    assert Store.generation(creator_scope) == creator[:generation]
    refute Store.generation(guest_scope) == guest[:generation]
    refute Store.current?(guest_scope, guest[:generation])
    assert Store.inflight_count(creator_scope) == 1
    assert Store.inflight_count(other_scope) == 1
    assert Store.find({url <> "/authority/creator", creator_scope})
    assert Store.find({url <> "/authority/other", other_scope})
    refute Store.find({url <> "/authority/guest", guest_scope})
    send(guest_handler, :release)

    fresh = Map.put(copied, :generation, Store.generation(guest_scope))
    assert {:ok, progress} = start_crawl(url <> "/authority/guest-progress", fresh)
    assert progress[:queue] == queue
    assert progress[:queue_owner] == nil
    await_idle(progress)
    assert Store.find_processed({url <> "/authority/guest-progress", guest_scope})
    assert :ok = Crawler.stop(progress)
    assert Process.alive?(queue)
    assert Store.inflight_count(creator_scope) == 1
    assert Store.inflight_count(other_scope) == 1

    send(creator_handler, :release)
    send(other_handler, :release)
    await_idle(creator)
    await_idle(other)
    assert Store.find_processed({url <> "/authority/creator", creator_scope})
    assert Store.find_processed({url <> "/authority/other", other_scope})

    assert :ok = Crawler.stop(%{queue: creator[:queue], scope: creator_scope})
    refute Process.alive?(creator[:queue])
    refute Process.alive?(creator[:queue_owner])
    assert Process.alive?(other[:queue])
    assert Store.find_processed({url <> "/authority/other", other_scope})
    assert :ok = Crawler.stop(%{queue: other[:queue], scope: other_scope})
    refute Process.alive?(other[:queue])
  end

  defp crawl(page, scope, req_options) do
    assert {:ok, opts} =
             start_crawl(page,
               scope: scope,
               workers: 2,
               max_body: 1_024,
               max_analysis_bytes: 2_097_152,
               store: Store,
               retries: 0,
               req_options: req_options
             )

    opts
  end

  defp install_blocked_route(site, parent, path, tag) do
    ReqTestSite.expect_once(site, "GET", path, fn conn ->
      send(parent, {:blocked, tag, self()})

      receive do
        :release ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "text/html")
          |> Plug.Conn.resp(200, path)
      end
    end)
  end
end
