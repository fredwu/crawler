defmodule Crawler.CrawlSnapshotPublishTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  @utf8_bom <<0xEF, 0xBB, 0xBF>>

  test "a slower save loses when a newer fetch of the same page finishes first", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("lifecycle-slow-save")
    page = "#{url}/lifecycle/slow-save"
    directory = "lifecycle-slow-save-#{System.unique_integer([:positive])}"
    file = offline(directory, site, "/lifecycle/slow-save")
    {:ok, hits} = Agent.start_link(fn -> 0 end)
    before_publish = hold_save()

    ReqTestSite.stub(site, "GET", "/lifecycle/slow-save", fn conn ->
      count = Agent.get_and_update(hits, fn count -> {count, count + 1} end)
      body = if count == 0, do: "OLD", else: "NEW"

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, body)
    end)

    {:ok, _first} =
      start_crawl(page,
        scope: scope,
        workers: 1,
        retries: 0,
        store: Store,
        save_to: tmp(directory),
        before_publish: before_publish,
        req_options: req_options
      )

    assert_receive {:staged, holder}, 2_000

    {:ok, second} =
      start_crawl(page,
        scope: scope,
        force: true,
        workers: 1,
        retries: 0,
        store: Store,
        save_to: tmp(directory),
        req_options: req_options
      )

    wait(2_000, fn ->
      refute Crawler.running?(second)
      assert File.read!(file) == @utf8_bom <> "NEW"
      assert %Store.Page{body: "NEW"} = Store.find_processed({page, scope})
    end)

    assert Process.alive?(holder)
    send(holder, :release_save)

    wait(fn ->
      refute Process.alive?(holder)
      assert File.read!(file) == @utf8_bom <> "NEW"
      assert %Store.Page{body: "NEW"} = Store.find_processed({page, scope})
    end)
  end

  test "concurrent saves of one path keep one complete body", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    page = "#{url}/lifecycle/bodies"
    scope_a = unique_scope("lifecycle-body-a")
    scope_b = unique_scope("lifecycle-body-b")
    directory = "lifecycle-bodies-#{System.unique_integer([:positive])}"
    file = offline(directory, site, "/lifecycle/bodies")
    {:ok, hits} = Agent.start_link(fn -> 0 end)
    before_publish = hold_save()

    ReqTestSite.stub(site, "GET", "/lifecycle/bodies", fn conn ->
      count = Agent.get_and_update(hits, fn count -> {count, count + 1} end)

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "BODY-#{count}")
    end)

    crawl = fn scope ->
      start_crawl(page,
        scope: scope,
        workers: 1,
        retries: 0,
        store: Store,
        save_to: tmp(directory),
        before_publish: before_publish,
        req_options: req_options
      )
    end

    {:ok, first} = crawl.(scope_a)
    {:ok, second} = crawl.(scope_b)
    assert first[:queue] != second[:queue]

    assert_receive {:staged, holder_a}, 2_000
    assert_receive {:staged, holder_b}, 2_000
    refute File.exists?(file)

    send(holder_a, :release_save)
    send(holder_b, :release_save)

    wait(2_000, fn ->
      refute Crawler.running?(first)
      refute Crawler.running?(second)
      refute Process.alive?(holder_a)
      refute Process.alive?(holder_b)

      assert %Store.Page{body: body_a} = Store.find_processed({page, scope_a})
      assert %Store.Page{body: body_b} = Store.find_processed({page, scope_b})
      assert body_a != body_b
      assert body_a in ["BODY-0", "BODY-1"]
      assert body_b in ["BODY-0", "BODY-1"]
      assert File.read!(file) in [@utf8_bom <> body_a, @utf8_bom <> body_b]
    end)
  end

  test "stopping a crawl during a save removes its temp file", %{
    site: site,
    url: url,
    req_options: req_options
  } do
    scope = unique_scope("lifecycle-stop-save")
    page = "#{url}/lifecycle/stop-save"
    directory = "lifecycle-stop-save-#{System.unique_integer([:positive])}"
    file = offline(directory, site, "/lifecycle/stop-save")
    dir = Path.dirname(file)
    before_publish = hold_save()

    ReqTestSite.stub(site, "GET", "/lifecycle/stop-save", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "PARTIAL")
    end)

    {:ok, opts} =
      start_crawl(page,
        scope: scope,
        workers: 1,
        retries: 0,
        store: Store,
        save_to: tmp(directory),
        before_publish: before_publish,
        req_options: req_options
      )

    assert_receive {:staged, _holder}, 2_000
    assert File.dir?(dir)
    assert Enum.any?(File.ls!(dir), &String.ends_with?(&1, ".tmp"))

    assert :ok = Crawler.stop(opts)

    wait(2_000, fn ->
      refute Process.alive?(opts[:queue])
      assert Enum.filter(File.ls!(dir), &String.ends_with?(&1, ".tmp")) == []
    end)

    refute File.exists?(file)
    refute Store.find({page, scope})
  end

  defp offline(directory, site, path) do
    tmp("#{directory}/#{site.path}#{path}", "__index.html")
  end

  defp hold_save do
    parent = self()
    {:ok, holders} = Agent.start(fn -> [] end)

    on_exit(fn ->
      if Process.alive?(holders) do
        holders |> Agent.get(& &1) |> Enum.each(&send(&1, :release_save))
        Agent.stop(holders)
      end
    end)

    fn ->
      holder = self()
      Agent.update(holders, &[holder | &1])
      send(parent, {:staged, holder})

      receive do
        :release_save -> :ok
      after
        5_000 -> :ok
      end
    end
  end
end
