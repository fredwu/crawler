defmodule Crawler.FetcherStoredAuthorityTest do
  use Crawler.TestCase, async: false

  alias Crawler.Fetcher
  alias Crawler.Options
  alias Crawler.Store
  alias Crawler.StoreGate

  defmodule HeldStore do
    def add_page_data(key, body, opts) do
      result = Crawler.Store.add_page_data(key, body, opts)
      send(opts.observer, {:custom_store_written, self()})

      receive do
        :continue_store -> result
      end
    end
  end

  defmodule HeldUpgradeFilter do
    def filter(_url, opts) do
      send(opts.observer, {:upgrade_admitted, self()})

      receive do
        :continue_upgrade -> {:ok, true}
      end
    end
  end

  for retirement <- [:reset, :queue_retirement] do
    test "response metadata cannot borrow replacement authority after #{retirement}", context do
      scope = unique_scope("response-metadata-authority")
      url = context.url <> "/response-metadata-authority"
      generation = Store.generation(scope)
      queue = self()
      Store.note_enqueued(scope, generation, queue)

      survivor =
        if unquote(retirement) == :queue_retirement, do: survivor_queue(scope, generation)

      on_exit(fn -> Store.dispose_scope(scope) end)

      ReqTestSite.expect_once(context.site, "GET", "/response-metadata-authority", fn conn ->
        conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, "OLD")
      end)

      opts =
        Map.merge(options(context, scope, generation, url), %{
          store: HeldStore,
          observer: self(),
          worker_base: url,
          queue: queue
        })

      old = Task.async(fn -> Fetcher.fetch(opts) end)
      assert_receive {:custom_store_written, worker}, 2_000
      gate = install_validation_gate(worker, scope, generation)
      send(worker, :continue_store)
      assert_receive {:store_call_held, ^worker, {:current?, ^scope, ^generation, _}}, 2_000

      fresh_generation =
        case unquote(retirement) do
          :reset ->
            Store.drop_scope(scope)

          :queue_retirement ->
            assert :ok = Store.release_queue(queue)
            assert Store.generation(scope) == generation
            generation
        end

      fresh =
        put_page(url, scope, fresh_generation, "FRESH", %{
          html_tag: "a",
          content_type: "text/html",
          referrer_url: url <> "/fresh",
          worker_base: url <> "/fresh-worker",
          alias_url: url <> "/fresh-alias",
          queue: survivor
        })

      StoreGate.resume(gate)
      assert {:warn, :stale} = Task.await(old)
      assert Store.find_processed({url, scope}) == fresh
    end
  end

  test "a stored document upgrade cannot take authority from its replacement page", context do
    scope = unique_scope("stored-upgrade-authority")
    url = context.url <> "/stored-upgrade-authority"
    generation = Store.generation(scope)
    on_exit(fn -> Store.dispose_scope(scope) end)
    put_page(url, scope, generation, "OLD SVG", %{html_tag: "img", content_type: "image/svg+xml"})

    opts =
      Map.merge(options(context, scope, generation, url), %{
        url_filter: HeldUpgradeFilter,
        observer: self()
      })

    old = Task.async(fn -> Fetcher.fetch(opts) end)
    assert_receive {:upgrade_admitted, worker}, 2_000
    gate = install_validation_gate(worker, scope, generation)
    send(worker, :continue_upgrade)
    assert_receive {:store_call_held, ^worker, {:current?, ^scope, ^generation, _}}, 2_000
    fresh_generation = Store.drop_scope(scope)

    fresh =
      put_page(url, scope, fresh_generation, "FRESH SVG", %{
        html_tag: "img",
        content_type: "image/svg+xml",
        referrer_url: url <> "/fresh"
      })

    StoreGate.resume(gate)
    assert {:error, :stale} = Task.await(old)
    assert Store.find_processed({url, scope}) == fresh
  end

  test "a surviving worker can upgrade a document whose stored queue has retired", context do
    scope = unique_scope("stored-retired-queue")
    generation = Store.generation(scope)
    queue = self()
    Store.note_enqueued(scope, generation, queue)
    survivor = survivor_queue(scope, generation)
    on_exit(fn -> Store.dispose_scope(scope) end)
    url = context.url <> "/stored-retired-queue"

    put_page(url, scope, generation, "<svg/>", %{
      html_tag: "img",
      content_type: "image/svg+xml",
      queue: queue
    })

    assert :ok = Store.release_queue(queue)
    assert Store.generation(scope) == generation
    opts = Map.put(options(context, scope, generation, url), :queue, survivor)
    assert %Store.Page{body: "<svg/>"} = Fetcher.fetch(opts)
    assert Store.find_processed({url, scope}).opts.html_tag == "a"
  end

  defp survivor_queue(scope, generation) do
    queue = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(queue, :kill) end)
    assert :ok = Store.note_enqueued(scope, generation, queue)
    queue
  end

  defp install_validation_gate(worker, scope, generation) do
    StoreGate.hold(worker, &match?({:current?, ^scope, ^generation, _}, &1))
  end

  defp put_page(url, scope, generation, body, metadata) do
    opts = Map.merge(%{url: url, scope: scope, generation: generation, queue: nil}, metadata)
    assert {:ok, _} = Store.add({url, scope}, generation)
    assert {_, _} = Store.add_page_data({url, scope}, body, opts)
    assert {_, _} = Store.processed({url, scope}, generation)
    Store.find_processed({url, scope})
  end

  defp options(context, scope, generation, url) do
    Options.assign_defaults(%{
      scope: scope,
      generation: generation,
      url: url,
      req_options: context.req_options,
      respect_robots: false,
      store: Store,
      retries: 0
    })
  end
end
