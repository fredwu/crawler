defmodule Crawler.QueueOwnerAuthorityTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  for target <- [:creator, :other] do
    test "copied options borrowing the #{target} queue cannot stop either creator", context do
      exercise_copied_options(unquote(target), context)
    end
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
