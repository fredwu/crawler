defmodule Crawler.Phase2.DeadlineIntegrationTest do
  use ExUnit.Case, async: false
  alias Crawler.Store

  defmodule PassParser do
    def parse(page), do: {:ok, page}
  end

  defmodule HeldModifier do
    @behaviour Crawler.Fetcher.Modifier.Spec

    def opts(opts) do
      send(opts.test_owner, {:preparation_held, self()})

      receive do
        :release_preparation -> []
      end
    end

    def headers(_opts), do: []
  end

  test "reused crawl options cap preparation at the attempt deadline" do
    scope = make_ref()
    observer = self()
    on_exit(fn -> Store.dispose_scope(scope) end)

    options =
      Crawler.Options.assign_defaults(%{
        scope: scope,
        workers: 1,
        interval: 0,
        retries: 0,
        respect_robots: false,
        attempt_timeout: 1_000,
        run_timeout: 10_000,
        req_options: [
          adapter: fn request ->
            send(observer, :unexpected_preparation_request)
            {request, Req.Response.new(status: 200, body: "root")}
          end
        ]
      })

    owner = start_supervised!({Crawler.Queue, options})
    queue = Crawler.Queue.feeder(owner)
    OPQ.pause(queue)
    assert {:paused, _, _} = OPQ.info(queue)

    assert {:ok, bound} =
             Crawler.crawl(
               "https://deadline-preparation.test/first",
               Map.put(options, :queue, queue)
             )

    queued =
      await(fn ->
        assert {:paused, %OPQ.Queue{data: pending}, _} = OPQ.info(queue)
        assert [%Crawler.QueueTickets.Ticket{}] = :queue.to_list(pending)
        pending
      end)

    before = admission_state(bound)
    tickets = Crawler.QueueTickets.status(queue)
    assert %{outstanding: 1} = tickets

    task =
      Task.async(fn ->
        Crawler.crawl(
          "https://deadline-preparation.test/second",
          Map.merge(bound, %{modifier: HeldModifier, test_owner: observer, attempt_timeout: 200})
        )
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    assert_receive {:preparation_held, executor}, 1_000
    monitor = Process.monitor(executor)
    assert Task.await(task, 2_000) == {:error, {:deadline, :attempt}}
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}, 1_000
    assert Crawler.Deadline.check(bound.run_deadline) == :ok
    assert admission_state(bound) == before
    assert {:paused, %OPQ.Queue{data: ^queued}, _} = OPQ.info(queue)
    assert Crawler.QueueTickets.status(queue) == tickets
    assert Process.alive?(queue)
    assert Process.alive?(owner)
    refute_received :unexpected_preparation_request
  end

  test "last queue rotation rearms a paused replacement at the original absolute deadline" do
    scope = make_ref()
    observer = self()
    on_exit(fn -> Store.dispose_scope(scope) end)

    adapter = fn request ->
      send(observer, {:rotation_request, request.url.path})
      {request, Req.Response.new(status: 200, body: "root")}
    end

    options = %{
      scope: scope,
      workers: 1,
      retries: 0,
      respect_robots: false,
      parser: PassParser,
      attempt_timeout: 1_000,
      run_timeout: 1_500,
      max_body: 262_144,
      max_analysis_bytes: 1_048_576,
      req_options: [adapter: adapter]
    }

    assert {:ok, first} = Crawler.crawl("https://deadline-rotation.test/first", options)
    on_exit(fn -> Crawler.Queue.stop(first.queue_owner) end)

    await(fn ->
      assert %{status: :succeeded} = Store.target_outcome(first.target_handle)
      refute Crawler.running?(first)
    end)

    assert_receive {:rotation_request, "/first"}
    original = :sys.get_state(Store).scopes[scope]
    assert is_reference(original.run_timer)
    assert original.run_deadline === first.run_deadline
    assert :ok = Crawler.Queue.stop(first.queue_owner)

    rotated =
      await(fn ->
        state = :sys.get_state(Store)
        assert state.scopes[scope]
        refute Crawler.Store.State.generation(state, scope) === first.generation
        assert state.scopes[scope].run_deadline === original.run_deadline
        assert state.scopes[scope].run_timer !== original.run_timer
        state.scopes[scope]
      end)

    assert :erlang.read_timer(original.run_timer) == false
    assert Crawler.Deadline.check(rotated.run_deadline) == :ok
    owner = start_supervised!({Crawler.Queue, Crawler.Options.assign_defaults(options)})
    queue = Crawler.Queue.feeder(owner)
    OPQ.pause(queue)
    assert {:paused, _, _} = OPQ.info(queue)

    assert {:ok, replacement} =
             Crawler.crawl(
               "https://deadline-rotation.test/replacement",
               Map.merge(options, %{queue: queue, run_timeout: 10_000, attempt_timeout: 10_000})
             )

    assert replacement.generation !== first.generation
    assert replacement.run_deadline === first.run_deadline
    current = :sys.get_state(Store).scopes[scope]
    assert is_reference(current.run_timer)
    assert current.run_timer !== original.run_timer
    assert :ok = Store.release_queue(first.queue)
    duplicate = :sys.get_state(Store).scopes[scope]
    assert duplicate.revision === current.revision
    assert duplicate.run_timer === current.run_timer
    assert duplicate.run_deadline === current.run_deadline
    send(Process.whereis(Store), {:expire_run, scope, first.generation})
    assert :sys.get_state(Store).scopes[scope].outcome == :open

    await(fn ->
      assert %{status: :limited, reason: {:deadline, :run}} =
               Store.target_outcome(replacement.target_handle)

      assert Store.pending_count(scope) == 0

      assert {:ok, %{state: :limited, reason: {:deadline, :run}}} =
               Crawler.run_status(replacement)

      assert :sys.get_state(Store).scopes[scope].run_timer == nil
    end)

    assert Process.alive?(queue)
    assert {:paused, _, _} = OPQ.info(queue)
    refute_received {:rotation_request, "/replacement"}
  end

  test "partial queue retirement keeps its timer and final unsuccessful removal cancels it" do
    scope = make_ref()
    observer = self()
    on_exit(fn -> Store.dispose_scope(scope) end)

    options =
      Crawler.Options.assign_defaults(%{
        scope: scope,
        workers: 1,
        retries: 0,
        respect_robots: false,
        run_timeout: 5_000,
        req_options: [
          adapter: fn request ->
            send(observer, :unexpected_paused_request)
            {request, Req.Response.new(status: 200, body: "paused")}
          end
        ]
      })

    owners =
      for _ <- 1..2 do
        start_supervised!(
          Supervisor.child_spec(
            {Crawler.Queue, options},
            id: {Crawler.Queue, make_ref()},
            restart: :temporary
          )
        )
      end

    [first_queue, second_queue] = Enum.map(owners, &Crawler.Queue.feeder/1)

    for queue <- [first_queue, second_queue] do
      OPQ.pause(queue)
      assert {:paused, _, _} = OPQ.info(queue)
    end

    assert {:ok, first} =
             Crawler.crawl(
               "https://deadline-shared-retirement.test/first",
               Map.put(options, :queue, first_queue)
             )

    assert {:ok, second} =
             Crawler.crawl(
               "https://deadline-shared-retirement.test/second",
               Map.put(options, :queue, second_queue)
             )

    assert second.generation === first.generation
    before = :sys.get_state(Store).scopes[scope]
    assert map_size(before.work) == 2
    assert before.ops == 0
    assert is_reference(before.run_timer)
    [first_owner, second_owner] = owners
    assert :ok = Crawler.Queue.stop(first_owner)
    partial = :sys.get_state(Store).scopes[scope]
    assert Map.keys(partial.work) == [second_queue]
    assert partial.revision === before.revision
    assert partial.run_timer === before.run_timer
    assert partial.run_deadline === before.run_deadline
    assert Store.current?(scope, second.generation, second_queue)
    refute Store.current?(scope, first.generation, first_queue)
    assert is_integer(:erlang.read_timer(before.run_timer))
    assert :ok = Crawler.Queue.stop(second_owner)
    refute Map.has_key?(:sys.get_state(Store).scopes, scope)
    assert :erlang.read_timer(before.run_timer) == false
    refute Crawler.Store.Authority.current?(scope, second.generation, second_queue)
    refute_received :unexpected_paused_request
  end

  for kind <- [:attempt, :run] do
    test "a real slow trickle settles #{kind} expiry after a redirect and releases claims" do
      scope = make_ref()
      sibling = make_ref()
      port = trickle_server()

      on_exit(fn ->
        Store.dispose_scope(scope)
        Store.dispose_scope(sibling)
      end)

      limits =
        if unquote(kind) == :attempt,
          do: [attempt_timeout: 150, run_timeout: 2_000],
          else: [attempt_timeout: 2_000, run_timeout: 150]

      assert {:ok, opts} =
               Crawler.crawl(
                 "http://127.0.0.1:#{port}/start",
                 [scope: scope, respect_robots: false, retries: 0, parser: PassParser] ++ limits
               )

      assert_receive :trickle_started, 1_000

      assert {:ok, live} =
               Crawler.crawl("https://deadline-sibling.test/",
                 scope: sibling,
                 respect_robots: false,
                 parser: PassParser,
                 retries: 0,
                 req_options: [
                   adapter: fn request ->
                     {request,
                      Req.Response.new(
                        status: 200,
                        body: "ok",
                        headers: [{"content-type", "text/plain"}]
                      )}
                   end
                 ]
               )

      await(fn ->
        assert %{status: :limited, reason: {:deadline, unquote(kind)}} =
                 Store.target_outcome(opts.target_handle)

        assert %{status: :succeeded} = Store.target_outcome(live.target_handle)
        assert Store.pending_count(scope) == 0
        assert :sys.get_state(Store).scheduler.claims == %{}
        assert :sys.get_state(Store).execution_claims == %{}
      end)

      Crawler.stop(opts)
      Crawler.stop(live)
    end
  end

  test "retry backoff shares the attempt deadline and leaves no claim" do
    scope = make_ref()
    parent = self()
    on_exit(fn -> Store.dispose_scope(scope) end)

    adapter = fn request ->
      send(parent, :retry_attempt)
      {request, Req.Response.new(status: 503, body: "retry")}
    end

    assert {:ok, opts} =
             Crawler.crawl("https://deadline-retry.test/",
               scope: scope,
               respect_robots: false,
               retries: 20,
               attempt_timeout: 75,
               parser: PassParser,
               req_options: [adapter: adapter]
             )

    assert_receive :retry_attempt

    await(fn ->
      assert %{status: :limited, reason: {:deadline, :attempt}} =
               Store.target_outcome(opts.target_handle)

      assert Store.pending_count(scope) == 0
      assert :sys.get_state(Store).scheduler.claims == %{}
    end)

    Crawler.stop(opts)
  end

  defp admission_state(opts) do
    state = :sys.get_state(Store)
    run = {opts.scope, opts.generation}

    %{
      scope: state.scopes[opts.scope],
      frontier_run: state.scheduler.frontier.runs[run],
      targets:
        Map.filter(state.scheduler.frontier.jobs, fn {_ref, record} ->
          Crawler.Frontier.run_key(record.job) == run
        end),
      owner: state.owners[opts.queue],
      executions:
        Map.filter(state.executions, fn {_ref, record} ->
          {record.opts.scope, record.opts.generation} == run
        end)
    }
  end

  defp trickle_server do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    server =
      spawn(fn ->
        {:ok, first} = :gen_tcp.accept(listener)
        {:ok, _} = :gen_tcp.recv(first, 0, 1_000)

        :ok =
          :gen_tcp.send(
            first,
            "HTTP/1.1 302 Found\r\nLocation: /slow\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          )

        :gen_tcp.close(first)
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _} = :gen_tcp.recv(socket, 0, 1_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 10000\r\nConnection: close\r\n\r\n"
          )

        send(parent, :trickle_started)
        trickle(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :kill)
    end)

    port
  end

  defp trickle(socket) do
    case :gen_tcp.send(socket, "x") do
      :ok ->
        receive do
        after
          10 -> trickle(socket)
        end

      _ ->
        :gen_tcp.close(socket)
    end
  end

  defp await(check, attempts \\ 400)

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
