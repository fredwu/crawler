defmodule Crawler.RedirectAliasRetryTest do
  use Crawler.TestCase, async: false

  alias Crawler.Store

  defmodule TransientStore do
    def add_page_data({url, scope}, _body, opts) do
      if url == opts[:landing_url] do
        :counters.add(opts[:storage_attempts], 1, 1)

        if :counters.get(opts[:storage_attempts], 1) == 1 do
          send(opts[:storage_owner], {:alias_write_failed, scope})
          {:error, :temporary}
        else
          :ok
        end
      else
        :ok
      end
    end
  end

  test "a same-canonical redirect keeps its requested key protected through a storage retry",
       context do
    scope = unique_scope("redirect-alias-retry")
    requested = "#{context.url}/retry/page"
    landing = requested <> "/"
    storage_attempts = :counters.new(1, [:atomics])
    requests = :counters.new(2, [:atomics])
    serve_redirect(context, landing, requests)

    {:ok, opts} =
      start_crawl(requested,
        workers: 1,
        retries: 1,
        scope: scope,
        store: TransientStore,
        storage_owner: self(),
        storage_attempts: storage_attempts,
        landing_url: landing,
        req_options: context.req_options
      )

    on_exit(fn -> Crawler.stop(opts) end)
    assert_receive {:alias_write_failed, ^scope}, 5_000
    assert_receive {:retry_started, retry_request}, 5_000

    try do
      assert {:ok, :skip} = Store.register_alias({landing, scope}, opts.generation, opts.queue)
    after
      send(retry_request, :resume)
    end

    await_idle(opts)
    assert Store.find_processed({requested, scope})
    assert Store.find_processed({landing, scope})
    assert Store.ops_count(scope) == 1
    assert :counters.get(storage_attempts, 1) == 2
    assert :counters.get(requests, 1) == 2
    assert :counters.get(requests, 2) == 2
  end

  defp serve_redirect(context, landing, requests) do
    parent = self()

    ReqTestSite.expect(context.site, "GET", "/retry/page", fn conn ->
      :counters.add(requests, 1, 1)

      if :counters.get(requests, 1) == 2 do
        send(parent, {:retry_started, self()})

        receive do
          :resume -> :ok
        end
      end

      conn
      |> Plug.Conn.put_resp_header("location", landing)
      |> Plug.Conn.resp(302, "")
    end)

    ReqTestSite.expect(context.site, "GET", "/retry/page/", fn conn ->
      :counters.add(requests, 2, 1)

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "RECOVERED")
    end)
  end
end
