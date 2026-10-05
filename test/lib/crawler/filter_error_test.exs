defmodule Crawler.FilterErrorTest do
  use Crawler.TestCase, async: false

  alias Crawler.Fetcher
  alias Crawler.Fetcher.Policer
  alias Crawler.Options
  alias Crawler.Store
  alias Crawler.Store.Page

  @secret "private-filter-token"
  @userinfo "private-filter-user:private-filter-password"
  @private "private-filter-option"

  defmodule ConfiguredFilter do
    @behaviour Crawler.Fetcher.UrlFilter.Spec

    def filter(url, opts) do
      send(opts[:observer], {:filtered, url, opts[:filter_result]})
      opts[:filter_result]
    end
  end

  defmodule RaisingFilter do
    @behaviour Crawler.Fetcher.UrlFilter.Spec

    def filter(_url, opts), do: raise(opts[:filter_exception])
  end

  setup context do
    scope = unique_scope("filter-error")
    requests = :counters.new(1, [:atomics])
    on_exit(fn -> Store.drop_scope(scope) end)

    ReqTestSite.stub(context.site, "GET", "/filter-error", fn conn ->
      :counters.add(requests, 1, 1)

      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.resp(200, "FILTER RETRY BODY")
    end)

    url =
      (context.url <> "/filter-error")
      |> URI.parse()
      |> Map.put(:userinfo, @userinfo)
      |> URI.to_string()

    opts =
      Options.assign_defaults(%{
        url: url,
        scope: scope,
        observer: self(),
        url_filter: ConfiguredFilter,
        filter_result: {:error, :filter_unavailable},
        private_filter_option: @private,
        workers: 1,
        max_pages: 1,
        retries: 2,
        store: Store,
        req_options: Keyword.put(context.req_options, :auth, {:bearer, @secret})
      })

    {:ok, opts: opts, requests: requests}
  end

  test "police and fetch preserve every tagged filter error without recording or HTTP", %{
    opts: opts,
    requests: requests
  } do
    reasons = [
      true,
      false,
      nil,
      :filter_unavailable,
      {:filter_unavailable, @secret},
      private_reason(opts)
    ]

    Enum.each(reasons, fn reason ->
      opts = %{opts | filter_result: {:error, reason}}

      assert {:error, ^reason} = Policer.police(opts)
      assert {:error, ^reason} = Fetcher.fetch(opts)
      refute Store.find({opts.url, opts.scope})
      assert Store.ops_count(opts.scope) == 0
    end)

    assert :counters.get(requests, 1) == 0
  end

  test "filter rejection remains a safe policy warning", %{opts: opts, requests: requests} do
    opts = %{opts | filter_result: {:ok, false}}

    assert {:warn, message} = Policer.police(opts)
    assert message =~ "Fetch failed check 'perform_url_filtering'"
    assert {:warn, ^message} = Fetcher.fetch(opts)
    assert_private(message)
    refute Store.find({opts.url, opts.scope})
    assert :counters.get(requests, 1) == 0
  end

  test "callback programming exceptions and invalid results remain exceptions", %{
    opts: opts,
    requests: requests
  } do
    exception = ArgumentError.exception(@secret)
    raising = Map.merge(opts, %{url_filter: RaisingFilter, filter_exception: exception})

    assert_raise ArgumentError, @secret, fn -> Policer.police(raising) end
    assert_raise ArgumentError, @secret, fn -> Fetcher.fetch(raising) end

    invalid = %{opts | filter_result: {:ok, :invalid}}
    assert_raise CaseClauseError, fn -> Policer.police(invalid) end
    assert_raise CaseClauseError, fn -> Fetcher.fetch(invalid) end
    assert :counters.get(requests, 1) == 0
  end

  test "the real worker returns the callback reason and settles without exposing it", %{
    opts: opts,
    requests: requests
  } do
    reason = private_reason(opts)
    opts = %{opts | filter_result: {:error, reason}}

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert {:error, ^reason} = Crawler.crawl_now(opts)
      end)

    assert log =~ "Crawl failed"
    refute log =~ "Worker failed"
    assert_private(log)
    assert_failed_settlement(opts, requests)
  end

  test "the real worker keeps programming exceptions distinct and private", %{
    opts: opts,
    requests: requests
  } do
    exception = ArgumentError.exception(@secret)
    opts = Map.merge(opts, %{url_filter: RaisingFilter, filter_exception: exception})

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert {:error, {:error, ^exception}} = Crawler.crawl_now(opts)
      end)

    assert log =~ "Worker failed"
    assert log =~ "ArgumentError"
    assert_private(log)
    assert_failed_settlement(opts, requests)
  end

  test "a queued filter error releases its page slot and permits a successful retry", %{
    opts: opts,
    requests: requests
  } do
    reason = private_reason(opts)
    opts = %{opts | filter_result: {:error, reason}}

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        assert {:ok, crawl} = start_crawl(opts.url, opts)
        assert_receive {:filtered, url, {:error, ^reason}}, 2_000
        assert url == opts.url
        await_idle(crawl)
        assert_failed_settlement(crawl, requests)
        assert Process.alive?(crawl.queue)
        assert Process.alive?(crawl.queue_owner)

        assert {:ok, retry} = start_crawl(opts.url, %{crawl | filter_result: {:ok, true}})
        await_idle(retry)
        assert %Page{body: "FILTER RETRY BODY"} = Store.find_processed({opts.url, opts.scope})
        assert Store.ops_count(opts.scope) == 1
        assert Store.pending_count(opts.scope) == 0
        assert Store.inflight_count(opts.scope) == 0
        assert :counters.get(requests, 1) == 1
      end)

    assert log =~ "Crawl failed"
    refute log =~ "Worker failed"
    assert_private(log)
  end

  defp private_reason(opts), do: %{status: :unavailable, token: @secret, url: opts.url}

  defp assert_failed_settlement(opts, requests) do
    assert Store.pending_count(opts.scope) == 0
    assert Store.inflight_count(opts.scope) == 0
    assert Store.ops_count(opts.scope) == 0
    refute Store.find({opts.url, opts.scope})
    assert :counters.get(requests, 1) == 0
  end

  defp assert_private(text) do
    for secret <- [@secret, @userinfo, "private-filter-user", "private-filter-password", @private] do
      refute text =~ secret
    end

    refute text =~ "filter_result"
    refute text =~ "private_filter_option"
    refute text =~ "req_options"
  end
end
