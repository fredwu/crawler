defmodule Crawler.Phase2.ExportLifecycleTest do
  use ExUnit.Case, async: false

  alias Crawler.Export.Filesystem
  alias Crawler.Export.Runtime
  alias Crawler.Export.Runtime.Context
  alias Crawler.IsolatedOwnerHelpers
  alias Crawler.Store
  alias Crawler.Store.Authority
  alias Crawler.Store.Execution
  alias Crawler.Store.ExportRun

  defmodule QueuedPublicationParser do
    @moduledoc false
    @behaviour Crawler.Parser.Spec

    def parse(%{opts: opts} = page) do
      result = Crawler.Parser.parse(page)
      send(opts.publication_observer, {:queued_publication_parsed, self()})

      receive do
        :publish_queued_export -> result
      end
    end

    def parse(other), do: Crawler.Parser.parse(other)
  end

  setup do
    {tmp, 0} = System.cmd("pwd", ["-P"], cd: System.tmp_dir!())

    root =
      Path.join(String.trim(tmp), "crawler-close-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

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

    opts = lifecycle_options(root, scope)

    %{root: root, opts: opts, scope: scope}
  end

  test "close parks one canonical finalizer and refuses late admission without revoking its run",
       c do
    opts = failed_target(c.opts)
    assert {:ok, %{state: :admitting, targets: 1, ready?: false}} = Store.export_status(opts)
    assert {:ok, %{state: :paused, running?: false}} = Store.export_status(opts, true)
    assert {:ok, closed} = Store.close_export(opts)
    state = :sys.get_state(Store)
    target = state.scheduler.frontier.jobs[closed.target_handle]
    assert target.job.kind == :finalize
    assert target.status == {:waiting, :finalizer_driver}
    assert state.exports[{opts.scope, opts.generation}].helper.finalizer.id == target.job.id
    assert Authority.current?(opts.scope, opts.generation, opts.queue)
    refute Authority.export_writable?(opts.scope, opts.generation, opts.queue)

    assert {:error, :closed_export} =
             Store.admit_job(%{opts | url: "https://example.test/late"}, nil, :sitemap)

    assert {:error, :closed_export} = Store.close_export(opts)
    assert {:ok, %{state: :finalizing, ready?: false}} = Store.export_status(opts)
  end

  test "close waits for a live executor and no-source terminals reach the manifest before close",
       c do
    parent = self()

    task =
      Task.async(fn ->
        Execution.run_job(c.opts, fn opts ->
          send(parent, {:held, opts, self()})

          receive do
            :finish -> {:error, :fixture_failure}
          end
        end)
      end)

    assert_receive {:held, opts, executor}, 5000
    assert :busy = Store.close_export(opts)
    assert Authority.export_writable?(opts.scope, opts.generation, opts.queue)
    send(executor, :finish)
    assert Task.await(task, 5000) == {:error, :fixture_failure}
    assert eventually(fn -> idle?(opts) end)
    assert {:ok, closed} = Store.close_export(opts)
    record = :sys.get_state(Store).exports[{opts.scope, opts.generation}]
    assert record.helper.session.manifest.targets[opts.target_handle].outcome == :failed
    assert record.helper.session.manifest.responses == %{}
    assert closed.target_handle != opts.target_handle
  end

  test "rejected close leaves admission and bounded metadata unchanged", c do
    opts = failed_target(Map.put(c.opts, :max_interpretations, 1))
    before = :sys.get_state(Store)
    assert {:error, {:limit, :max_interpretations}} = Store.close_export(opts)
    after_state = :sys.get_state(Store)
    assert after_state.scheduler == before.scheduler
    assert after_state.export_bytes == before.export_bytes
    assert after_state.exports == before.exports
    assert Authority.export_writable?(opts.scope, opts.generation, opts.queue)
  end

  test "waiter capacity refusal keeps the same finalizer parked and retryable", c do
    opts = failed_target(Map.put(c.opts, :max_pending, 1))
    assert {:ok, closed} = Store.close_export(opts)
    other_scope = make_ref()
    on_exit(fn -> Store.dispose_scope(other_scope) end)
    other = failed_target(%{c.opts | scope: other_scope, save_to: Path.join(c.root, "other")})
    assert {:ok, other_closed} = Store.close_export(other)

    waiter =
      Task.async(fn ->
        Store.await_direct(other_closed.target_handle, Crawler.Deadline.after_ms(5000))
      end)

    on_exit(fn -> if Process.alive?(waiter.pid), do: Process.exit(waiter.pid, :kill) end)
    assert eventually(fn -> map_size(:sys.get_state(Store).direct_waiters) == 1 end)
    state = :sys.get_state(Store)
    assert [%{owner?: false, target: observed}] = Map.values(state.direct_waiters)
    assert observed === other_closed.target_handle
    refute Map.has_key?(state.direct_owners, observed)
    assert state.scheduler.frontier.jobs[observed].status == {:waiting, :finalizer_driver}

    assert_capacity_refusal(closed.target_handle, {:limit, :max_pending})
    assert_unrelated_progress(c.opts)
    Task.shutdown(waiter, :brutal_kill)
    assert eventually(fn -> :sys.get_state(Store).direct_waiters == %{} end)
    assert {:ok, :committed} = finalize(opts, closed)
    assert Store.target_outcome(closed.target_handle).status == :succeeded
  end

  test "retained capacity refusal keeps the same finalizer parked and retryable", c do
    state = :sys.get_state(Store)

    options =
      Crawler.Store.ResourceManager.options(state, Crawler.Options.assign_defaults(c.opts))

    baseline = state.resources.used + options.external_frontier_bytes
    ceiling = min(state.resources.limit, baseline + 4_194_304)
    assert ceiling - baseline == 4_194_304, "fixture requires 4 MiB of available retained credit"
    opts = failed_target(Map.put(c.opts, :max_retained_bytes, ceiling))
    assert {:ok, closed} = Store.close_export(opts)
    pressure_scope = make_ref()
    on_exit(fn -> Store.dispose_scope(pressure_scope) end)
    parent = self()
    pressure_opts = %{c.opts | scope: pressure_scope, save_to: nil, max_analysis_bytes: 8_388_608}

    pressure =
      Task.async(fn ->
        Execution.run_job(pressure_opts, fn owned ->
          assert {:ok, receipt} = Store.reserve_resource(owned, :source, 1_048_576)
          assert :ok = Store.commit_resource(receipt, 1_048_576)
          send(parent, {:retained_pressure, self(), receipt})

          receive do
            :release_pressure ->
              Store.release_resource(receipt)
              :ok
          end
        end)
      end)

    on_exit(fn -> if Process.alive?(pressure.pid), do: Process.exit(pressure.pid, :kill) end)
    assert_receive {:retained_pressure, executor, receipt}, 5000
    assert :sys.get_state(Store).resources.receipts[receipt].actual == 1_048_576
    assert retained_headroom(:sys.get_state(Store), opts) < 16_384

    assert_capacity_refusal(closed.target_handle, {:limit, :max_retained_bytes})
    assert_unrelated_progress(c.opts)
    send(executor, :release_pressure)
    assert Task.await(pressure, 5000) == :ok
    assert eventually(fn -> retained_headroom(:sys.get_state(Store), opts) >= 16_384 end)
    assert {:ok, :committed} = finalize(opts, closed)
    assert Store.target_outcome(closed.target_handle).status == :succeeded
  end

  test "the exact finalizer seals, stages a manifest and becomes ready only after cleanup", c do
    opts = failed_target(c.opts)
    assert {:ok, closed} = Store.close_export(opts)
    assert {:ok, :committed} = finalize(opts, closed)

    assert eventually(fn ->
             match?(
               {:ok, %{state: :ready, ready?: true, running?: false}},
               Store.export_status(opts)
             )
           end)

    assert Store.target_outcome(closed.target_handle).status == :succeeded
    assert File.regular?(Path.join([c.root, "archive", "manifest.json"]))
    assert Enum.sort(File.ls!(c.root)) == [".crawler-fs-claims", "archive"]
    state = :sys.get_state(Store)
    assert state.exports[{opts.scope, opts.generation}].filesystem == nil
    assert filesystem_actors_for_run(state, {opts.scope, opts.generation}) == %{}
  end

  test "a promoted archive stays finalizing while its selected filesystem cleanup is held", c do
    opts = failed_target(c.opts)
    assert {:ok, closed} = Store.close_export(opts)
    parent = self()

    task =
      Task.async(fn ->
        finalize(opts, closed, fn filesystem, owned ->
          send(parent, {:cleanup_held, filesystem.filesystem, owned, self()})

          receive do
            :start_commit -> :ok
          end
        end)
      end)

    assert_receive {:cleanup_held, filesystem, owned, executor}, 5000
    assert :erlang.suspend_process(filesystem)
    send(executor, :start_commit)

    try do
      assert eventually(fn ->
               :sys.get_state(Store).exports[{opts.scope, opts.generation}].phase == :finishing
             end)

      assert File.regular?(Path.join([c.root, "archive", "manifest.json"]))

      assert {:ok, %{state: :finalizing, ready?: false, running?: true}} =
               Store.export_status(opts)

      assert Task.await(task, 5000) == {:ok, :committed}
      assert Store.target_outcome(closed.target_handle).status == :succeeded
      assert eventually(fn -> not Authority.execution_current?(owned.execution_lease) end)
      assert Crawler.running?(opts)
      sibling = make_ref()
      assert :ok = Execution.run_job(%{c.opts | scope: sibling, save_to: nil}, fn _ -> :ok end)
      Store.dispose_scope(sibling)
    after
      if Process.alive?(filesystem), do: :erlang.resume_process(filesystem)
    end

    assert eventually(fn ->
             match?({:ok, %{state: :ready, ready?: true}}, Store.export_status(opts))
           end)

    assert Store.target_outcome(closed.target_handle).status == :succeeded
  end

  test "paused queued publication keeps its pause flags across expiry and actual cleanup", c do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, "queued publication")
    end)

    supplied =
      Map.merge(c.opts, %{
        req_options: [plug: {Req.Test, __MODULE__}, retry: false],
        parser: QueuedPublicationParser,
        publication_observer: self(),
        respect_robots: false,
        retries: 0,
        workers: 1,
        interval: 0,
        max_body: 1_048_576,
        max_analysis_bytes: 16_777_216,
        max_manifest_bytes: 1_048_576,
        run_timeout: 2000
      })

    assert {:ok, opts} = Crawler.crawl(supplied.url, supplied)
    on_exit(fn -> Crawler.stop(opts) end)

    assert_receive {:queued_publication_parsed, parser}, 5000

    key = {opts.scope, opts.generation}
    filesystem = :sys.get_state(Store).exports[key].filesystem
    assert is_pid(filesystem)
    monitor = Process.monitor(filesystem)
    hook = hold_queued_cleanup(filesystem)

    on_exit(fn ->
      send(parser, :publish_queued_export)
      send(filesystem, {:release_queued_cleanup, hook})
    end)

    try do
      send(parser, :publish_queued_export)
      assert_receive {:queued_cleanup_held, ^filesystem, nonce}, 5000
      state = :sys.get_state(Store)
      assert state.exports[key].phase == :finishing
      assert state.exports[key].terminal.nonce === nonce
      assert state.exports[key].terminal.pid === filesystem
      assert Store.target_outcome(opts.target_handle).status == :succeeded
      assert Crawler.Deadline.check(opts.run_deadline) == :ok
      archive = published_files(opts)

      assert {:ok, %{state: :finalizing, ready?: false, paused?: false, running?: true}} =
               Crawler.export_status(opts)

      assert :ok = Crawler.pause(opts)
      assert {:paused, _, _} = OPQ.info(opts.queue)
      assert_paused_publication(opts, :finalizing)

      assert {:ok,
              %{
                state: :paused,
                root_status: :succeeded,
                paused?: true,
                running?: false,
                terminal?: false,
                reported_limit: nil
              }} = Crawler.run_status(opts)

      assert eventually(
               fn ->
                 match?(
                   %{outcome: {:limited, {:deadline, :run}}, run_timer: nil},
                   :sys.get_state(Store).scopes[opts.scope]
                 )
               end,
               500
             )

      expired = :sys.get_state(Store)
      assert Crawler.Store.State.generation(expired, opts.scope) === opts.generation
      assert expired.exports[key].terminal === state.exports[key].terminal
      assert Process.alive?(filesystem)
      assert_paused_publication(opts, :finalizing)

      assert {:ok,
              %{
                state: :limited,
                root_status: :succeeded,
                reported_limit: {:deadline, :run},
                paused?: true,
                running?: false,
                terminal?: false
              }} = Crawler.run_status(opts)

      refute Authority.current?(opts.scope, opts.generation, opts.queue)
      refute Authority.export_writable?(opts.scope, opts.generation, opts.queue)
      assert published_files(opts) === archive
      send(filesystem, {:release_queued_cleanup, hook})
      assert_receive {:DOWN, ^monitor, :process, ^filesystem, :normal}, 5000

      assert eventually(fn ->
               match?({:ok, %{state: :ready, ready?: true}}, Crawler.export_status(opts))
             end)

      assert_paused_publication(opts, :ready)

      assert {:ok,
              %{
                state: :limited,
                root_status: :succeeded,
                reported_limit: {:deadline, :run},
                paused?: true,
                running?: false,
                terminal?: true,
                pending: 0,
                inflight: 0
              }} = Crawler.run_status(opts)

      complete = :sys.get_state(Store)
      assert complete.exports[key].filesystem == nil
      assert complete.exports[key].terminal.down?
      assert complete.exports[key].terminal.result == {:ok, :promoted}
      assert filesystem_actors_for_run(complete, key) == %{}
      assert Store.target_outcome(opts.target_handle).status == :succeeded
      assert published_files(opts) === archive
      refute Authority.current?(opts.scope, opts.generation, opts.queue)
      refute Authority.export_writable?(opts.scope, opts.generation, opts.queue)
    after
      send(parser, :publish_queued_export)
      send(filesystem, {:release_queued_cleanup, hook})
    end
  end

  for kind <- [:attempt, :run] do
    test "published cleanup survives the original #{kind} deadline without renewed authority",
         c do
      kind = unquote(kind)

      timeouts =
        if kind == :attempt,
          do: %{attempt_timeout: 1000, run_timeout: 5000},
          else: %{attempt_timeout: 5000, run_timeout: 2000}

      opts = failed_target(Map.merge(c.opts, timeouts))
      assert {:ok, closed} = Store.close_export(opts)
      parent = self()

      task =
        Task.async(fn ->
          finalize(opts, closed, fn filesystem, owned ->
            send(parent, {:deadline_cleanup_held, filesystem.filesystem, owned, self()})

            receive do
              :start_commit -> :ok
            end
          end)
        end)

      assert_receive {:deadline_cleanup_held, filesystem, owned, executor}, 5000
      assert owned.crawler_deadline.kind == kind
      assert :erlang.suspend_process(filesystem)
      send(executor, :start_commit)

      try do
        assert Task.await(task, 5000) == {:ok, :committed}
        assert Store.target_outcome(closed.target_handle).status == :succeeded
        key = {opts.scope, opts.generation}
        state = :sys.get_state(Store)
        record = state.exports[key]
        assert record.phase == :finishing
        assert record.helper.session.manifest.state == :ready
        assert record.helper.session.finalizer.outcome.status == :succeeded
        assert record.terminal.pid == filesystem
        assert map_size(filesystem_actors_for_run(state, key)) == 1
        manifest_path = Path.join([c.root, "archive", "manifest.json"])
        manifest = File.read!(manifest_path)
        assert Jason.decode!(manifest)["resources"] == []

        assert {:ok, %{state: :finalizing, ready?: false, running?: true}} =
                 Store.export_status(opts)

        assert Crawler.running?(opts)
        assert eventually(fn -> not Authority.execution_current?(owned.execution_lease) end)

        assert eventually(
                 fn ->
                   Crawler.Deadline.check(owned.crawler_deadline) == {:error, {:deadline, kind}}
                 end,
                 500
               )

        if kind == :run do
          assert eventually(fn ->
                   match?(
                     %{outcome: {:limited, {:deadline, :run}}, run_timer: nil},
                     :sys.get_state(Store).scopes[opts.scope]
                   )
                 end)

          assert {:ok, %{state: :limited, reported_limit: {:deadline, :run}}} =
                   Crawler.run_status(opts)
        end

        expired = :sys.get_state(Store)
        assert Crawler.Store.State.generation(expired, opts.scope) == opts.generation
        assert expired.exports[key].helper.session.manifest.state == :ready
        assert expired.exports[key].terminal.nonce == record.terminal.nonce
        assert expired.exports[key].terminal.pid == record.terminal.pid
        assert filesystem_actors_for_run(expired, key) == filesystem_actors_for_run(state, key)
        assert Process.alive?(filesystem)
        assert Store.target_outcome(closed.target_handle).status == :succeeded
        refute Authority.execution_current?(owned.execution_lease)
        refute Authority.export_writable?(opts.scope, opts.generation, opts.queue)
        assert File.read!(manifest_path) == manifest

        assert {:ok, %{state: :finalizing, ready?: false}} = Store.export_status(opts)
        assert :erlang.resume_process(filesystem)

        assert eventually(fn ->
                 match?({:ok, %{state: :ready, ready?: true}}, Store.export_status(opts))
               end)

        assert File.read!(manifest_path) == manifest
        assert Enum.sort(File.ls!(c.root)) == [".crawler-fs-claims", "archive"]
        complete = :sys.get_state(Store)
        assert complete.exports[key].filesystem == nil
        assert complete.exports[key].terminal.result == {:ok, :promoted}
        assert complete.exports[key].terminal.down?
        assert filesystem_actors_for_run(complete, key) == %{}
        assert Store.target_outcome(closed.target_handle).status == :succeeded
        refute Authority.execution_current?(owned.execution_lease)
        refute Authority.export_writable?(opts.scope, opts.generation, opts.queue)
      after
        if Process.info(filesystem, :status) == {:status, :suspended},
          do: :erlang.resume_process(filesystem)
      end
    end
  end

  test "unproved cleanup keeps publication success and bounded recovery after disposal", c do
    child = IsolatedOwnerHelpers.start(c.root, __MODULE__, :unproved_cleanup_case, __ENV__.file)

    try do
      assert :ok = IsolatedOwnerHelpers.await(child, Crawler.Deadline.after_ms(10_000))
    after
      IsolatedOwnerHelpers.cleanup(child)
    end
  end

  @doc false
  def unproved_cleanup_case(c) do
    c = Map.put(c, :opts, lifecycle_options(c.root, c.scope))
    opts = failed_target(c.opts)
    assert {:ok, closed} = Store.close_export(opts)
    parent = self()

    task =
      Task.async(fn ->
        finalize(opts, closed, fn filesystem, _owned ->
          send(parent, {:failed_cleanup_held, filesystem.filesystem, self()})

          receive do
            :start_commit -> :ok
          end
        end)
      end)

    assert_receive {:failed_cleanup_held, filesystem, executor}, 5000
    assert :erlang.suspend_process(filesystem)
    send(executor, :start_commit)

    try do
      assert Task.await(task, 5000) == {:ok, :committed}
      assert Store.target_outcome(closed.target_handle).status == :succeeded
      key = {opts.scope, opts.generation}
      record = :sys.get_state(Store).exports[key]
      assert record.phase == :finishing
      assert record.terminal.pid == filesystem
      assert record.terminal.operation == :finish
      assert {:ok, %{state: :finalizing, ready?: false}} = Store.export_status(opts)
      manifest_path = Path.join([c.root, "archive", "manifest.json"])
      manifest = File.read!(manifest_path)
      monitor = Process.monitor(filesystem)
      Process.exit(filesystem, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^filesystem, :killed}, 5000

      assert eventually(fn ->
               match?(
                 {:ok, %{state: :failed, reason: {:snapshot, :cleanup_failed}, ready?: false}},
                 Store.export_status(opts)
               )
             end)

      failed = :sys.get_state(Store)
      recovery = failed.exports[key]
      assert recovery.phase == :cleanup_failed
      assert recovery.failure == nil
      assert recovery.helper.session.manifest.state == :ready
      assert recovery.helper.session.finalizer.outcome.status == :succeeded
      assert recovery.filesystem == nil
      assert recovery.terminal.down?
      assert recovery.terminal.result == {:error, :cleanup_failed}
      assert recovery.receipt == record.receipt
      assert recovery.reserved_bytes == record.reserved_bytes
      assert {:ok, _} = Crawler.Store.Retained.bytes(recovery.receipt, recovery.reserved_bytes)
      assert File.dir?(recovery.receipt.stage)
      assert File.dir?(recovery.receipt.claim)
      assert filesystem_actors_for_run(failed, key) == %{}
      refute Enum.any?(failed.export_monitors, fn {_ref, actor} -> actor == {key, filesystem} end)
      assert Store.target_outcome(closed.target_handle).status == :succeeded
      assert File.read!(manifest_path) == manifest
      refute Crawler.running?(opts)
      assert :ok = Store.dispose_scope(opts.scope, opts.generation)
      disposed = :sys.get_state(Store)
      assert disposed.exports[key].receipt == record.receipt
      assert disposed.exports[key].reserved_bytes == record.reserved_bytes
      assert disposed.export_bytes >= record.reserved_bytes

      assert {:ok, %{state: :failed, reason: {:snapshot, :cleanup_failed}}} =
               Store.export_status(opts)

      assert File.dir?(record.receipt.stage)
      assert File.dir?(record.receipt.claim)
      assert File.read!(manifest_path) == manifest
    after
      if Process.info(filesystem, :status) == {:status, :suspended},
        do: :erlang.resume_process(filesystem)
    end

    :ok
  end

  test "successful terminal cleanup retains custody until the actual filesystem DOWN is processed",
       c do
    opts = failed_target(c.opts)
    assert {:ok, closed} = Store.close_export(opts)
    parent = self()

    task =
      Task.async(fn ->
        finalize(opts, closed, fn filesystem, _owned ->
          send(parent, {:terminal_held, filesystem.filesystem, self()})

          receive do
            :start_commit -> :ok
          end
        end)
      end)

    assert_receive {:terminal_held, filesystem, executor}, 5000
    assert :erlang.suspend_process(filesystem)
    send(executor, :start_commit)
    owner = Process.whereis(Store)

    try do
      assert Task.await(task, 5000) == {:ok, :committed}
      key = {opts.scope, opts.generation}
      before = :sys.get_state(Store)
      record = before.exports[key]
      nonce = record.terminal.nonce

      assert record.terminal == %{
               pid: filesystem,
               nonce: nonce,
               operation: :finish,
               result: nil,
               down?: false
             }

      assert :ok = :sys.suspend(owner)
      assert :erlang.resume_process(filesystem)
      assert eventually(fn -> not Process.alive?(filesystem) end)

      assert eventually(fn ->
               {:messages, messages} = Process.info(owner, :messages)

               {:crawler_filesystem_terminal, filesystem, nonce, :finish, {:ok, :promoted}} in messages
             end)

      after_result = apply_queued_terminal_result(owner, filesystem, nonce)

      held = after_result.exports[key]
      assert held.phase == :finishing
      assert held.filesystem == filesystem
      assert held.terminal.result == {:ok, :promoted}
      refute held.terminal.down?
      assert held.receipt == record.receipt
      assert held.reserved_bytes == record.reserved_bytes
      assert after_result.export_actors[filesystem] == key
      assert after_result.export_monitors == before.export_monitors

      assert {:ok, %{state: :finalizing, ready?: false}} =
               ExportRun.status(after_result, opts, false)

      assert :ok = :sys.resume(owner)

      assert eventually(fn ->
               match?({:ok, %{state: :ready, ready?: true}}, Store.export_status(opts))
             end)

      complete = :sys.get_state(Store)
      assert complete.exports[key].terminal.down?
      assert complete.exports[key].terminal.result == {:ok, :promoted}
      assert filesystem_actors_for_run(complete, key) == %{}
      refute File.exists?(record.receipt.stage)
      assert File.dir?(record.receipt.claim)
      assert File.regular?(Path.join([c.root, "archive", "manifest.json"]))
      assert Store.target_outcome(closed.target_handle).status == :succeeded
    after
      :sys.resume(owner)

      if Process.info(filesystem, :status) == {:status, :suspended},
        do: :erlang.resume_process(filesystem)
    end
  end

  test "retirement cleans its selected filesystem and releases the aborted destination claim",
       c do
    {opts, filesystem} = acquired_filesystem(c.opts)
    key = {opts.scope, opts.generation}
    before = :sys.get_state(Store)
    record = before.exports[key]
    assert File.dir?(record.receipt.stage)
    assert File.dir?(record.receipt.claim)
    assert :erlang.suspend_process(filesystem)
    monitor = Process.monitor(filesystem)

    try do
      assert :ok = Store.dispose_scope(opts.scope, opts.generation)
      retired = :sys.get_state(Store)
      assert retired.exports[key].retired?
      assert retired.exports[key].filesystem == filesystem
      assert retired.exports[key].terminal.operation == :abort
      assert retired.exports[key].terminal.result == nil
      refute retired.exports[key].terminal.down?
      assert retired.exports[key].reserved_bytes == record.reserved_bytes
      assert retired.export_actors[filesystem] == key
      assert :erlang.resume_process(filesystem)
      assert_receive {:DOWN, ^monitor, :process, ^filesystem, :normal}, 5000
      assert eventually(fn -> not Map.has_key?(:sys.get_state(Store).exports, key) end)
      assert :sys.get_state(Store).export_bytes == before.export_bytes - record.reserved_bytes
      refute File.exists?(record.receipt.stage)
      refute File.exists?(record.receipt.claim)
      refute File.exists?(Path.join(c.root, "archive"))
      assert {:ok, replacement, replacement_receipt} = Filesystem.acquire(c.root, "archive")
      assert {:ok, :aborted} = Filesystem.abort(replacement)
      refute File.exists?(replacement_receipt.claim)
    after
      if Process.info(filesystem, :status) == {:status, :suspended},
        do: :erlang.resume_process(filesystem)
    end
  end

  test "a killed retiring filesystem keeps its unproved recovery receipt and reserved credit",
       c do
    child =
      IsolatedOwnerHelpers.start(
        c.root,
        __MODULE__,
        :killed_retiring_filesystem_case,
        __ENV__.file
      )

    try do
      assert :ok = IsolatedOwnerHelpers.await(child, Crawler.Deadline.after_ms(10_000))
    after
      IsolatedOwnerHelpers.cleanup(child)
    end
  end

  @doc false
  def killed_retiring_filesystem_case(c) do
    c = Map.put(c, :opts, lifecycle_options(c.root, c.scope))
    {opts, filesystem} = acquired_filesystem(c.opts)
    key = {opts.scope, opts.generation}
    record = :sys.get_state(Store).exports[key]
    assert :erlang.suspend_process(filesystem)
    assert :ok = Store.dispose_scope(opts.scope, opts.generation)
    monitor = Process.monitor(filesystem)
    Process.exit(filesystem, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^filesystem, :killed}, 5000

    assert eventually(fn ->
             match?(
               {:ok, %{state: :failed, reason: {:snapshot, :cleanup_failed}}},
               Store.export_status(opts)
             )
           end)

    retained = :sys.get_state(Store)
    recovery = retained.exports[key]
    assert recovery.retired?
    assert recovery.phase == :cleanup_failed
    assert recovery.terminal.operation == :abort
    assert recovery.terminal.down?
    assert recovery.terminal.result == {:error, :cleanup_failed}
    assert recovery.filesystem == nil
    assert recovery.receipt == record.receipt
    assert recovery.reserved_bytes == record.reserved_bytes
    assert retained.export_bytes >= record.reserved_bytes
    assert filesystem_actors_for_run(retained, key) == %{}
    refute Enum.any?(retained.export_monitors, fn {_ref, actor} -> actor == {key, filesystem} end)
    assert File.dir?(record.receipt.stage)
    assert File.dir?(record.receipt.claim)
    assert {:error, _} = Filesystem.acquire(c.root, "archive")
    assert :stale = Store.dispose_scope(opts.scope, opts.generation)
    assert :sys.get_state(Store).exports[key] == recovery
    :ok
  end

  test "retirement retains the exact late acquisition receipt until actual cleanup", c do
    file_server = Process.whereis(:file_server_2)
    owner = Process.whereis(Store)
    assert :ok = :sys.suspend(file_server)

    task =
      Task.async(fn ->
        Execution.run_job(c.opts, fn owned ->
          assert {:ok, export} = Store.export_context(owned)
          Store.export_filesystem(owned, export.epoch)
        end)
      end)

    try do
      assert eventually(fn ->
               Enum.any?(:sys.get_state(Store).exports, fn
                 {{scope, _}, %{phase: :acquiring}} -> scope == c.scope
                 _ -> false
               end)
             end)

      [{key, record}] =
        Enum.filter(:sys.get_state(Store).exports, fn {{scope, _}, _} -> scope == c.scope end)

      filesystem = record.filesystem
      nonce = record.nonce
      assert :ok = Store.dispose_scope(c.scope)
      assert :ok = :sys.suspend(owner)
      assert :ok = :sys.resume(file_server)
      assert eventually(fn -> not Process.alive?(filesystem) end)

      assert eventually(fn ->
               {:messages, messages} = Process.info(owner, :messages)

               Enum.any?(
                 messages,
                 &match?({:crawler_filesystem_acquired, ^nonce, ^filesystem, {:ok, _}}, &1)
               )
             end)

      after_acquisition = apply_queued_acquisition(owner, filesystem, nonce)

      held = after_acquisition.exports[key]
      assert held.retired?
      assert held.receipt.root == c.root
      assert held.receipt.destination == "archive"
      assert held.filesystem == filesystem
      assert held.terminal.operation == :abort
      refute held.terminal.down?
      assert held.reserved_bytes == record.reserved_bytes
      refute Authority.current?(c.scope, elem(key, 1), nil)
      assert :ok = :sys.resume(owner)
      assert Task.await(task, 5000) == {:warn, :stale}
      assert eventually(fn -> not Map.has_key?(:sys.get_state(Store).exports, key) end)
      refute File.exists?(held.receipt.stage)
      refute File.exists?(held.receipt.claim)
    after
      :sys.resume(file_server)
      :sys.resume(owner)
    end
  end

  test "the exact publication acknowledgment survives disposal before its observer resumes", c do
    opts = failed_target(Map.merge(c.opts, %{attempt_timeout: 1000, run_timeout: 5000}))
    assert {:ok, closed} = Store.close_export(opts)
    parent = self()

    task =
      Task.async(fn ->
        result =
          finalize(opts, closed, fn filesystem, owned ->
            send(parent, {:publication_observer_held, filesystem.filesystem, owned, self()})

            receive do
              :start_commit -> :ok
            end
          end)

        {:messages, messages} = Process.info(self(), :messages)
        {result, messages}
      end)

    assert_receive {:publication_observer_held, filesystem, owned, executor}, 5000
    assert :erlang.suspend_process(filesystem)

    try do
      assert :erlang.suspend_process(task.pid)
      send(executor, :start_commit)

      assert eventually(fn ->
               match?(%{status: :succeeded}, Store.target_outcome(closed.target_handle))
             end)

      key = {opts.scope, opts.generation}
      state = :sys.get_state(Store)
      assert state.exports[key].phase == :finishing
      assert {:ok, %{state: :finalizing, ready?: false}} = Store.export_status(opts)
      assert Crawler.running?(opts)
      manifest_path = Path.join([c.root, "archive", "manifest.json"])
      manifest = File.read!(manifest_path)
      owner = Process.whereis(Store)

      publication =
        {:crawler_export_published, owner, closed.target_handle, closed.epoch, closed.close_token}

      assert {:messages, messages} = Process.info(task.pid, :messages)
      assert publication in messages

      other_close =
        {:crawler_export_published, owner, closed.target_handle, closed.epoch, make_ref()}

      send(task.pid, other_close)

      assert eventually(
               fn ->
                 Crawler.Deadline.check(owned.crawler_deadline) == {:error, {:deadline, :attempt}}
               end,
               500
             )

      assert :ok = Store.dispose_scope(opts.scope, opts.generation)

      replacement =
        failed_target(%{c.opts | save_to: Path.join(c.root, "replacement")})

      refute replacement.generation == opts.generation
      replacement_key = {replacement.scope, replacement.generation}
      replacement_record = :sys.get_state(Store).exports[replacement_key]
      assert {:ok, %{state: :admitting}} = Store.export_status(replacement)
      assert {:error, :stale} = Store.export_status(opts)
      assert :erlang.resume_process(filesystem)

      assert eventually(fn ->
               current = :sys.get_state(Store)

               not Map.has_key?(current.exports, key) and
                 not Map.has_key?(current.scheduler.frontier.jobs, closed.target_handle) and
                 filesystem_actors_for_run(current, key) == %{}
             end)

      assert Store.target_outcome(closed.target_handle) == nil
      assert Process.info(task.pid, :status) == {:status, :suspended}
      assert File.read!(manifest_path) == manifest
      assert :sys.get_state(Store).exports[replacement_key] == replacement_record
      assert :erlang.resume_process(task.pid)
      assert {{:ok, :committed}, remaining} = Task.await(task, 5000)
      assert other_close in remaining
      refute publication in remaining
      assert Store.target_outcome(closed.target_handle) == nil
      assert {:error, :stale} = Store.export_status(opts)
      assert {:ok, %{state: :admitting}} = Store.export_status(replacement)
      assert :sys.get_state(Store).exports[replacement_key] == replacement_record
      assert File.read!(manifest_path) == manifest
      refute Authority.execution_current?(owned.execution_lease)
    after
      if Process.info(filesystem, :status) == {:status, :suspended},
        do: :erlang.resume_process(filesystem)

      if Process.info(task.pid, :status) == {:status, :suspended},
        do: :erlang.resume_process(task.pid)
    end
  end

  test "publication acknowledgment survives disposal of the returned executor before result delivery",
       c do
    opts = failed_target(c.opts)
    assert {:ok, closed} = Store.close_export(opts)
    parent = self()

    task =
      Task.async(fn ->
        result =
          finalize(opts, closed, fn filesystem, owned ->
            send(parent, {:returned_publication_prepared, filesystem.filesystem, owned, self()})

            receive do
              :start_commit -> :ok
            end
          end)

        {:messages, messages} = Process.info(self(), :messages)
        {result, messages}
      end)

    assert_receive {:returned_publication_prepared, filesystem, owned, executor}, 5000
    owner = Process.whereis(Store)
    hook = hold_returned_executor(owner, owned.execution_lease, executor, parent)
    assert :erlang.suspend_process(filesystem)
    monitor = Process.monitor(executor)

    other_close =
      {:crawler_export_published, owner, closed.target_handle, closed.epoch, make_ref()}

    send(task.pid, other_close)
    send(executor, :start_commit)

    try do
      assert_receive {:returned_executor_held, ^executor}, 5000

      assert eventually(fn ->
               match?(
                 %{status: :returned},
                 :sys.get_state(Store).executions[owned.execution_lease]
               )
             end)

      assert Process.info(executor, :status) == {:status, :suspended}
      assert Store.target_outcome(closed.target_handle).status == :succeeded
      manifest_path = Path.join([c.root, "archive", "manifest.json"])
      manifest = File.read!(manifest_path)

      publication =
        {:crawler_export_published, owner, closed.target_handle, closed.epoch, closed.close_token}

      assert {:messages, messages} = Process.info(task.pid, :messages)
      assert publication in messages
      assert :ok = Store.dispose_scope(opts.scope, opts.generation)
      assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}, 5000
      assert {{:ok, :committed}, remaining} = Task.await(task, 5000)
      assert other_close in remaining
      refute publication in remaining
      assert File.read!(manifest_path) == manifest
      refute Authority.execution_current?(owned.execution_lease)
      assert :erlang.resume_process(filesystem)
      key = {opts.scope, opts.generation}
      assert eventually(fn -> not Map.has_key?(:sys.get_state(Store).exports, key) end)
      assert File.read!(manifest_path) == manifest
    after
      :sys.remove(owner, hook)

      if Process.info(filesystem, :status) == {:status, :suspended},
        do: :erlang.resume_process(filesystem)

      if Process.info(executor, :status) == {:status, :suspended},
        do: :erlang.resume_process(executor)
    end
  end

  for kind <- [:error, :throw, :exit] do
    test "finalizer #{kind} is preserved when no publication acknowledgment was accepted", c do
      opts = failed_target(c.opts)
      assert {:ok, closed} = Store.close_export(opts)
      kind = unquote(kind)

      execute = fn ->
        Execution.run_finalizer(Map.merge(opts, closed), fn _ ->
          case kind do
            :error -> raise ArgumentError, "unpublished finalizer"
            :throw -> throw(:unpublished_finalizer)
            :exit -> exit(:unpublished_finalizer)
          end
        end)
      end

      case kind do
        :error -> assert_raise ArgumentError, "unpublished finalizer", execute
        :throw -> assert catch_throw(execute.()) == :unpublished_finalizer
        :exit -> assert catch_exit(execute.()) == :unpublished_finalizer
      end

      refute File.exists?(Path.join(c.root, "archive"))
      assert Store.target_outcome(closed.target_handle).status == :failed
    end
  end

  for refusal <- [:missing_root, :destination_exists] do
    test "#{refusal} acquisition releases unclaimed owner credit only after actual DOWN", c do
      refusal = unquote(refusal)
      opts = preclaim_options(c, refusal)
      file_server = Process.whereis(:file_server_2)
      assert :ok = :sys.suspend(file_server)
      observer = self()
      task = Task.async(fn -> request_filesystem(opts, observer) end)

      try do
        assert_receive {:acquisition_owned, owned}, 5000
        key = {owned.scope, owned.generation}
        assert eventually(fn -> :sys.get_state(Store).exports[key].phase == :acquiring end)
        before = :sys.get_state(Store)
        record = before.exports[key]
        filesystem = record.filesystem
        monitor = Process.monitor(filesystem)
        assert record.receipt == nil
        assert Process.alive?(filesystem)
        assert :ok = :sys.resume(file_server)
        assert {:error, _} = Task.await(task, 5000)
        assert_receive {:DOWN, ^monitor, :process, ^filesystem, :normal}, 5000
        assert eventually(fn -> :sys.get_state(Store).exports[key].filesystem == nil end)
        failed = :sys.get_state(Store).exports[key]
        assert failed.phase == :failed
        refute is_nil(failed.failure)
        assert failed.cleanup_failure == nil
        assert failed.receipt == nil
        assert :ok = Store.dispose_scope(owned.scope, owned.generation)
        assert eventually(fn -> not Map.has_key?(:sys.get_state(Store).exports, key) end)
        after_dispose = :sys.get_state(Store)
        assert after_dispose.export_bytes == before.export_bytes - record.reserved_bytes
        assert filesystem_actors_for_run(after_dispose, key) == %{}

        refute Enum.any?(after_dispose.export_monitors, fn {_ref, actor} ->
                 actor == {key, filesystem}
               end)

        refute File.exists?(Path.join(Path.dirname(opts.save_to), ".crawler-fs-claims"))

        if refusal == :destination_exists,
          do: assert(File.read!(Path.join(opts.save_to, "keep")) == "existing destination")
      after
        :sys.resume(file_server)
      end
    end
  end

  test "retirement before an unclaimed acknowledgment retains custody until actual DOWN", c do
    opts = preclaim_options(c, :missing_root)
    file_server = Process.whereis(:file_server_2)
    owner = Process.whereis(Store)
    assert :ok = :sys.suspend(file_server)
    observer = self()
    task = Task.async(fn -> request_filesystem(opts, observer) end)

    try do
      assert_receive {:acquisition_owned, owned}, 5000
      key = {owned.scope, owned.generation}
      assert eventually(fn -> :sys.get_state(Store).exports[key].phase == :acquiring end)
      before = :sys.get_state(Store)
      record = before.exports[key]
      filesystem = record.filesystem
      nonce = record.nonce
      monitor = Process.monitor(filesystem)
      assert :ok = Store.dispose_scope(owned.scope, owned.generation)
      assert :sys.get_state(Store).exports[key].terminal.operation == :abort
      assert :ok = :sys.suspend(owner)
      assert :ok = :sys.resume(file_server)
      assert eventually(fn -> not Process.alive?(filesystem) end)

      assert eventually(fn ->
               {:messages, messages} = Process.info(owner, :messages)

               Enum.any?(
                 messages,
                 &match?(
                   {:crawler_filesystem_acquired, ^nonce, ^filesystem, {:error, :unclaimed, _}},
                   &1
                 )
               )
             end)

      after_ack = apply_queued_unclaimed(owner, filesystem, nonce)
      held = after_ack.exports[key]
      assert held.retired?
      assert held.phase == :unacquired
      assert held.cleanup_failure == nil
      assert held.receipt == nil
      assert held.filesystem == filesystem
      assert held.reserved_bytes == record.reserved_bytes
      assert after_ack.export_bytes == before.export_bytes
      assert after_ack.export_actors[filesystem] == key

      assert Enum.any?(after_ack.export_monitors, fn {_ref, actor} ->
               actor == {key, filesystem}
             end)

      assert :ok = :sys.resume(owner)
      assert_receive {:DOWN, ^monitor, :process, ^filesystem, :normal}, 5000
      assert Task.await(task, 5000) == {:warn, :stale}
      assert eventually(fn -> not Map.has_key?(:sys.get_state(Store).exports, key) end)
      assert :sys.get_state(Store).export_bytes == before.export_bytes - record.reserved_bytes
      refute File.exists?(Path.dirname(opts.save_to))
    after
      :sys.resume(file_server)
      :sys.resume(owner)
    end
  end

  test "a retired parked finalizer cannot acquire execution or reopen writers", c do
    opts = failed_target(c.opts)
    assert {:ok, closed} = Store.close_export(opts)
    Store.dispose_scope(c.scope)

    assert {:error, _} =
             Execution.run_finalizer(Map.merge(opts, closed), fn _ ->
               flunk("stale finalizer ran")
             end)

    assert {:error, :stale} = Store.export_status(opts)
    refute File.exists?(Path.join(c.root, "archive"))
  end

  test "render funding narrows an unshared reservation once after the sealed render frame", c do
    opts = failed_target(c.opts)
    assert {:ok, closed} = Store.close_export(opts)

    assert :ok =
             Execution.run_finalizer(Map.merge(opts, closed), fn owned ->
               assert {:ok, export} = Store.export_context(owned)
               assert {:ok, _} = Store.export_filesystem(owned, export.epoch)
               assert {:ok, overlap} = Store.reserve_resource(owned, :snapshot, 65_536)
               credit = %{retained: [], backing: [], overlap: overlap, unavailable: 128}
               assert {:ok, funding} = Store.resource_funding(owned, credit)

               assert {:error, :invalid_render_funding} =
                        Store.export_render_funding(owned, export.epoch, funding)

               assert {:ok, {:batch, [], cursor}, batch} =
                        Store.export_prepare_next(owned, export.epoch, closed.close_token, nil)

               Store.release_resource(batch)

               assert :done =
                        Store.export_prepare_next(owned, export.epoch, closed.close_token, cursor)

               assert {:ok, _, snapshot} =
                        Store.export_seal(owned, export.epoch, closed.close_token)

               assert {:ok, ^funding} =
                        Store.export_render_funding(owned, export.epoch, funding)

               assert {:error, {:limit, :receipt_capacity}} =
                        Store.export_finish_render(owned, export.epoch, funding, 65_537)

               assert :sys.get_state(Store).resources.receipts[overlap].actual == nil

               assert {:ok, fresh} =
                        Store.export_finish_render(owned, export.epoch, funding, 80)

               assert fresh == %{
                        funding
                        | overlap_capacity: 80,
                          grants: %{overlap => %{funding.grants[overlap] | capacity: 80}}
                      }

               assert Crawler.Export.StagedIO.credit_spec(fresh) == credit
               assert :sys.get_state(Store).resources.receipts[overlap].actual == 80

               assert {:error, :invalid_render_funding} =
                        Store.export_render_funding(owned, export.epoch, funding)

               assert {:error, :invalid_render_funding} =
                        Store.export_finish_render(owned, export.epoch, fresh, 1)

               Store.release_resource(overlap)
               Store.release_resource(snapshot)
               :ok
             end)
  end

  for ending <- [:abandon, :return, :killed] do
    test "a reserved write fails visibly before custody on #{ending}", c do
      parent = self()
      ending = unquote(ending)

      execute = fn ->
        Execution.run_job(c.opts, fn owned ->
          assert {:ok, export} = Store.export_context(owned)
          assert {:ok, _} = Store.export_filesystem(owned, export.epoch)

          assert {:ok, plan} =
                   Crawler.Export.StagedIO.plan_source("sources/abandoned", "x", make_ref())

          operation = make_ref()
          assert :ok = Store.export_reserve(owned, export.epoch, operation, plan)
          send(parent, {:reserved_write, owned, export.epoch, operation})

          case ending do
            :abandon ->
              assert :ok = Store.export_abandon(owned, export.epoch, operation, :fixture)
              :ok

            :return ->
              :ok

            :killed ->
              Process.exit(self(), :kill)
          end
        end)
      end

      if ending == :killed,
        do: assert(catch_exit(execute.()) == :killed),
        else: assert(execute.() == :ok)

      assert_receive {:reserved_write, owned, epoch, operation}
      opts = Map.drop(owned, [:execution_lease, :scheduler_claim, :crawler_deadline])

      assert eventually(fn ->
               match?(
                 {:ok, %{state: :failed, reason: {:snapshot, :export_io_failed}}},
                 Store.export_status(opts)
               )
             end)

      assert {:error, {:snapshot, :export_io_failed}} = Store.close_export(opts)
      refute Authority.export_writable?(opts.scope, opts.generation, opts.queue)
      record = :sys.get_state(Store).exports[{opts.scope, opts.generation}]
      assert record.epoch === epoch
      assert record.helper.session.pending[operation]
      refute File.exists?(Path.join(c.root, "archive"))
    end
  end

  defp finalize(opts, closed, before_commit \\ fn _, _ -> :ok end) do
    Execution.run_finalizer(Map.merge(opts, closed), fn owned ->
      assert owned.target_handle == closed.target_handle
      assert owned.scheduler_kind == :finalize
      assert {:ok, export} = Store.export_context(owned)
      assert export.job.id == closed.target_handle
      before = :sys.get_state(Store).resources

      assert {:error, :unstaged_metadata} =
               Store.export_prepared(
                 owned,
                 export.epoch,
                 closed.close_token,
                 make_ref(),
                 make_ref(),
                 []
               )

      assert :sys.get_state(Store).resources.used == before.used
      assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)

      assert {:ok, {:batch, [], cursor}, batch_receipt} =
               Store.export_prepare_next(owned, export.epoch, closed.close_token, nil)

      Store.release_resource(batch_receipt)

      assert :done =
               Store.export_prepare_next(owned, export.epoch, closed.close_token, cursor)

      assert {:ok, %{snapshot: snapshot, staged: %{}}, snapshot_receipt} =
               Store.export_seal(owned, export.epoch, closed.close_token)

      assert snapshot.artifacts == %{}
      assert snapshot.targets[opts.target_handle].outcome == :failed
      assert Authority.resource_current?(snapshot_receipt, owned.execution_lease, self())

      assert {:ok, overlap} =
               Store.reserve_resource(owned, :snapshot, owned.max_manifest_bytes)

      credit = %{retained: [], backing: [], overlap: overlap, unavailable: 0}
      assert {:ok, funding} = Store.resource_funding(owned, credit)

      context = %Context{
        job: export.job,
        opts: owned,
        executor: self(),
        filesystem: filesystem.filesystem,
        recovery_receipt: filesystem.receipt,
        resource_owner: Process.whereis(Store),
        start_io: &Store.start_export_io(owned, export.epoch, &1),
        render_funding: &Store.export_render_funding(owned, export.epoch, &1),
        finish_render: &Store.export_finish_render(owned, export.epoch, &1, &2),
        reserve: &Store.export_reserve(owned, export.epoch, &1, &2),
        written: &Store.export_written(owned, export.epoch, &1, &2),
        custody: &Store.export_custody(owned, export.epoch, &1, &2, &3),
        deliver: &Store.export_deliver(owned, export.epoch, &1, &2, &3),
        settled: &Store.export_settled(owned, export.epoch, &1, &2),
        abandon: &Store.export_abandon(owned, export.epoch, &1, &2)
      }

      Runtime.with_io(context, fn runtime ->
        assert {:ok, ack} =
                 Runtime.public_manifest(
                   runtime,
                   snapshot,
                   owned.max_manifest_bytes,
                   funding
                 )

        session = :sys.get_state(Store).exports[filesystem.run].helper.session

        operation = staged_operation(session, ack.plan)

        assert {:ok, prepared} = Runtime.prepare(runtime)
        before_commit.(filesystem, owned)
        assert Filesystem.prepared_for?(prepared, filesystem.receipt) == false
        assert {:ok, %{state: :finalizing, ready?: false}} = Store.export_status(owned)

        assert {:ok, :committed} =
                 Store.export_commit(
                   owned,
                   export.epoch,
                   closed.close_token,
                   snapshot.seal_token,
                   prepared,
                   operation
                 )

        Store.release_resource(snapshot_receipt)
        Store.release_resource(overlap)
        {:ok, :committed}
      end)
    end)
  end

  defp preclaim_options(c, :missing_root),
    do: %{c.opts | save_to: Path.join([c.root, "missing", "archive"])}

  defp preclaim_options(c, :destination_exists) do
    File.mkdir!(c.opts.save_to)
    File.write!(Path.join(c.opts.save_to, "keep"), "existing destination", [:exclusive])
    c.opts
  end

  defp request_filesystem(opts, observer) do
    Execution.run_job(opts, fn owned ->
      send(observer, {:acquisition_owned, owned})
      assert {:ok, export} = Store.export_context(owned)
      Store.export_filesystem(owned, export.epoch)
    end)
  end

  defp lifecycle_options(root, scope) do
    %{
      url: "https://example.test/root",
      scope: scope,
      save_to: Path.join(root, "archive"),
      max_body: 1024,
      max_analysis_bytes: 1_048_576,
      max_manifest_bytes: 262_144,
      attempt_timeout: 5000
    }
  end

  defp staged_operation(session, plan) do
    [{operation, _}] = Enum.filter(session.staged, fn {_, candidate} -> candidate == plan end)
    operation
  end

  defp assert_capacity_refusal(target, reason) do
    before = finalizer_wait_snapshot(target)
    assert before.target.status == {:waiting, :finalizer_driver}

    for await <- [&Store.await_direct/2, &Store.await_finalizer/2] do
      assert {:error, ^reason} = await.(target, Crawler.Deadline.after_ms(5000))
      assert finalizer_wait_snapshot(target) === before
      assert Process.alive?(Process.whereis(Store))
    end
  end

  defp finalizer_wait_snapshot(target) do
    state = :sys.get_state(Store)

    %{
      target: state.scheduler.frontier.jobs[target],
      direct:
        Map.take(state, [
          :direct_waiters,
          :direct_targets,
          :direct_owners,
          :direct_runs,
          :direct_workers,
          :direct_monitors,
          :waiting_workers,
          :waiting_refs,
          :waiting_bytes
        ])
    }
  end

  defp retained_headroom(state, opts) do
    options = Crawler.Store.ResourceManager.options(state, opts)

    min(options.max_retained_bytes, state.resources.limit) -
      state.resources.used - options.external_frontier_bytes
  end

  defp assert_unrelated_progress(opts) do
    scope = make_ref()
    on_exit(fn -> Store.dispose_scope(scope) end)
    assert :ok = Execution.run_job(%{opts | scope: scope, save_to: nil}, fn _ -> :ok end)
    assert Process.alive?(Process.whereis(Store))
  end

  defp failed_target(opts) do
    parent = self()

    assert Execution.run_job(opts, fn owned ->
             send(parent, {:admitted, owned})
             {:error, :fixture_failure}
           end) == {:error, :fixture_failure}

    assert_receive {:admitted, owned}, 5000
    assert eventually(fn -> idle?(owned) end)
    Map.drop(owned, [:execution_lease, :crawler_deadline, :scheduler_claim])
  end

  defp apply_queued_unclaimed(owner, filesystem, nonce) do
    :sys.replace_state(owner, fn state ->
      receive do
        {:crawler_filesystem_acquired, ^nonce, ^filesystem, {:error, :unclaimed, _} = result} ->
          ExportRun.acquired(state, nonce, filesystem, result)
      after
        0 -> flunk("the actual unclaimed acquisition result was not queued")
      end
    end)
  end

  defp apply_queued_terminal_result(owner, filesystem, nonce) do
    :sys.replace_state(owner, fn state ->
      receive do
        {:crawler_filesystem_terminal, ^filesystem, ^nonce, :finish, result} ->
          ExportRun.terminal_result(state, filesystem, nonce, :finish, result)
      after
        0 -> flunk("the actual terminal result was not queued")
      end
    end)
  end

  defp apply_queued_acquisition(owner, filesystem, nonce) do
    :sys.replace_state(owner, fn state ->
      receive do
        {:crawler_filesystem_acquired, ^nonce, ^filesystem, {:ok, receipt}} ->
          ExportRun.acquired(state, nonce, filesystem, {:ok, receipt})
      after
        0 -> flunk("the actual acquisition receipt was not queued")
      end
    end)
  end

  defp hold_returned_executor(owner, lease, executor, parent) do
    hook = make_ref()

    callback = fn
      :armed, {:in, {:"$gen_call", {^executor, _}, {:end_execution, ^lease}}}, _ ->
        :erlang.suspend_process(executor)
        send(parent, {:returned_executor_held, executor})
        :held

      state, _event, _name ->
        state
    end

    assert :ok = :sys.install(owner, {hook, callback, :armed})
    hook
  end

  defp hold_queued_cleanup(filesystem) do
    parent = self()
    hook = make_ref()

    callback = fn
      :armed, {:in, {:crawler_filesystem_terminate, _owner, nonce, :finish}}, _ ->
        send(parent, {:queued_cleanup_held, self(), nonce})

        receive do
          {:release_queued_cleanup, ^hook} -> :held
        end

      state, _event, _name ->
        state
    end

    assert :ok = :sys.install(filesystem, {hook, callback, :armed})
    hook
  end

  defp assert_paused_publication(opts, phase) do
    assert {:paused, _, _} = OPQ.info(opts.queue)

    for status <- [Crawler.export_status(opts), Store.export_status(opts, true)] do
      assert {:ok, %{state: ^phase, paused?: true, running?: false} = public} = status
      assert public.ready? == (phase == :ready)
    end

    refute Crawler.running?(opts)
  end

  defp published_files(opts) do
    manifest = File.read!(Path.join(opts.save_to, "manifest.json"))

    resources =
      Enum.map(Jason.decode!(manifest)["resources"], fn resource ->
        {resource["path"], File.read!(Path.join(opts.save_to, resource["path"]))}
      end)

    Map.new([{"manifest.json", manifest} | resources])
  end

  defp acquired_filesystem(opts) do
    parent = self()

    assert Execution.run_job(opts, fn owned ->
             assert {:ok, export} = Store.export_context(owned)
             assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)
             send(parent, {:acquired_filesystem, owned, filesystem.filesystem})
             {:error, :fixture_failure}
           end) == {:error, :fixture_failure}

    assert_receive {:acquired_filesystem, owned, filesystem}, 5000
    assert eventually(fn -> idle?(owned) end)
    {Map.drop(owned, [:execution_lease, :crawler_deadline, :scheduler_claim]), filesystem}
  end

  defp filesystem_actors_for_run(state, key) do
    Map.filter(state.export_actors, fn {_pid, run} -> run == key end)
  end

  defp idle?(opts) do
    state = :sys.get_state(Store)
    Crawler.Store.ExportRun.quiescent?(state, {opts.scope, opts.generation})
  end

  defp eventually(callback, attempts \\ 200)
  defp eventually(callback, 0), do: callback.()

  defp eventually(callback, attempts) do
    if callback.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(callback, attempts - 1)
        )
  end
end
