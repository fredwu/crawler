defmodule Crawler.Phase2.DirectIntegrationTest do
  use ExUnit.Case, async: false

  alias Crawler.Fetcher
  alias Crawler.Store
  alias Crawler.Store.Execution
  alias Crawler.Store.Page

  defmodule Parser do
    def parse(%Page{} = page) do
      send(page.opts.direct_observer, {:direct_parsed, page.body})
      {:ok, page}
    end
  end

  setup do
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)
    %{scope: scope}
  end

  test "direct compatible interpretations share one request without occupying waiting producer arenas",
       %{scope: scope} do
    owner = self()
    name = {__MODULE__, make_ref()}
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(name, fn conn ->
      Agent.update(calls, &(&1 + 1))
      send(owner, {:direct_transport, self()})

      receive do
        :continue -> :ok
      end

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/javascript")
      |> Plug.Conn.send_resp(200, "let x = 1;")
    end)

    opts = options(scope, plug: {Req.Test, name})
    script = Task.async(fn -> Fetcher.fetch(Map.put(opts, :javascript_goal, :script)) end)
    assert_receive {:direct_transport, executor}, 1_000
    module = Task.async(fn -> Fetcher.fetch(Map.put(opts, :javascript_goal, :module)) end)
    await(fn -> assert map_size(:sys.get_state(Store).direct_waiters) == 1 end)
    assert :sys.get_state(Store).resources.open_arenas == 1
    send(executor, :continue)
    assert %Page{body: "let x = 1;"} = Task.await(script)
    assert %Page{body: "let x = 1;"} = Task.await(module)
    assert Agent.get(calls, & &1) == 1
    assert Store.ops_count(scope) == 1

    await(fn ->
      state = :sys.get_state(Store)
      assert state.direct_waiters == %{}
      assert state.scheduler.claims == %{}
    end)
  end

  test "an active duplicate caller timeout does not cancel the shared owner", %{scope: scope} do
    owner = self()
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      send(owner, {:direct_transport, self()})

      receive do
        :continue -> :ok
      end

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/javascript")
      |> Plug.Conn.send_resp(200, "one")
    end)

    opts = options(scope, plug: {Req.Test, name})
    first = Task.async(fn -> Fetcher.fetch(opts) end)
    assert_receive {:direct_transport, executor}, 1_000
    duplicate = Task.async(fn -> Fetcher.fetch(%{opts | attempt_timeout: 60}) end)
    assert {:error, {:deadline, :attempt}} = Task.await(duplicate)
    assert Process.alive?(executor)
    assert map_size(:sys.get_state(Store).scheduler.claims) == 1
    send(executor, :continue)
    assert %Page{body: "one"} = Task.await(first)
    assert Store.ops_count(scope) == 1
    await(fn -> assert :sys.get_state(Store).direct_waiters == %{} end)
  end

  test "a direct cookie retry keeps its claim until the same executor can retry", %{scope: scope} do
    {opts, calls} = direct_retry_fixture(scope)
    store = Process.whereis(Store)
    retry = start_direct_retry(opts)
    assert_receive {:direct_retry_held, executor, owned}, 1_000
    target = owned.target_handle
    claim = owned.scheduler_claim

    state = :sys.get_state(store)
    assert state.scheduler.frontier.jobs[target].status == {:running, claim}
    assert state.scheduler.claims[claim].job == target
    assert state.scheduler_workers[claim].worker == executor
    refute Map.has_key?(state.direct_owners, target)
    refute Map.has_key?(state.scheduler.forks.members, target)
    assert Store.target_outcome(target) == nil
    assert Process.alive?(executor)

    assert :ok =
             Execution.run_job(%{opts | url: "https://direct.test/unrelated"}, fn _ -> :ok end)

    assert Process.whereis(Store) == store
    assert Process.alive?(store)

    await(fn ->
      state = :sys.get_state(store)
      assert state.scheduler.frontier.jobs[target].status == {:running, claim}
      assert Map.keys(state.scheduler.claims) == [claim]
      assert map_size(state.scheduler_monitors) == 1
      assert map_size(state.execution_monitors) == 1
    end)

    send(executor, :continue_retry)
    assert %Page{body: "id=B", opts: %{target_handle: ^target}} = Task.await(retry)
    assert_receive {:direct_retry_claimed, ^executor, retried, monitors}, 1_000
    assert retried.target_handle == target
    refute retried.scheduler_claim == claim
    assert retried.crawler_deadline == owned.crawler_deadline
    assert monitors == %{scheduler: 1, execution: 1, arenas: 1, dead_scratch: 0}
    assert %{status: :succeeded} = Store.target_outcome(target)

    assert Enum.reverse(Agent.get(calls, & &1)) == [
             {"/start", nil},
             {"/private", "id=A"},
             {"/start", nil},
             {"/private", "id=B"}
           ]

    assert_direct_retry_cleanup(scope)
  end

  for ending <- [:kill, :raise, :attempt_expiry] do
    test "a deferred direct retry terminates its target after #{ending}", %{scope: scope} do
      {opts, calls} = direct_retry_fixture(scope)
      retry = start_direct_retry(opts)
      assert_receive {:direct_retry_held, executor, owned}, 1_000
      target = owned.target_handle
      claim = owned.scheduler_claim
      assert :sys.get_state(Store).scheduler.frontier.jobs[target].status == {:running, claim}

      case unquote(ending) do
        :kill -> Process.exit(executor, :kill)
        :raise -> send(executor, :raise_retry)
        :attempt_expiry -> :ok
      end

      result = Task.await(retry)

      case unquote(ending) do
        :kill ->
          assert result == {:caught, :exit, :killed}

          await(fn ->
            assert %{status: :failed, reason: {:executor_down, :killed}} =
                     Store.target_outcome(target)
          end)

        :raise ->
          assert {:caught, :error, %RuntimeError{message: "deferred direct retry failed"}} =
                   result

          assert %{status: :failed, reason: {:callback, :error}} = Store.target_outcome(target)

        :attempt_expiry ->
          assert result == {:error, {:deadline, :attempt}}
          assert %{status: :limited, reason: {:deadline, :attempt}} = Store.target_outcome(target)
      end

      assert Enum.reverse(Agent.get(calls, & &1)) == [{"/start", nil}, {"/private", "id=A"}]
      refute_receive {:direct_retry_claimed, _, _, _}
      assert_direct_retry_cleanup(scope)
    end
  end

  test "a suspended observer cannot leave a deferred direct retry unowned", %{scope: scope} do
    {opts, _calls} = direct_retry_fixture(scope)
    retry = start_direct_retry(opts)
    assert_receive {:direct_retry_held, executor, owned}, 1_000
    monitor = Process.monitor(executor)
    assert :erlang.suspend_process(retry.pid)

    try do
      send(executor, :continue_retry)
      assert_receive {:direct_retry_claimed, ^executor, retried, _monitors}, 1_000
      assert retried.target_handle == owned.target_handle
      assert_receive {:DOWN, ^monitor, :process, ^executor, :normal}, 1_000
      assert %{status: :succeeded} = Store.target_outcome(owned.target_handle)

      receive do
      after
        Crawler.Deadline.remaining(owned.crawler_deadline) + 1 -> :ok
      end

      assert Crawler.Deadline.check(owned.crawler_deadline) == {:error, {:deadline, :attempt}}
      assert %{status: :succeeded} = Store.target_outcome(owned.target_handle)
    after
      if Process.alive?(retry.pid), do: :erlang.resume_process(retry.pid)
    end

    assert Task.await(retry) == {:error, {:deadline, :attempt}}
    assert_direct_retry_cleanup(scope)
  end

  test "raw crawl_now parses and completes its canonical target", %{scope: scope} do
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.send_resp(200, "raw")
    end)

    opts =
      options(scope, plug: {Req.Test, name})
      |> Map.put(:parser, Parser)
      |> Map.put(:direct_observer, self())

    assert %Page{body: "raw"} = Crawler.crawl_now(opts)
    assert_receive {:direct_parsed, "raw"}
    assert Store.ops_count(scope) == 1
    assert {:warn, :already_completed} = Crawler.crawl_now(opts)
    await(fn -> assert :sys.get_state(Store).scheduler.claims == %{} end)
  end

  test "a later direct target preserves the existing absolute run deadline", %{scope: scope} do
    parent = self()
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      if conn.request_path == "/held" do
        send(parent, {:run_transport, self()})

        receive do
          :continue -> :ok
        end
      end

      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain")
      |> Plug.Conn.send_resp(200, "one")
    end)

    opts = options(scope, plug: {Req.Test, name}) |> Map.put(:run_timeout, 120)
    assert %Page{} = Fetcher.fetch(opts)
    assert {:error, {:deadline, :run}} = Fetcher.fetch(%{opts | url: "https://direct.test/held"})
    assert_receive {:run_transport, executor}
    refute Process.alive?(executor)

    await(fn ->
      state = :sys.get_state(Store)
      assert state.direct_waiters == %{}
      assert state.scheduler.claims == %{}
    end)
  end

  test "failed direct preparation leaves no automatic scope metadata", %{scope: scope} do
    opts = options(scope, adapter: fn _ -> raise "not sent" end)
    opts = Map.put(opts, :modifier, fn _ -> {:error, :preparation_failed} end)
    assert {:error, _} = Fetcher.fetch(opts)
    state = :sys.get_state(Store)
    refute state.scopes[scope]
    refute state.cookies[scope]
    refute state.cookie_outcomes[scope]
    assert state.direct_waiters == %{}
  end

  defp direct_retry_fixture(scope) do
    generation = Store.generation(scope)

    Store.save_cookies(
      scope,
      "https://direct.test/private",
      ["id=A; Path=/private; Secure"],
      generation
    )

    {:ok, calls} = Agent.start_link(fn -> [] end)
    name = {__MODULE__, make_ref()}

    Req.Test.stub(name, fn conn ->
      path = conn.request_path
      cookie = List.first(Plug.Conn.get_req_header(conn, "cookie"))
      Agent.update(calls, &[{path, cookie} | &1])

      if path == "/start" do
        conn
        |> Plug.Conn.put_resp_header("location", "/private")
        |> Plug.Conn.send_resp(302, "")
      else
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/javascript")
        |> Plug.Conn.send_resp(200, cookie || "empty")
      end
    end)

    opts =
      options(scope, plug: {Req.Test, name})
      |> Map.merge(%{
        url: "https://direct.test/start",
        site: "https://direct.test/",
        cookie_site: "https://direct.test/",
        cookie_navigation: false,
        generation: generation
      })

    assert %Page{body: "id=A"} = Fetcher.fetch(opts)
    await(fn -> assert :sys.get_state(Store).scheduler.claims == %{} end)
    {opts, calls}
  end

  defp start_direct_retry(opts) do
    parent = self()
    retry = Task.async(fn -> run_direct_retry(opts, parent) end)
    on_exit(fn -> if Process.alive?(retry.pid), do: Process.exit(retry.pid, :kill) end)
    retry
  end

  defp run_direct_retry(opts, parent) do
    Execution.run_job(%{opts | javascript_goal: :module}, &direct_retry_callback(&1, parent))
  catch
    kind, reason -> {:caught, kind, reason}
  end

  defp direct_retry_callback(%{scheduler_mode: :interpret} = owned, parent) do
    Store.save_cookies(
      owned.scope,
      "https://direct.test/private",
      ["id=B; Path=/private; Secure"],
      owned.generation
    )

    assert {:error, :representation_deferred} = result = Fetcher.fetch(owned)
    send(parent, {:direct_retry_held, self(), owned})

    receive do
      :continue_retry -> result
      :raise_retry -> raise "deferred direct retry failed"
    end
  end

  defp direct_retry_callback(owned, parent) do
    state = :sys.get_state(Store)
    worker = self()
    current_lease = owned.execution_lease

    dead_scratch =
      Enum.count(state.resources.receipts, fn
        {_, %{kind: :scratch, holders: holders}} ->
          case holders[worker] do
            %{lease: lease} -> lease != current_lease
            _ -> false
          end

        _ ->
          false
      end)

    monitors = %{
      scheduler: map_size(state.scheduler_monitors),
      execution: map_size(state.execution_monitors),
      arenas: state.resources.open_arenas,
      dead_scratch: dead_scratch
    }

    send(parent, {:direct_retry_claimed, self(), owned, monitors})
    Fetcher.fetch(owned)
  end

  defp assert_direct_retry_cleanup(scope) do
    await(fn ->
      state = :sys.get_state(Store)
      assert state.direct_waiters == %{}
      assert state.direct_owners == %{}
      assert state.scheduler.claims == %{}
      assert state.scheduler_workers == %{}
      assert state.executions == %{}
      assert state.resources.open_arenas == 0
      assert Store.pending_count(scope) == 0
      assert Store.inflight_count(scope) == 0
    end)
  end

  defp options(scope, req_options) do
    Crawler.Options.assign_defaults(%{
      url: "https://direct.test/script",
      scope: scope,
      respect_robots: false,
      store: Store,
      retries: 0,
      javascript_goal: :script,
      html_tag: "script",
      attempt_timeout: 2_000,
      req_options: req_options
    })
  end

  defp await(check, attempts \\ 300)

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
