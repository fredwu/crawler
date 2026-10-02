defmodule Crawler.StoreQueueCleanupTest do
  use Crawler.TestCase, async: false

  alias Crawler.Fetcher
  alias Crawler.Options
  alias Crawler.Store
  alias Crawler.Store.Page

  for event <- [:finish, :retire] do
    test "queue #{event} preserves a direct fetch registration and body", context do
      exercise_direct_fetch(unquote(event), context)
    end
  end

  defp exercise_direct_fetch(event, %{site: site, url: url, req_options: req_options}) do
    parent = self()
    scope = unique_scope("direct-fetch-#{event}")
    generation = Store.generation(scope)
    key = {url <> "/direct-fetch", scope}
    on_exit(fn -> Store.drop_scope(scope) end)

    ReqTestSite.expect_once(site, "GET", "/direct-fetch", fn conn ->
      send(parent, {:direct_fetch_started, self()})

      receive do
        :release -> Plug.Conn.resp(conn, 200, "DIRECT BODY")
      end
    end)

    opts =
      Options.assign_defaults(%{
        url: elem(key, 0),
        scope: scope,
        generation: generation,
        store: Store,
        retries: 0,
        req_options: req_options
      })

    fetch = Task.async(fn -> Fetcher.fetch(opts) end)
    assert_receive {:direct_fetch_started, handler}, 2_000
    on_exit(fn -> send(handler, :release) end)
    assert %Page{body: nil, processed: nil} = Store.find(key)

    exercise_queue_cleanup(event, scope, generation, url)
    assert %Page{body: nil} = Store.find(key)
    assert Store.generation(scope) == generation
    assert Store.current?(scope, generation)
    send(handler, :release)
    assert %Page{body: "DIRECT BODY"} = Task.await(fetch)
    stored = Store.find(key)
    assert %Page{body: "DIRECT BODY", processed: nil} = stored

    exercise_queue_cleanup(event, scope, generation, url)
    assert Store.find(key) == stored
    assert Store.generation(scope) == generation
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
    assert Store.ops_count(scope) == 0
  end

  defp exercise_queue_cleanup(event, scope, generation, url) do
    queue =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(queue, :kill) end)
    suffix = System.unique_integer([:positive])
    failed = {url <> "/failed-#{suffix}", scope}
    kept = {url <> "/kept-#{suffix}", scope}

    assert :ok = Store.note_enqueued(scope, generation, queue)
    assert :ok = Store.try_claim(scope, :infinity, generation, queue)
    assert {:ok, _} = Store.add(failed, generation, queue)
    assert {:ok, _} = Store.add(kept, generation, queue)
    Store.processed(kept, generation, queue)

    case event do
      :finish -> assert :ok = Store.finish_work(scope, generation, true, queue)
      :retire -> assert :ok = Store.release_queue(queue)
    end

    refute Store.find(failed)
    assert Store.find_processed(kept)
    assert Store.pending_count(scope) == 0
    assert Store.inflight_count(scope) == 0
    assert {:ok, _} = Store.add(failed, generation)
  end
end
