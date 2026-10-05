defmodule Crawler.ReqTestSite.LifecycleTest do
  use ExUnit.Case, async: true

  import Crawler.TestHelpers

  alias Crawler.ReqTestSite
  alias Crawler.ReqTestSite.Lifecycle
  alias Crawler.Store

  setup do
    fixture = ReqTestSite.open(verify_on_exit: false)
    on_exit(fn -> ReqTestSite.close(fixture) end)
    {:ok, fixture: fixture}
  end

  test "completed requests release their caller monitors and request tokens", %{fixture: fixture} do
    text(fixture.site, "/done")
    before = self() |> Process.info(:monitored_by) |> elem(1) |> MapSet.new()

    for _ <- 1..10 do
      assert {:ok, %Req.Response{status: 200}} =
               Req.get(fixture.url <> "/done", fixture.req_options)
    end

    wait(fn ->
      after_requests = self() |> Process.info(:monitored_by) |> elem(1) |> MapSet.new()
      assert after_requests == before
      assert Agent.get(fixture.site.agent, & &1.requests) == %{}
    end)

    assert :ok = ReqTestSite.verify!(fixture)
  end

  test "a killed caller terminates an exit-trapping handler before verification", %{
    fixture: fixture
  } do
    observer = self()

    ReqTestSite.expect_once(fixture.site, "GET", "/held", fn conn ->
      Process.flag(:trap_exit, true)
      send(observer, {:handler_started, self()})

      receive do
        :release ->
          send(observer, :late_side_effect)
          Plug.Conn.send_resp(conn, 200, "done")
      end
    end)

    caller = spawn(fn -> Req.get(fixture.url <> "/held", fixture.req_options) end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:handler_started, handler}, 2_000
    on_exit(fn -> Process.exit(handler, :kill) end)
    caller_monitor = Process.monitor(caller)
    handler_monitor = Process.monitor(handler)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}, 2_000
    assert :ok = ReqTestSite.verify!(fixture)
    refute Process.alive?(handler)
    assert_receive {:DOWN, ^handler_monitor, :process, ^handler, :killed}, 2_000
    assert Agent.get(fixture.site.agent, & &1.requests) == %{}
    send(handler, :release)
    refute_receive :late_side_effect
  end

  test "handler errors release request accounting and caller monitors", %{fixture: fixture} do
    ReqTestSite.expect_once(fixture.site, "GET", "/error", fn _conn -> raise "handler failed" end)
    before = self() |> Process.info(:monitored_by) |> elem(1) |> MapSet.new()

    assert {:ok, %Req.Response{status: 500}} =
             Req.get(fixture.url <> "/error", fixture.req_options)

    wait(fn ->
      after_request = self() |> Process.info(:monitored_by) |> elem(1) |> MapSet.new()
      assert after_request == before
      assert Agent.get(fixture.site.agent, & &1.requests) == %{}
    end)

    assert_raise ExUnit.AssertionError, ~r/handler failed/, fn -> ReqTestSite.verify!(fixture) end
  end

  test "a killed handler returns a fixture failure to its caller", %{
    fixture: fixture
  } do
    ReqTestSite.expect_once(fixture.site, "GET", "/killed", fn _conn ->
      Process.exit(self(), :kill)
    end)

    assert {:ok, %Req.Response{status: 500}} =
             Req.get(fixture.url <> "/killed", fixture.req_options)

    assert Agent.get(fixture.site.agent, & &1.requests) == %{}

    assert_raise ExUnit.AssertionError, ~r/exited: :killed/, fn ->
      ReqTestSite.verify!(fixture)
    end
  end

  test "closing a fixture terminates an exit-trapping handler and its watcher", %{
    fixture: fixture
  } do
    assert_close_stops_handler(fixture, false)
  end

  test "close owns a handler before its callback starts", %{fixture: fixture} do
    observer = self()
    caller = spawn(fn -> run_registered_request(observer) end)
    on_exit(fn -> Process.exit(caller, :kill) end)

    watcher =
      Agent.get_and_update(fixture.site.agent, fn state ->
        {state, watcher} = Lifecycle.start_request(state, make_ref(), caller, fixture.site.agent)
        {watcher, state}
      end)

    true = :erlang.suspend_process(watcher)
    on_exit(fn -> if Process.alive?(watcher), do: :erlang.resume_process(watcher) end)
    1 = :erlang.trace(watcher, true, [:procs])
    send(caller, {:run, watcher})

    wait(fn ->
      {:messages, messages} = Process.info(watcher, :messages)
      assert Enum.any?(messages, &match?({:handler, _, _}, &1))
    end)

    closer = Task.async(fn -> ReqTestSite.close(fixture) end)

    wait(fn ->
      {:messages, messages} = Process.info(watcher, :messages)
      assert :finished in messages
    end)

    refute_received :callback_started
    assert Task.yield(closer, 0) == nil
    true = :erlang.resume_process(watcher)
    assert :ok = Task.await(closer, 2_000)
    assert_receive {:trace, ^watcher, :spawn, handler, _}, 2_000
    refute Process.alive?(handler)
    refute Process.alive?(watcher)
    send(handler, :release)
    refute_receive :late_side_effect
  end

  test "crawl and owned queue registration are atomic with close", %{fixture: fixture} do
    opts = owned_queue(fixture)
    agent = fixture.site.agent
    true = :erlang.suspend_process(agent)
    on_exit(fn -> if Process.alive?(agent), do: :erlang.resume_process(agent) end)
    registration = Task.async(fn -> ReqTestSite.track_crawl(opts, owned_queue?: true) end)
    wait(fn -> assert elem(Process.info(agent, :message_queue_len), 1) == 1 end)
    closer = Task.async(fn -> ReqTestSite.close(fixture) end)
    wait(fn -> assert elem(Process.info(agent, :message_queue_len), 1) == 2 end)
    true = :erlang.resume_process(agent)
    assert :ok = Task.await(registration, 2_000)
    assert :ok = Task.await(closer, 2_000)
    refute Process.alive?(opts.queue_owner)
    refute Process.alive?(opts.queue)
  end

  test "closed fixtures reject registration and stop only confirmed owned queues", %{
    fixture: fixture
  } do
    assert :ok = ReqTestSite.close(fixture)
    owned = owned_queue(fixture)
    borrowed = owned_queue(fixture)
    mismatched = owned_queue(fixture)

    assert {:error, :fixture_closed} = ReqTestSite.track_crawl(owned, owned_queue?: true)
    refute Process.alive?(owned.queue_owner)
    refute Process.alive?(owned.queue)
    assert {:error, :fixture_closed} = ReqTestSite.track_crawl(borrowed, owned_queue?: false)
    assert Process.alive?(borrowed.queue_owner)
    assert Process.alive?(borrowed.queue)

    assert {:error, :fixture_closed} =
             ReqTestSite.track_crawl(%{mismatched | scope: "unrelated"}, owned_queue?: true)

    assert Process.alive?(mismatched.queue_owner)
    assert Process.alive?(mismatched.queue)
  end

  test "start_crawl returns the closed fixture rejection", %{fixture: fixture} do
    assert :ok = ReqTestSite.close(fixture)

    assert {:error, :fixture_closed} =
             start_crawl(fixture.url <> "/closed",
               scope: unique_scope("fixture-closed-start"),
               req_options: fixture.req_options
             )
  end

  test "closing a fixture waits for a delayed watcher before stopping its Agent", %{
    fixture: fixture
  } do
    assert_close_stops_handler(fixture, true)
  end

  test "closing a fixture can overlap normal request completion", %{fixture: fixture} do
    observer = self()

    ReqTestSite.expect_once(fixture.site, "GET", "/complete", fn conn ->
      send(observer, {:handler_started, self()})

      receive do
        :release -> Plug.Conn.send_resp(conn, 200, "done")
      end
    end)

    request = Task.async(fn -> Req.get(fixture.url <> "/complete", fixture.req_options) end)
    assert_receive {:handler_started, handler}, 2_000
    on_exit(fn -> Process.exit(handler, :kill) end)
    handler_monitor = Process.monitor(handler)
    [watcher] = Agent.get(fixture.site.agent, &Map.values(&1.requests))
    true = :erlang.suspend_process(watcher)
    on_exit(fn -> if Process.alive?(watcher), do: :erlang.resume_process(watcher) end)
    closer = Task.async(fn -> ReqTestSite.close(fixture) end)

    wait(fn ->
      {:messages, messages} = Process.info(watcher, :messages)
      assert :finished in messages
    end)

    send(handler, :release)
    assert_receive {:DOWN, ^handler_monitor, :process, ^handler, :normal}, 2_000
    assert Task.yield(closer, 0) == nil
    true = :erlang.resume_process(watcher)
    assert :ok = Task.await(closer, 2_000)
    refute Process.alive?(handler)
    assert {:ok, %Req.Response{status: 200, body: "done"}} = Task.await(request, 2_000)
  end

  test "closing from a handler completes cleanup of the fixture and other handlers", %{
    fixture: fixture
  } do
    observer = self()

    ReqTestSite.expect_once(fixture.site, "GET", "/other", fn conn ->
      Process.flag(:trap_exit, true)
      send(observer, {:other_started, self()})

      receive do
        :release ->
          send(observer, :late_side_effect)
          Plug.Conn.send_resp(conn, 200, "late")
      end
    end)

    other_caller = spawn(fn -> request_until_closed(fixture, "/other") end)
    on_exit(fn -> Process.exit(other_caller, :kill) end)
    assert_receive {:other_started, other_handler}, 2_000
    on_exit(fn -> Process.exit(other_handler, :kill) end)

    ReqTestSite.expect_once(fixture.site, "GET", "/self-close", fn _conn ->
      send(observer, {:closer_started, self()})

      receive do
        :close -> ReqTestSite.close(fixture)
      end
    end)

    closer_caller = spawn(fn -> request_until_closed(fixture, "/self-close") end)
    on_exit(fn -> Process.exit(closer_caller, :kill) end)
    assert_receive {:closer_started, closer_handler}, 2_000
    on_exit(fn -> Process.exit(closer_handler, :kill) end)
    fixture_monitor = Process.monitor(fixture.site.agent)
    other_monitor = Process.monitor(other_handler)
    closer_monitor = Process.monitor(closer_handler)
    send(closer_handler, :close)
    assert_receive {:DOWN, ^fixture_monitor, :process, _, :normal}, 2_000
    refute Process.alive?(other_handler)
    refute Process.alive?(closer_handler)
    assert_receive {:DOWN, ^other_monitor, :process, ^other_handler, :killed}, 2_000
    assert_receive {:DOWN, ^closer_monitor, :process, ^closer_handler, :killed}, 2_000
    send(other_handler, :release)
    refute_receive :late_side_effect
  end

  test "closing a fixture stops its own queues and preserves stored pages", %{fixture: fixture} do
    other = ReqTestSite.open(verify_on_exit: false)
    on_exit(fn -> ReqTestSite.close(other) end)
    text(fixture.site, "/owned")
    text(fixture.site, "/borrowed")
    text(other.site, "/unrelated")
    owned = crawl(fixture, "/owned")
    unrelated = crawl(other, "/unrelated")

    {:ok, borrowed} =
      start_crawl(fixture.url <> "/borrowed",
        scope: unrelated.scope,
        queue: unrelated.queue,
        store: Store,
        req_options: fixture.req_options
      )

    await_idle(borrowed)
    assert :ok = ReqTestSite.verify!(fixture)
    assert :ok = ReqTestSite.close(fixture)
    refute Process.alive?(owned.queue)
    refute Process.alive?(owned.queue_owner)
    assert Store.find_processed({owned.url, owned.scope}).body == "done"
    assert Process.alive?(unrelated.queue)
    assert Process.alive?(unrelated.queue_owner)
    assert Store.find_processed({unrelated.url, unrelated.scope}).body == "done"
    assert Store.find_processed({borrowed.url, borrowed.scope}).body == "done"
  end

  test "closing a fixture leaves an external queue alive", %{fixture: fixture} do
    scope = unique_scope("fixture-external")

    owner =
      start_supervised!({Crawler.Queue, %{scope: scope, workers: 1, interval: 0, timeout: 5_000}})

    queue = Crawler.Queue.feeder(owner)
    text(fixture.site, "/external")

    {:ok, crawl} =
      start_crawl(fixture.url <> "/external",
        scope: scope,
        queue: queue,
        store: Store,
        req_options: fixture.req_options
      )

    await_idle(crawl)
    assert :ok = ReqTestSite.verify!(fixture)
    assert :ok = ReqTestSite.close(fixture)
    assert Process.alive?(queue)
    assert Process.alive?(owner)
    assert Store.find_processed({crawl.url, scope}).body == "done"
  end

  defp assert_close_stops_handler(fixture, suspend_watcher?) do
    observer = self()

    ReqTestSite.expect_once(fixture.site, "GET", "/close", fn conn ->
      Process.flag(:trap_exit, true)
      send(observer, {:handler_started, self()})

      receive do
        :release ->
          send(observer, :late_side_effect)
          Plug.Conn.send_resp(conn, 200, "done")
      end
    end)

    ReqTestSite.stub(fixture.site, "GET", "/after-close", fn conn ->
      send(observer, :unexpected_handler_started)
      Plug.Conn.send_resp(conn, 200, "late")
    end)

    caller = spawn(fn -> request_until_closed(fixture, "/close") end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:handler_started, handler}, 2_000
    on_exit(fn -> Process.exit(handler, :kill) end)

    watcher =
      wait(fn ->
        caller_watchers = caller |> Process.info(:monitored_by) |> elem(1) |> MapSet.new()

        fixture_watchers =
          fixture.site.agent |> Process.info(:monitored_by) |> elem(1) |> MapSet.new()

        assert [watcher] =
                 caller_watchers |> MapSet.intersection(fixture_watchers) |> MapSet.to_list()

        watcher
      end)

    watcher_monitor = Process.monitor(watcher)
    caller_monitor = Process.monitor(caller)
    handler_monitor = Process.monitor(handler)

    if suspend_watcher? do
      close_with_delayed_watcher(fixture, watcher, handler)
    else
      assert :ok = ReqTestSite.close(fixture)
    end

    refute Process.alive?(handler)
    assert_receive {:DOWN, ^watcher_monitor, :process, ^watcher, :normal}, 2_000
    assert_receive {:DOWN, ^handler_monitor, :process, ^handler, :killed}, 2_000
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :normal}, 2_000
    send(handler, :release)
    refute_receive :late_side_effect
  end

  defp close_with_delayed_watcher(fixture, watcher, handler) do
    true = :erlang.suspend_process(watcher)

    on_exit(fn ->
      if Process.alive?(watcher), do: :erlang.resume_process(watcher)
    end)

    closer = Task.async(fn -> ReqTestSite.close(fixture) end)

    wait(fn ->
      assert Process.alive?(fixture.site.agent)
      {:messages, messages} = Process.info(watcher, :messages)
      assert :finished in messages
    end)

    assert Process.alive?(handler)
    assert Task.yield(closer, 0) == nil

    assert {:ok, %Req.Response{status: 500, body: "ReqTestSite is closed"}} =
             Req.get(fixture.url <> "/after-close", fixture.req_options)

    refute_received :unexpected_handler_started

    opts = owned_queue(fixture)
    assert {:error, :fixture_closed} = ReqTestSite.track_crawl(opts, owned_queue?: true)
    refute Process.alive?(opts.queue_owner)
    refute Process.alive?(opts.queue)

    true = :erlang.resume_process(watcher)
    assert :ok = Task.await(closer, 2_000)
  end

  defp request_until_closed(fixture, path) do
    Req.get(fixture.url <> path, fixture.req_options)
  catch
    :exit, _ -> :ok
  end

  defp run_registered_request(observer) do
    receive do
      {:run, watcher} ->
        Lifecycle.handler_result(watcher, held_callback(observer), 5_000)
        Lifecycle.finish_request(watcher)
    end
  end

  defp held_callback(observer) do
    fn ->
      Process.flag(:trap_exit, true)
      send(observer, :callback_started)

      receive do
        :release -> send(observer, :late_side_effect)
      end
    end
  end

  defp owned_queue(fixture) do
    scope = unique_scope("fixture-registration")
    opts = %{scope: scope, workers: 1, interval: 0, timeout: 5_000}
    spec = Supervisor.child_spec({Crawler.Queue, opts}, restart: :temporary)
    {:ok, owner} = DynamicSupervisor.start_child(Crawler.QueueSupervisor, spec)
    on_exit(fn -> Crawler.Queue.stop(owner) end)

    %{
      scope: scope,
      generation: Store.generation(scope),
      queue: Crawler.Queue.feeder(owner),
      queue_owner: owner,
      req_options: fixture.req_options
    }
  end

  defp text(site, path) do
    ReqTestSite.stub(site, "GET", path, &Plug.Conn.send_resp(&1, 200, "done"))
  end

  defp crawl(fixture, path) do
    {:ok, crawl} =
      start_crawl(fixture.url <> path,
        scope: unique_scope("fixture-owned"),
        store: Store,
        req_options: fixture.req_options
      )

    await_idle(crawl)
    crawl
  end
end
