defmodule Crawler.QueueFailureTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  test "a feeder crash releases shared work and preserves completed pages", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    parent = self()
    owner_scope = unique_scope("queue-crash-owner")
    guest_scope = unique_scope("queue-crash-guest")
    owner_page = "#{url}/queue-crash/owner"
    guest_page = "#{url}/queue-crash/guest"
    kept_page = "#{url}/queue-crash/kept"
    {:ok, requests} = Agent.start_link(fn -> 0 end)

    ReqTestSite.expect_once(site, "GET", "/queue-crash/owner", fn conn ->
      block_request(conn, parent, :owner)
    end)

    ReqTestSite.expect_once(site, "GET", "/queue-crash/kept", fn conn ->
      Plug.Conn.resp(conn, 200, "kept")
    end)

    ReqTestSite.expect(site, "GET", "/queue-crash/guest", fn conn ->
      count = Agent.get_and_update(requests, fn count -> {count, count + 1} end)

      if count == 0 do
        block_request(conn, parent, :guest)
      else
        Plug.Conn.resp(conn, 200, "recovered")
      end
    end)

    {:ok, owner} =
      start_crawl(owner_page,
        scope: owner_scope,
        workers: 3,
        timeout: 10_000,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    on_exit(fn ->
      Crawler.stop(owner)
      Store.drop_scope(guest_scope)
    end)

    assert_receive {:blocked, :owner, owner_handler}, 2_000
    on_exit(fn -> send(owner_handler, :release) end)

    {:ok, guest} =
      start_crawl(kept_page,
        scope: guest_scope,
        queue: owner[:queue],
        retries: 0,
        store: Store,
        req_options: req_options
      )

    wait(fn ->
      assert Store.find_processed({kept_page, guest_scope})
      assert Store.pending_count(guest_scope) == 0
    end)

    {:ok, guest} = start_crawl(guest_page, guest)
    assert_receive {:blocked, :guest, guest_handler}, 2_000
    on_exit(fn -> send(guest_handler, :release) end)

    assert Store.inflight_count(owner_scope) == 1
    assert Store.inflight_count(guest_scope) == 1
    assert Store.pending_count(owner_scope) == 1
    assert Store.pending_count(guest_scope) == 1

    {:links, links} = Process.info(owner[:queue_owner], :links)
    supervisor = Process.whereis(Crawler.QueueSupervisor)
    children = links -- [supervisor]

    monitors =
      [owner[:queue_owner], owner_handler, guest_handler | children]
      |> Enum.uniq()
      |> Enum.map(fn pid -> {pid, Process.monitor(pid)} end)

    Process.exit(owner[:queue], :kill)

    Enum.each(monitors, fn {pid, ref} ->
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
      refute Process.alive?(pid)
    end)

    assert Process.alive?(supervisor)
    assert Store.queue_record(owner[:queue]) == nil
    refute Process.whereis(:"opq-#{inspect(owner[:queue])}")
    assert Store.inflight_count(owner_scope) == 0
    assert Store.inflight_count(guest_scope) == 0
    assert Store.pending_count(owner_scope) == 0
    assert Store.pending_count(guest_scope) == 0
    assert Store.ops_count(guest_scope) == 1
    assert Store.generation(owner_scope) == owner[:generation] + 1
    assert Store.generation(guest_scope) == guest[:generation] + 1
    refute Store.find({owner_page, owner_scope})
    refute Store.find({guest_page, guest_scope})
    assert %Store.Page{body: "kept"} = Store.find_processed({kept_page, guest_scope})
    refute Crawler.running?(owner)
    refute Crawler.running?(guest)

    {:ok, again} =
      start_crawl(guest_page,
        scope: guest_scope,
        workers: 1,
        max_pages: 2,
        retries: 0,
        store: Store,
        req_options: req_options
      )

    on_exit(fn -> Crawler.stop(again) end)
    assert again[:queue] != owner[:queue]

    wait(fn ->
      refute Crawler.running?(again)
      assert %Store.Page{body: "recovered"} = Store.find_processed({guest_page, guest_scope})
    end)

    assert Store.find_processed({kept_page, guest_scope})
    assert Store.ops_count(guest_scope) == 2
    assert Agent.get(requests, & &1) == 2
  end

  defp block_request(conn, parent, scope) do
    send(parent, {:blocked, scope, self()})

    receive do
      :release -> Plug.Conn.resp(conn, 200, "released")
    end
  end
end
