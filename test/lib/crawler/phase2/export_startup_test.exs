defmodule Crawler.Phase2.ExportStartupTest do
  use ExUnit.Case, async: false

  alias Crawler.Store
  alias Crawler.Store.Authority
  alias Crawler.Store.Execution

  defmodule Reject do
    @behaviour Crawler.Fetcher.UrlFilter.Spec
    @impl true
    def filter(_url, _opts), do: {:error, :fixture_rejected}
  end

  setup do
    {tmp, 0} = System.cmd("pwd", ["-P"], cd: System.tmp_dir!())

    root =
      Path.join(
        String.trim(tmp),
        "crawler-store-export-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    scope = make_ref()

    on_exit(fn ->
      Store.dispose_scope(scope)

      assert eventually(fn ->
               not Enum.any?(:sys.get_state(Store).exports, fn {{owner, _}, _} ->
                 owner === scope
               end)
             end)

      File.rm_rf!(root)
    end)

    %{root: root, scope: scope}
  end

  test "queued exports retain only a bounded finalizer projection after accepted admission", c do
    assert {:ok, queue} =
             OPQ.start_link(worker: Crawler.Dispatcher.Worker, workers: 1, interval: 0)

    OPQ.pause(queue)
    assert {:paused, _, _} = OPQ.info(queue)
    on_exit(fn -> if Process.alive?(queue), do: OPQ.stop(queue) end)

    opts = Map.merge(options(c), %{queue: queue, respect_robots: false, force: false})
    assert {:ok, owned} = Crawler.crawl(opts.url, opts)
    state = :sys.get_state(Store)
    record = state.exports[{owned.scope, owned.generation}]
    automatic = record.automatic
    assert automatic.scope === owned.scope
    assert automatic.generation === owned.generation
    assert automatic.save_to === owned.save_to
    assert automatic.run_deadline === owned.run_deadline
    refute Map.has_key?(automatic, :queue)
    refute Map.has_key?(automatic, :req_options)
    refute Map.has_key?(automatic, :modifier)
    assert record.driver == nil
    assert {:ok, retained} = Crawler.Store.Retained.bytes(automatic, 16_384)
    assert {:ok, copy} = Crawler.Store.Retained.copy_bytes(automatic, 16_384)
    assert retained + copy <= 16_384

    assert {:ok, _child} =
             Crawler.crawl_reference("https://example.test/child", Map.put(owned, :save_to, nil))

    assert :sys.get_state(Store).exports[record.run].automatic === automatic
    refute File.exists?(Path.join(c.root, "archive"))

    oversized_scope = String.duplicate("scope", 10_000)
    on_exit(fn -> Store.dispose_scope(oversized_scope) end)

    assert {:error, {:limit, :max_retained_bytes}} =
             Crawler.crawl(opts.url, Map.put(opts, :scope, oversized_scope))

    after_rejection = :sys.get_state(Store)
    refute Map.has_key?(after_rejection.scopes, oversized_scope)

    refute Enum.any?(Map.keys(after_rejection.exports), fn {scope, _} ->
             scope === oversized_scope
           end)
  end

  test "an accepted queued run automatically finalizes its failed no-source target", c do
    opts = automatic_options(c)
    assert {:ok, owned} = Crawler.crawl(opts.url, opts)
    on_exit(fn -> Crawler.stop(owned) end)

    assert eventually(fn -> match?({:ok, %{state: :ready}}, Crawler.export_status(owned)) end)

    assert {:ok, %{state: :ready, artifacts: 0, targets: 1, ready?: true}} =
             Crawler.export_status(owned)

    refute Crawler.running?(owned)
    assert File.regular?(Path.join([c.root, "archive", "manifest.json"]))
    record = :sys.get_state(Store).exports[{owned.scope, owned.generation}]
    assert record.helper.finalizer.kind == :finalize
    assert eventually(fn -> :sys.get_state(Store).exports[record.run].driver == nil end)

    assert {:error, :closed_export} =
             Crawler.crawl_reference("https://example.test/late", owned)
  end

  test "last queue retirement cancels its export before a pending close can run", c do
    assert {:ok, queue} =
             OPQ.start_link(worker: Crawler.Dispatcher.Worker, workers: 1, interval: 0)

    OPQ.pause(queue)
    on_exit(fn -> if Process.alive?(queue), do: OPQ.stop(queue) end)
    opts = Map.merge(options(c), %{queue: queue, respect_robots: false, force: false})
    assert {:ok, owned} = Crawler.crawl(opts.url, opts)
    owner = Process.whereis(Store)
    run = {owned.scope, owned.generation}
    assert :sys.get_state(Store).exports[run].driver == nil

    OPQ.stop(queue)
    assert eventually(fn -> :sys.get_state(Store).exports[run] == nil end)
    send(owner, :export_pending)
    assert {:error, :stale} = Store.close_export(owned)
    assert Process.whereis(Store) === owner
    refute Map.has_key?(:sys.get_state(Store).scopes, owned.scope)
    refute File.exists?(Path.join(c.root, "archive"))
  end

  test "retained scope rotation removes an old export gate before ordinary CSS discovery", c do
    observer = self()

    adapter = fn request ->
      send(observer, {:retained_scope_request, request.url.path})

      {type, body} =
        case request.url.path do
          "/root" -> {"text/html", "published root"}
          "/ordinary" -> {"text/html", ~s|<link rel="stylesheet" href="/app.css">|}
          "/app.css" -> {"text/css", ~s|@import "tokens.css";a{background:url(image.png)}|}
          "/tokens.css" -> {"text/css", ":root{--color:blue}"}
          "/image.png" -> {"image/png", "image"}
        end

      {request, Req.Response.new(status: 200, body: body, headers: [{"content-type", type}])}
    end

    opts =
      Map.merge(options(c), %{
        workers: 1,
        retries: 0,
        respect_robots: false,
        run_timeout: 10_000,
        max_body: 1_048_576,
        max_analysis_bytes: 16_777_216,
        req_options: [adapter: adapter]
      })

    assert {:ok, first} = Crawler.crawl(opts.url, opts)
    on_exit(fn -> Crawler.Queue.stop(first.queue_owner) end)
    assert eventually(fn -> match?({:ok, %{state: :ready}}, Crawler.export_status(first)) end)
    assert Store.ops_count(c.scope) == 1
    assert_receive {:retained_scope_request, "/root"}
    refute Authority.export_writable?(c.scope, first.generation, first.queue)
    assert Store.generation(c.scope) === first.generation
    refute Authority.export_writable?(c.scope, first.generation, first.queue)

    monitors = Enum.map([first.queue_owner, first.queue], &{&1, Process.monitor(&1)})
    assert :ok = Crawler.Queue.stop(first.queue_owner)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    end

    assert eventually(fn ->
             state = :sys.get_state(Store)

             state.scopes[c.scope] &&
               Crawler.Store.State.generation(state, c.scope) !== first.generation
           end)

    generation = Store.generation(c.scope)
    refute Authority.current?(c.scope, first.generation, first.queue)
    assert Authority.export_writable?(c.scope, generation, nil)
    assert :sys.get_state(Store).scopes[c.scope].run_deadline === first.run_deadline
    assert Crawler.Deadline.check(first.run_deadline) == :ok

    assert {:ok, ordinary} =
             Crawler.crawl(
               "https://example.test/ordinary",
               Map.merge(opts, %{save_to: nil, assets: ["css", "images"]})
             )

    on_exit(fn -> Crawler.stop(ordinary) end)
    assert ordinary.generation === generation
    assert ordinary.run_deadline === first.run_deadline

    assert eventually(fn -> not is_nil(Store.target_outcome(ordinary.target_handle)) end)

    assert %{status: :succeeded} =
             ordinary.target_handle |> Store.target_outcome() |> Crawler.Job.Outcome.bounded()

    assert eventually(fn ->
             Store.ops_count(c.scope) == 5 and not Crawler.running?(ordinary)
           end)

    for path <- ["/ordinary", "/app.css", "/tokens.css", "/image.png"] do
      assert_receive {:retained_scope_request, ^path}, 2_000
      assert Store.find_processed({"https://example.test" <> path, c.scope})
    end

    assert File.regular?(Path.join([c.root, "archive", "manifest.json"]))
  end

  test "automatic finalizer funding refusal preserves its terminal limit", c do
    opts = Map.put(automatic_options(c), :max_analysis_bytes, 4_095)
    assert {:ok, owned} = Crawler.crawl(opts.url, opts)
    on_exit(fn -> Crawler.stop(owned) end)

    assert eventually(fn -> match?({:ok, %{state: :limited}}, Crawler.export_status(owned)) end)

    assert {:ok, %{reason: {:limit, :arena_capacity}, ready?: false}} =
             Crawler.export_status(owned)

    state = :sys.get_state(Store)
    record = state.exports[{owned.scope, owned.generation}]
    target = record.helper.finalizer.id

    assert state.scheduler.frontier.jobs[target].outcome ==
             Crawler.Job.Outcome.limited(:arena_capacity)

    refute Crawler.running?(owned)
    refute File.exists?(Path.join(c.root, "archive"))
  end

  test "automatic finalizer retirement retains initialization custody until actual actor DOWN",
       c do
    file_server = Process.whereis(:file_server_2)
    :ok = :sys.suspend(file_server)

    try do
      opts = automatic_options(c)
      assert {:ok, owned} = Crawler.crawl(opts.url, opts)
      on_exit(fn -> Crawler.stop(owned) end)
      run = {owned.scope, owned.generation}

      assert eventually(fn ->
               match?(
                 %{driver: %{pid: pid}, phase: :acquiring} when is_pid(pid),
                 :sys.get_state(Store).exports[run]
               )
             end)

      record = :sys.get_state(Store).exports[run]
      driver = record.driver.pid
      filesystem = record.filesystem
      finalizer = record.helper.finalizer.id
      driver_monitor = Process.monitor(driver)
      filesystem_monitor = Process.monitor(filesystem)
      assert Crawler.running?(owned)
      assert {:ok, %{state: :finalizing, ready?: false}} = Crawler.export_status(owned)
      for _ <- 1..10, do: send(Process.whereis(Store), :export_pending)
      after_messages = :sys.get_state(Store).exports[run]
      assert after_messages.driver.pid === driver
      assert after_messages.helper.finalizer.id === finalizer

      assert :ok = Store.dispose_scope(owned.scope)
      assert_receive {:DOWN, ^driver_monitor, :process, ^driver, :killed}, 5000
      held = :sys.get_state(Store)
      assert held.exports[run].retired?
      assert held.export_bytes >= record.reserved_bytes
      assert Process.alive?(filesystem)
      :ok = :sys.resume(file_server)
      assert_receive {:DOWN, ^filesystem_monitor, :process, ^filesystem, _}, 5000
      assert eventually(fn -> :sys.get_state(Store).exports[run] == nil end)
      refute File.exists?(Path.join(c.root, "archive"))
    after
      :sys.resume(file_server)
    end
  end

  test "Store associates the selected actor and funds its context before returning", c do
    parent = self()

    task =
      Task.async(fn ->
        Execution.run_job(options(c), fn opts ->
          assert {:ok, export} = Store.export_context(opts)
          assert {:ok, ready} = Store.export_filesystem(opts, export.epoch)
          state = :sys.get_state(Store)
          record = state.exports[ready.run]
          assert record.filesystem == ready.filesystem
          assert record.receipt == ready.receipt
          assert record.phase == :ready
          assert record.waiters == %{}
          assert state.export_actors[ready.filesystem] == ready.run
          assert Process.alive?(ready.filesystem)
          assert state.resources.used > 65_536
          send(parent, {:ready, ready, self()})

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive {:ready, ready, executor}, 5000
    monitor = Process.monitor(ready.filesystem)
    Store.dispose_scope(c.scope)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 5000
    send(executor, :finish)
    assert Task.await(task, 5000) == {:warn, :stale}
    assert eventually(fn -> :sys.get_state(Store).exports[ready.run] == nil end)
    refute File.exists?(Path.join(c.root, "archive"))
  end

  test "one expired initializer caller does not cancel a sibling waiting on shared setup", c do
    parent = self()
    file_server = Process.whereis(:file_server_2)
    :ok = :sys.suspend(file_server)
    on_exit(fn -> :sys.resume(file_server) end)

    first =
      Task.async(fn ->
        Execution.run_job(options(c) |> Map.put(:attempt_timeout, 150), fn opts ->
          assert {:ok, export} = Store.export_context(opts)
          send(parent, :first_starting)
          Store.export_filesystem(opts, export.epoch)
        end)
      end)

    assert_receive :first_starting, 5000

    assert eventually(fn ->
             Enum.any?(scope_exports(:sys.get_state(Store), c.scope), fn {_, record} ->
               record.phase == :acquiring
             end)
           end)

    second =
      Task.async(fn ->
        Execution.run_job(options(c) |> Map.put(:url, "https://example.test/second"), fn opts ->
          assert {:ok, export} = Store.export_context(opts)
          send(parent, :second_starting)
          result = Store.export_filesystem(opts, export.epoch)
          send(parent, {:second_result, result, self()})

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :second_starting, 5000
    assert Task.await(first, 5000) == {:error, {:deadline, :attempt}}
    state = :sys.get_state(Store)
    [{_, record}] = scope_exports(state, c.scope)
    assert Process.alive?(record.filesystem)
    assert map_size(record.waiters) <= 2
    :ok = :sys.resume(file_server)
    assert_receive {:second_result, {:ok, ready}, executor}, 5000
    assert ready.filesystem == record.filesystem
    send(executor, :finish)
    assert Task.await(second, 5000) == :ok
  end

  test "retirement during setup retains custody until the actor completes cleanup", c do
    file_server = Process.whereis(:file_server_2)
    :ok = :sys.suspend(file_server)
    on_exit(fn -> :sys.resume(file_server) end)

    task =
      Task.async(fn ->
        Execution.run_job(options(c), fn opts ->
          assert {:ok, export} = Store.export_context(opts)
          Store.export_filesystem(opts, export.epoch)
        end)
      end)

    assert eventually(fn ->
             Enum.any?(scope_exports(:sys.get_state(Store), c.scope), fn {_, record} ->
               record.phase == :acquiring
             end)
           end)

    [{run, record}] = scope_exports(:sys.get_state(Store), c.scope)
    monitor = Process.monitor(record.filesystem)
    Store.dispose_scope(c.scope)
    retired = :sys.get_state(Store)
    assert retired.exports[run].retired?
    assert retired.export_bytes >= record.reserved_bytes
    assert Process.alive?(record.filesystem)
    :ok = :sys.resume(file_server)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 5000
    assert Task.await(task, 5000) == {:warn, :stale}
    assert eventually(fn -> :sys.get_state(Store).exports[run] == nil end)
    refute File.exists?(Path.join(c.root, "archive"))
  end

  test "startup waiters have an explicit finite ceiling inside the owner reservation", c do
    file_server = Process.whereis(:file_server_2)
    :ok = :sys.suspend(file_server)
    on_exit(fn -> :sys.resume(file_server) end)

    tasks =
      for index <- 1..16 do
        Task.async(fn ->
          Execution.run_job(Map.put(options(c), :url, "https://example.test/#{index}"), fn opts ->
            {:ok, export} = Store.export_context(opts)
            Store.export_filesystem(opts, export.epoch)
          end)
        end)
      end

    assert eventually(fn -> map_size(:sys.get_state(Store).export_waiters) == 16 end)
    state = :sys.get_state(Store)
    [{run, record}] = scope_exports(state, c.scope)
    assert {:ok, _} = Crawler.Store.Retained.bytes(record.waiters, 65_536)
    assert map_size(state.export_waiter_leases) == 16

    assert Execution.run_job(Map.put(options(c), :url, "https://example.test/extra"), fn opts ->
             {:ok, export} = Store.export_context(opts)
             Store.export_filesystem(opts, export.epoch)
           end) == {:error, {:limit, :export_waiters}}

    assert map_size(:sys.get_state(Store).export_waiters) == 16
    Store.dispose_scope(c.scope)
    assert :sys.get_state(Store).export_waiters == %{}
    assert :sys.get_state(Store).export_waiter_leases == %{}
    :ok = :sys.resume(file_server)
    Enum.each(tasks, fn task -> assert Task.await(task, 5000) == {:warn, :stale} end)
    assert eventually(fn -> :sys.get_state(Store).exports[run] == nil end)
  end

  defp scope_exports(state, scope),
    do: Enum.filter(state.exports, fn {{owner, _generation}, _record} -> owner === scope end)

  defp automatic_options(c) do
    Map.merge(options(c), %{
      workers: 1,
      interval: 0,
      retries: 0,
      respect_robots: false,
      url_filter: Reject,
      max_manifest_bytes: 262_144
    })
  end

  defp options(c) do
    %{
      url: "https://example.test/root",
      scope: c.scope,
      save_to: Path.join(c.root, "archive"),
      attempt_timeout: 5000,
      max_body: 1024,
      max_analysis_bytes: 1_048_576
    }
  end

  defp eventually(callback, left \\ 200)
  defp eventually(callback, 0), do: callback.()

  defp eventually(callback, left) do
    if callback.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(callback, left - 1)
        )
  end
end
