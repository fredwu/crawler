defmodule Crawler.CookieOutcomeIntegrationTest do
  use ExUnit.Case, async: false

  alias Crawler.Fetcher.Requester
  alias Crawler.Store

  test "every canonical cookie cap has a public redacted latest-save outcome" do
    for {key, value, headers} <- [
          {:max_cookies, 1, ["a=secret; Path=/", "b=secret; Path=/"]},
          {:max_cookies_per_site, 1, ["a=secret; Path=/", "b=secret; Path=/"]},
          {:max_cookie_bytes, 16, ["id=" <> String.duplicate("secret", 10)]},
          {:max_cookie_jar_bytes, 1, ["id=secret; Path=/"]},
          {:max_cookie_updates, 1, ["a=secret; Path=/", "b=secret; Path=/"]}
        ] do
      scope = make_ref()
      on_exit(fn -> Store.dispose_scope(scope) end)
      generation = Store.generation(scope)
      name = {__MODULE__, make_ref()}

      Req.Test.stub(name, fn conn ->
        Plug.Conn.send_resp(
          %{conn | resp_headers: Enum.map(headers, &{"set-cookie", &1})},
          200,
          "ok"
        )
      end)

      opts =
        Crawler.Options.assign_defaults(%{
          scope: scope,
          generation: generation,
          url: "https://cookie-outcome.test/",
          respect_robots: false,
          req_options: [plug: {Req.Test, name}]
        })
        |> Map.put(key, value)

      assert {:ok, prepared} = Requester.prepare(opts)
      assert {:ok, _} = Requester.send(prepared)

      before =
        :sys.get_state(Store) |> Map.take([:scopes, :cookies, :cookie_outcomes, :cookie_bytes])

      assert {:ok, %{status: :limited, limits: limits} = outcome} = Crawler.cookie_outcome(opts)
      assert key in limits
      refute inspect(outcome) =~ "secret"
      assert {:ok, ^outcome} = Crawler.cookie_outcome(opts)
      assert {:ok, ^outcome} = Crawler.cookie_outcome(Map.put(opts, :execution_lease, make_ref()))

      assert before ==
               :sys.get_state(Store)
               |> Map.take([:scopes, :cookies, :cookie_outcomes, :cookie_bytes])

      assert :sys.get_state(Store).scopes[scope].reported_limit == {:limit, hd(limits)}

      assert :ok =
               Store.save_cookies(
                 scope,
                 opts.url,
                 ["ok=1; Path=/"],
                 generation,
                 Crawler.Cookies.limits()
               )

      assert {:ok, %{status: :ok}} = Crawler.cookie_outcome(opts)
      assert :sys.get_state(Store).scopes[scope].reported_limit == {:limit, hd(limits)}
      assert :sys.get_state(Store).scopes[scope].outcome == :open
      Store.drop_scope(scope)
      assert Crawler.cookie_outcome(opts) == {:error, :stale}
      assert Crawler.cookie_outcome(%{scope: scope}) == {:ok, nil}
    end
  end

  for entry <- [:direct, :queued] do
    test "#{entry} fetch preserves a cookie funding limit with nonzero outer retries" do
      scope = make_ref()
      on_exit(fn -> Store.dispose_scope(scope) end)
      name = {__MODULE__, make_ref()}
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      Req.Test.set_req_test_to_shared()
      on_exit(fn -> Req.Test.set_req_test_to_private() end)

      Req.Test.stub(name, fn conn ->
        number = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})

        conn =
          if number == 1,
            do: Plug.Conn.put_resp_header(conn, "set-cookie", "id=first; Path=/"),
            else: conn

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/plain")
        |> Plug.Conn.send_resp(200, "response #{number}")
      end)

      opts =
        Crawler.Options.assign_defaults(%{
          scope: scope,
          url: "https://cookie-outcome.test/funding",
          respect_robots: false,
          max_cookie_bytes: 10_000_000,
          retries: 2,
          req_options: [plug: {Req.Test, name}, retry: false]
        })

      case unquote(entry) do
        :direct ->
          assert Crawler.Fetcher.fetch(opts) == {:error, {:limit, :max_retained_bytes}}

        :queued ->
          assert {:ok, admitted} = Crawler.crawl(opts.url, opts)
          on_exit(fn -> Crawler.stop(admitted) end)

          await(fn ->
            assert %{status: :limited, reason: {:limit, :max_retained_bytes}} =
                     Store.target_outcome(admitted.target_handle)

            assert Store.pending_count(scope) == 0
          end)
      end

      assert Agent.get(calls, & &1) == 1
      assert :sys.get_state(Store).cookies[scope] == nil
      assert :sys.get_state(Store).cookie_outcomes[scope] == nil
    end
  end

  test "an unbound read creates no scope, jar or outcome" do
    scope = make_ref()
    before = :sys.get_state(Store)
    assert Crawler.cookie_outcome(%{scope: scope}) == {:ok, nil}
    after_read = :sys.get_state(Store)

    for key <- [:scopes, :cookies, :cookie_outcomes, :cookie_bytes] do
      assert Map.fetch!(after_read, key) == Map.fetch!(before, key)
    end
  end

  test "queue retirement rejects only that queue's read authority" do
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)

    {:links, previous} = Process.info(self(), :links)
    {:ok, queue} = OPQ.init(worker: Crawler.Dispatcher.Worker, workers: 1, timeout: 5_000)
    {:links, current} = Process.info(self(), :links)
    children = current -- previous
    Enum.each(children, &Process.unlink/1)

    on_exit(fn ->
      Enum.each(children, fn pid -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    end)

    OPQ.pause(queue)
    assert {:paused, _, _} = OPQ.info(queue)

    assert {:ok, opts} =
             Crawler.crawl("https://cookie-outcome.test/",
               scope: scope,
               queue: queue,
               respect_robots: false
             )

    assert :ok =
             Store.save_cookies(
               scope,
               "https://cookie-outcome.test/",
               ["id=value; Path=/"],
               opts.generation
             )

    assert {:ok, sibling} =
             Crawler.crawl("https://cookie-outcome.test/sibling",
               scope: scope,
               queue: self(),
               respect_robots: false
             )

    assert {:ok, outcome} = Crawler.cookie_outcome(opts)
    Process.exit(queue, :kill)
    assert Crawler.cookie_outcome(opts) == {:error, :stale}
    assert Crawler.cookie_outcome(sibling) == {:ok, outcome}
    assert Crawler.cookie_outcome(%{scope: scope, generation: opts.generation}) == {:ok, outcome}
  end

  defp await(check, attempts \\ 200)

  defp await(check, attempts) when attempts > 0 do
    try do
      check.()
    rescue
      ExUnit.AssertionError ->
        receive do
        after
          5 -> :ok
        end

        await(check, attempts - 1)
    end
  end

  defp await(check, 0), do: check.()
end
