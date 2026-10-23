defmodule Crawler.Export.RuntimeTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis
  alias Crawler.Deadline
  alias Crawler.Export.Filesystem
  alias Crawler.Export.Runtime
  alias Crawler.Export.Runtime.Context
  alias Crawler.Export.StagedIO
  alias Crawler.Fetcher
  alias Crawler.IsolatedOwnerHelpers
  alias Crawler.Store
  alias Crawler.Store.Authority
  alias Crawler.Store.Execution
  alias Crawler.Store.Resources
  alias Crawler.Store.Retained

  @analysis_limits %{
    max_bytes: 1_000_000,
    max_total_bytes: 16_000_000,
    max_regions: 20_000,
    max_depth: 16,
    max_facts: 40_000,
    max_occurrences: 4000,
    max_edits: 4000,
    max_output_bytes: 2_000_000
  }
  @limits %{
    max_targets: 20,
    max_representations: 20,
    max_artifacts: 20,
    max_edges: 4000,
    max_manifest_bytes: 4_000_000,
    max_staged_bytes: 40_000_000,
    max_staged_metadata_bytes: 24_000_000,
    max_file_bytes: 16_000_000,
    max_files: 100
  }

  setup do
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(__MODULE__, fn conn ->
      if conn.request_path == "/copy" do
        conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.resp(200, "copy bytes")
      else
        source = ~s|<a href="/child">child</a><a href="/missing#fragment">missing</a>|
        conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.resp(200, source)
      end
    end)

    {tmp, 0} = System.cmd("pwd", ["-P"], cd: System.tmp_dir!())
    root = Path.join(String.trim(tmp), "runtime-" <> Base.encode16(:crypto.strong_rand_bytes(8)))
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    scope = make_ref()

    on_exit(fn ->
      if Process.whereis(Store) do
        Store.dispose_scope(scope)

        assert eventually(fn ->
                 not Enum.any?(:sys.get_state(Store).exports, fn {{owner, _}, _} ->
                   owner === scope
                 end)
               end)
      end

      File.rm_rf!(root)
      Req.Test.set_req_test_to_private()
    end)

    %{root: root, scope: scope, key: make_ref(), observer: self()}
  end

  test "real credited transport stages final cycles and safe fallbacks before filesystem prepare",
       fixture do
    {opts, targets} = produce_cycle(fixture)
    assert {:ok, closed} = Store.close_export(opts)

    assert :ok =
             Execution.run_finalizer(Map.merge(opts, closed), fn owned ->
               with_owned(fixture, owned, fn c ->
                 prepare_all(c, closed)

                 assert {:ok, %{snapshot: snapshot, staged: staged}, snapshot_receipt} =
                          Store.export_seal(owned, c.epoch, closed.close_token)

                 [first, second] = targets
                 assert snapshot.artifacts[first].path != snapshot.artifacts[second].path

                 assert :ok =
                          Runtime.with_io(context(c), fn runtime ->
                            for {target, child} <- [{first, second}, {second, first}] do
                              metadata = staged[snapshot.artifacts[target].analysis_handle]

                              funding =
                                workspace(
                                  c,
                                  0,
                                  @analysis_limits.max_total_bytes,
                                  metadata.unavailable
                                )

                              assert Resources.receipt(ledger(), funding.overlap).actual == nil

                              assert {:ok, ack, stats} =
                                       Runtime.render(runtime, snapshot, target, staged, funding)

                              assert stats.budget.counts.occurrences == 2
                              assert stats.budget.limit == @analysis_limits.max_total_bytes

                              assert stats.budget.caps ==
                                       staged[snapshot.artifacts[target].analysis_handle].bound_budget.caps

                              output =
                                File.read!(Path.join([c.receipt.stage, "archive", ack.plan.path]))

                              assert byte_size(output) < 1024
                              assert output =~ Path.basename(snapshot.artifacts[child].path)
                              assert output =~ "https://example.test/missing#fragment"
                              refute output =~ "secret"
                              refute output =~ "user@"
                              assert is_reference(ack.operation)
                              assert session(c).staged[ack.operation] === ack.plan

                              assert :ok =
                                       Store.export_rendered(
                                         owned,
                                         c.epoch,
                                         snapshot.seal_token,
                                         target,
                                         ack.operation
                                       )

                              assert_render_commit(c, funding, output)
                            end

                            manifest_funding = workspace(c, 0, @limits.max_manifest_bytes)

                            assert {:ok, manifest_ack} =
                                     Runtime.public_manifest(
                                       runtime,
                                       snapshot,
                                       @limits.max_manifest_bytes,
                                       manifest_funding
                                     )

                            manifest_path =
                              Path.join([c.receipt.stage, "archive", "manifest.json"])

                            manifest_output = File.read!(manifest_path)
                            refute manifest_output =~ "secret"
                            assert_render_commit(c, manifest_funding, manifest_output)
                            assert is_reference(manifest_ack.operation)

                            assert :ok =
                                     Crawler.Export.Session.validate_commit(
                                       session(c),
                                       c.epoch,
                                       snapshot.seal_token,
                                       c.job.id,
                                       manifest_ack.operation
                                     )

                            assert {:ok, prepared} = Runtime.prepare(runtime)
                            assert is_tuple(prepared)
                            refute File.exists?(Path.join(c.root, "archive"))
                            assert {:error, :not_owner} = Filesystem.cancel(prepared)
                            assert {:error, :not_terminal} = Filesystem.finish(c.fs)
                            send(c.observer, {c.key, :prepared_filesystem, c.fs})

                            assert Enum.count(events(c), &match?({:finish_render, _, _, _}, &1)) ==
                                     3

                            :ok
                          end)

                 Store.release_resource(snapshot_receipt)
                 :ok
               end)
             end)

    assert_owned_completed(fixture, closed.target_handle)
    assert_receive {key, :prepared_filesystem, filesystem} when key == fixture.key
    assert Process.alive?(filesystem)
    filesystem_monitor = Process.monitor(filesystem)
    Store.dispose_scope(fixture.scope)
    assert_receive {:DOWN, ^filesystem_monitor, :process, ^filesystem, _}, 5000

    assert eventually(fn ->
             not Enum.any?(:sys.get_state(Store).exports, fn {{scope, _}, _} ->
               scope === fixture.scope
             end)
           end)

    refute File.exists?(Path.join(fixture.root, "archive"))
    all_events = observed_events(fixture)
    assert Enum.count(all_events, &match?({:custody, _, _}, &1)) == 7
    assert Enum.count(all_events, &match?({:settled, _}, &1)) == 7
  end

  test "one companion is reused and nested or reentrant work is rejected", fixture do
    with_context(fixture, fn c ->
      initial = context(c)

      context = %{
        initial
        | reserve: fn operation, plan ->
            assert {:error, :operation_pending} = Runtime.prepare(Process.get({c.key, :runtime}))
            initial.reserve.(operation, plan)
          end
      }

      assert :ok =
               Runtime.with_io(context, fn runtime ->
                 Process.put({c.key, :runtime}, runtime)
                 assert {:error, :already_running} = Runtime.with_io(context, fn _ -> flunk() end)

                 assert {:ok, _} =
                          Runtime.stage_source(
                            runtime,
                            "one",
                            "one",
                            make_ref(),
                            :retained,
                            workspace(c)
                          )

                 assert {:ok, _} =
                          Runtime.stage_source(
                            runtime,
                            "two",
                            "two",
                            make_ref(),
                            :retained,
                            workspace(c)
                          )

                 companions = for {:custody, _, companion} <- events(c), do: companion
                 assert Enum.uniq(companions) == [runtime.companion]
                 assert Process.alive?(runtime.companion)
                 send(self(), {c.key, :companion, runtime.companion})
                 :ok
               end)

      assert_receive {key, :companion, companion} when key == c.key
      refute Process.alive?(companion)
    end)
  end

  test "fetch jobs cannot render or prepare managed publication", fixture do
    with_context(fixture, fn c ->
      assert :ok =
               Runtime.with_io(context(c), fn runtime ->
                 assert {:error, :wrong_job_kind} =
                          Runtime.render(runtime, nil, make_ref(), %{}, c.funding)

                 assert {:error, :wrong_job_kind} =
                          Runtime.public_manifest(
                            runtime,
                            nil,
                            @limits.max_manifest_bytes,
                            c.funding
                          )

                 assert {:error, :wrong_job_kind} = Runtime.prepare(runtime)
                 assert events(c) == []
                 :ok
               end)
    end)
  end

  test "revoked real grants reject source transport before any host reservation", fixture do
    with_context(fixture, fn c ->
      assert :ok = Store.release_resource(c.retained)

      assert :ok =
               Runtime.with_io(context(c), fn runtime ->
                 assert {:error, :stale_resource} =
                          Runtime.stage_source(
                            runtime,
                            "revoked",
                            "body",
                            make_ref(),
                            :retained,
                            c.funding
                          )

                 assert events(c) == []
                 refute File.exists?(Path.join([c.receipt.stage, "source", "revoked"]))
                 :ok
               end)
    end)
  end

  test "companion death abandons and poisons the helper while real custodian grants remain",
       fixture do
    controller = self()
    completed = make_ref()

    with_context(fixture, fn c ->
      initial = context(c)
      assert :erlang.suspend_process(c.fs)

      try do
        context = %{
          initial
          | deliver: fn companion, credit, payload ->
              {:ok, reference, io_funding} = initial.deliver.(companion, credit, payload)
              Process.exit(companion, :kill)
              monitor = Process.monitor(companion)
              assert_receive {:DOWN, ^monitor, :process, ^companion, _}
              {:ok, reference, io_funding}
            end
        }

        assert :ok =
                 Runtime.with_io(context, fn runtime ->
                   assert {:error, :companion_down} =
                            Runtime.stage_source(
                              runtime,
                              "abandoned",
                              "body",
                              make_ref(),
                              :retained,
                              workspace(c)
                            )

                   assert {:error, :inactive_runtime} =
                            Runtime.stage_source(
                              runtime,
                              "late",
                              "late",
                              make_ref(),
                              :retained,
                              c.funding
                            )

                   assert Enum.count(events(c), &match?({:custody, _, _}, &1)) == 1
                   assert Enum.count(events(c), &match?({:abandon, _, _}, &1)) == 1
                   refute Enum.any?(events(c), &match?({:settled, _}, &1))
                   refute Enum.any?(events(c), &match?({:written, _}, &1))
                   assert Process.alive?(c.fs)

                   for receipt <- receipts(current_credit(c)) do
                     assert Resources.receipt(ledger(), receipt).holders[Process.whereis(Store)]

                     assert Authority.resource_current?(
                              receipt,
                              c.opts.execution_lease,
                              Process.whereis(Store)
                            )
                   end

                   refute File.exists?(Path.join([c.receipt.stage, "source", "late"]))
                   :ok
                 end)
      after
        if Process.alive?(c.fs), do: :erlang.resume_process(c.fs)
      end

      assert eventually(fn -> not Process.alive?(c.fs) end)

      assert eventually(fn ->
               row = :sys.get_state(Store).export_io[c.opts.execution_lease]

               row.status == :poisoned and row.down? and
                 row.held == MapSet.new([row.metadata_receipt])
             end)

      for receipt <- receipts(current_credit(c)) do
        row = Resources.receipt(ledger(), receipt)
        assert is_nil(row) or not Map.has_key?(row.holders, Process.whereis(Store))
      end

      send(controller, {completed, c.opts.execution_lease})
    end)

    assert_receive {^completed, lease}
    assert eventually(fn -> :sys.get_state(Store).export_io[lease] == nil end)
  end

  test "a throwing reservation abandons the exact operation and stops the companion", fixture do
    with_context(fixture, fn c ->
      initial = context(c)

      context = %{
        initial
        | reserve: fn operation, plan ->
            :ok = initial.reserve.(operation, plan)
            raise "reservation callback failed"
          end,
          abandon: fn operation, reason ->
            assert :ok = Store.export_abandon(c.opts, c.epoch, operation, reason)

            assert {:ok, %{state: :failed, reason: {:snapshot, :export_io_failed}}} =
                     Store.export_status(c.opts)

            assert Map.has_key?(session(c).pending, operation)
            event(c, {:abandon, operation, reason})
          end
      }

      assert_raise RuntimeError, "reservation callback failed", fn ->
        Runtime.with_io(context, fn runtime ->
          send(self(), {c.key, :companion, runtime.companion})

          Runtime.stage_source(
            runtime,
            "callback-failed",
            "body",
            make_ref(),
            :retained,
            workspace(c)
          )
        end)
      end

      assert_receive {key, :companion, companion} when key == c.key
      refute Process.alive?(companion)

      assert [
               {:abandon, operation, {:error, {:operation_raised, :error, %RuntimeError{}}}},
               {:reserved, operation}
             ] = events(c)

      assert Map.has_key?(session(c).pending, operation)
      refute Enum.any?(events(c), &match?({:settled, _}, &1))
      refute Enum.any?(events(c), &match?({:written, _}, &1))
      refute File.exists?(Path.join([c.receipt.stage, "source", "callback-failed"]))
    end)
  end

  test "filesystem rejection abandons custody and prevents subsequent work", fixture do
    with_context(fixture, fn c ->
      initial = context(c)

      context = %{
        initial
        | abandon: fn operation, reason ->
            assert :erlang.suspend_process(c.fs)
            initial.abandon.(operation, reason)
          end
      }

      try do
        assert :ok =
                 Runtime.with_io(context, fn runtime ->
                   assert {:ok, _} =
                            Runtime.stage_source(
                              runtime,
                              "duplicate",
                              "one",
                              make_ref(),
                              :retained,
                              workspace(c)
                            )

                   rejected = Path.join([c.receipt.stage, "source", "rejected"])
                   File.write!(rejected, "occupied", [:exclusive])

                   assert {:error, _} =
                            Runtime.stage_source(
                              runtime,
                              "rejected",
                              "two",
                              make_ref(),
                              :retained,
                              workspace(c)
                            )

                   assert {:error, :inactive_runtime} =
                            Runtime.stage_source(
                              runtime,
                              "third",
                              "three",
                              make_ref(),
                              :retained,
                              c.funding
                            )

                   assert Enum.count(events(c), &match?({:settled, _}, &1)) == 1
                   assert Enum.count(events(c), &match?({:abandon, _, _}, &1)) == 1
                   assert File.read!(Path.join([c.receipt.stage, "source", "duplicate"])) == "one"
                   assert File.read!(rejected) == "occupied"
                   refute File.exists?(Path.join([c.receipt.stage, "source", "third"]))
                   File.rm!(rejected)
                   :ok
                 end)
      after
        if Process.alive?(c.fs), do: :erlang.resume_process(c.fs)
      end
    end)
  end

  test "no callback runs before the exact owner actor READY message", fixture do
    parent = self()
    gate = make_ref()

    task =
      Task.async(fn ->
        with_context(fixture, fn c ->
          initial = context(c)

          context = %{
            initial
            | start_io: fn nonce ->
                {:ok, io} = initial.start_io.(nonce)
                lease = c.opts.execution_lease
                assert_receive {:crawler_export_io_ready, ^nonce, ^io, ^lease}, 1000
                send(self(), {:crawler_export_io_ready, make_ref(), io, lease})
                send(self(), {:crawler_export_io_ready, nonce, self(), lease})
                send(self(), {:crawler_export_io_ready, nonce, io, make_ref()})
                send(parent, {gate, :held_ready, self(), nonce, io, lease})
                {:ok, io}
              end
          }

          assert :ok =
                   Runtime.with_io(context, fn runtime ->
                     send(parent, {gate, :callback, runtime.companion})

                     assert :sys.get_state(Store).export_io[c.opts.execution_lease].status ==
                              :idle

                     :ok
                   end)
        end)
      end)

    assert_receive {^gate, :held_ready, executor, nonce, io, lease}, 5000
    refute_receive {^gate, :callback, _}, 100
    send(executor, {:crawler_export_io_ready, nonce, io, lease})
    assert_receive {^gate, :callback, ^io}, 1000
    assert Task.await(task, 5000) == :ok
  end

  test "copy rendering and manifest narrow their own real overlaps once", fixture do
    opts = produce_copy(fixture)
    assert {:ok, closed} = Store.close_export(opts)

    assert :ok =
             Execution.run_finalizer(Map.merge(opts, closed), fn owned ->
               with_owned(fixture, owned, fn c ->
                 prepare_all(c, closed)

                 assert {:ok, %{snapshot: snapshot, staged: staged}, snapshot_receipt} =
                          Store.export_seal(owned, c.epoch, closed.close_token)

                 assert :ok =
                          Runtime.with_io(context(c), fn runtime ->
                            funding = workspace(c, 0, 65_536)

                            assert {:ok, ack, nil} =
                                     Runtime.render(
                                       runtime,
                                       snapshot,
                                       opts.target_handle,
                                       staged,
                                       funding
                                     )

                            output =
                              File.read!(Path.join([c.receipt.stage, "archive", ack.plan.path]))

                            assert output == "copy bytes"
                            assert_render_commit(c, funding, output)

                            assert :ok =
                                     Store.export_rendered(
                                       owned,
                                       c.epoch,
                                       snapshot.seal_token,
                                       opts.target_handle,
                                       ack.operation
                                     )

                            manifest = workspace(c, 0, @limits.max_manifest_bytes)
                            assert manifest.overlap != funding.overlap

                            assert {:ok, manifest_ack} =
                                     Runtime.public_manifest(
                                       runtime,
                                       snapshot,
                                       @limits.max_manifest_bytes,
                                       manifest
                                     )

                            assert_render_commit(
                              c,
                              manifest,
                              File.read!(
                                Path.join([c.receipt.stage, "archive", manifest_ack.plan.path])
                              )
                            )

                            assert Enum.count(events(c), &match?({:finish_render, _, _, _}, &1)) ==
                                     2

                            :ok
                          end)

                 Store.release_resource(snapshot_receipt)
                 :ok
               end)
             end)

    assert_owned_completed(fixture, closed.target_handle)
  end

  test "render funding rejects unsealed, stale, shared and over-capacity reservations", fixture do
    opts = failed_target(fixture)
    assert {:ok, closed} = Store.close_export(opts)

    assert :ok =
             Execution.run_finalizer(Map.merge(opts, closed), fn owned ->
               with_owned(fixture, owned, fn c ->
                 funding = workspace(c, 0, 65_536, 128)

                 assert {:error, :invalid_render_funding} =
                          Store.export_render_funding(owned, c.epoch, funding)

                 assert {:error, :invalid_render_funding} =
                          Store.export_finish_render(owned, c.epoch, funding, 80)

                 prepare_all(c, closed)

                 assert {:ok, _, snapshot_receipt} =
                          Store.export_seal(owned, c.epoch, closed.close_token)

                 assert {:ok, ^funding} = Store.export_render_funding(owned, c.epoch, funding)

                 assert {:error, {:limit, :receipt_capacity}} =
                          Store.export_finish_render(owned, c.epoch, funding, 65_537)

                 assert Resources.receipt(ledger(), funding.overlap).actual == nil
                 assert {:error, _} = Store.export_render_funding(owned, make_ref(), funding)
                 assert {:ok, fresh} = Store.export_finish_render(owned, c.epoch, funding, 80)

                 assert fresh == %{
                          funding
                          | overlap_capacity: 80,
                            grants: %{
                              funding.overlap => %{funding.grants[funding.overlap] | capacity: 80}
                            }
                        }

                 assert StagedIO.credit_spec(fresh) == StagedIO.credit_spec(funding)
                 assert Resources.receipt(ledger(), funding.overlap).actual == 80

                 assert {:error, :invalid_render_funding} =
                          Store.export_render_funding(owned, c.epoch, funding)

                 assert {:error, :invalid_render_funding} =
                          Store.export_finish_render(owned, c.epoch, fresh, 1)

                 shared = workspace(c, 0, 65_536)

                 holder =
                   spawn(fn ->
                     receive do
                       :stop -> :ok
                     end
                   end)

                 try do
                   assert :ok = Store.retain_resource(shared.overlap, holder)

                   assert {:error, :invalid_render_funding} =
                            Store.export_render_funding(owned, c.epoch, shared)
                 after
                   Process.exit(holder, :kill)
                 end

                 Store.release_resource(snapshot_receipt)
                 :ok
               end)
             end)

    assert_owned_completed(fixture, closed.target_handle)
  end

  test "an idle Runtime actor shares the accepted attempt deadline", fixture do
    parent = self()

    assert {:error, {:deadline, :attempt}} =
             Execution.run_job(Map.put(options(fixture), :attempt_timeout, 1000), fn owned ->
               with_owned(fixture, owned, fn c ->
                 Runtime.with_io(context(c), fn runtime ->
                   send(parent, {:runtime_deadline, runtime.companion, owned.execution_lease})

                   receive do
                     :never -> flunk("deadline was not enforced")
                   end
                 end)
               end)
             end)

    assert_receive {:runtime_deadline, companion, lease}, 1000

    assert eventually(fn ->
             not Process.alive?(companion) and :sys.get_state(Store).export_io[lease] == nil
           end)
  end

  test "producer death during a real blocked filesystem call retains custody until filesystem DOWN",
       fixture do
    controller = self()
    barrier = make_ref()
    task = Task.async(fn -> blocked_producer(fixture, controller, barrier) end)
    assert_receive {^barrier, executor, filesystem, companion, lease, credit}, 5000
    assert :erlang.suspend_process(filesystem)
    filesystem_monitor = Process.monitor(filesystem)
    companion_monitor = Process.monitor(companion)
    executor_monitor = Process.monitor(executor)

    try do
      send(executor, {barrier, :write})
      assert eventually(fn -> filesystem_reservation_queued?(filesystem, companion) end)
      row = :sys.get_state(Store).export_io[lease]
      assert row.status == :delivered
      assert row.io === companion
      assert row.filesystem === filesystem
      held = MapSet.to_list(row.held)
      assert Enum.all?(receipts(credit), &(&1 in held))
      assert length(held) == length(receipts(credit)) + 2

      for receipt <- held,
          do: assert(Resources.receipt(ledger(), receipt).holders[Process.whereis(Store)])

      Process.exit(executor, :kill)
      assert_receive {:DOWN, ^executor_monitor, :process, ^executor, :killed}, 1000
      assert Task.await(task, 5000) == {:executor_exit, :killed}
      assert_receive {:DOWN, ^companion_monitor, :process, ^companion, _}, 2000
      assert Process.alive?(filesystem)
      row = :sys.get_state(Store).export_io[lease]
      assert row.status == :poisoned
      assert row.ended?

      for receipt <- held,
          do: assert(Resources.receipt(ledger(), receipt).holders[Process.whereis(Store)])

      refute File.exists?(Path.join(fixture.root, "archive"))
      assert Enum.count(observed_events(fixture), &match?({:settled, _}, &1)) == 0
    after
      if Process.alive?(filesystem), do: :erlang.resume_process(filesystem)
    end

    assert_receive {:DOWN, ^filesystem_monitor, :process, ^filesystem, _}, 5000
    assert eventually(fn -> :sys.get_state(Store).export_io[lease] == nil end)

    for receipt <- receipts(credit) do
      row = Resources.receipt(ledger(), receipt)
      assert is_nil(row) or not Map.has_key?(row.holders, Process.whereis(Store))
    end

    refute File.exists?(Path.join(fixture.root, "archive"))
  end

  test "the original actor deadline survives Store and executor death during a blocked filesystem call",
       fixture do
    controller = self()
    barrier = make_ref()
    owner = Process.whereis(Store)
    task = Task.async(fn -> parent_runtime_guard(fixture, controller, barrier) end)

    try do
      assert_receive {^barrier, :parent_ready, executor, %Deadline{} = parent_deadline}, 5000
      remaining = min(8000, Deadline.remaining(parent_deadline) - 1500)
      assert remaining > 0
      watchdog = Deadline.after_ms(remaining)

      child =
        IsolatedOwnerHelpers.start(fixture.root, __MODULE__, :owner_death_case, __ENV__.file)

      try do
        assert :ok = IsolatedOwnerHelpers.await(child, watchdog)
        assert :ok = IsolatedOwnerHelpers.cleanup(child)
        assert Process.whereis(Store) === owner
        assert Process.alive?(owner)
        send(executor, {barrier, :child_done})
        assert Task.await(task, 1000) == :ok
      after
        IsolatedOwnerHelpers.cleanup(child)
      end
    after
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end
  end

  @doc false
  def owner_death_case(fixture) do
    controller = self()
    barrier = make_ref()
    task = Task.async(fn -> blocked_producer(fixture, controller, barrier, 2000) end)
    assert_receive {^barrier, executor, filesystem, companion, lease, _credit}, 5000
    assert_receive {^barrier, :original_deadline, %Deadline{} = deadline, target}, 1000
    assert deadline.kind == :attempt
    assert :erlang.suspend_process(filesystem)
    owner = Process.whereis(Store)
    owner_monitor = Process.monitor(owner)
    filesystem_monitor = Process.monitor(filesystem)
    companion_monitor = Process.monitor(companion)
    executor_monitor = Process.monitor(executor)

    try do
      send(executor, {barrier, :write})
      assert eventually(fn -> filesystem_reservation_queued?(filesystem, companion) end)
      row = :sys.get_state(Store).export_io[lease]
      assert row.status == :delivered
      assert row.io === companion
      assert row.worker === executor
      assert row.filesystem === filesystem
      assert :ok = :sys.suspend(owner)
      Process.exit(executor, :kill)
      assert_receive {:DOWN, ^executor_monitor, :process, ^executor, :killed}, 1000
      assert eventually(fn -> discard_return_queued?(owner, task.pid, executor) end)
      assert Deadline.remaining(deadline) > 0
      assert Process.alive?(companion)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 1000

      assert {:executor_exit,
              {:killed, {GenServer, :call, [Store, {:discard_execution_return, ^executor}, 5000]}}} =
               Task.await(task, 5000)

      reason = {:deadline, deadline.kind}

      assert_receive {:DOWN, ^companion_monitor, :process, ^companion, ^reason},
                     Deadline.remaining(deadline) + 1000

      assert Deadline.now() >= deadline.at
      assert Process.alive?(filesystem)
      assert Process.whereis(Store) == nil
      refute File.exists?(Path.join(fixture.root, "archive"))
      key = fixture.key
      refute_receive {^key, :owned_callback_ran, ^target}, 0
      assert Enum.count(observed_events(fixture), &match?({:settled, _}, &1)) == 0
    after
      if Process.alive?(owner), do: :sys.resume(owner)
      if Process.alive?(filesystem), do: :erlang.resume_process(filesystem)
    end

    assert_receive {:DOWN, ^filesystem_monitor, :process, ^filesystem, _}, 5000
    refute File.exists?(Path.join(fixture.root, "archive"))
    assert {:ok, _} = File.rm_rf(fixture.root)
    refute File.exists?(fixture.root)
    :ok
  end

  test "filesystem death stops the actor and prevents the next reservation", fixture do
    owner = Process.whereis(Store)

    child =
      IsolatedOwnerHelpers.start(fixture.root, __MODULE__, :filesystem_death_case, __ENV__.file)

    try do
      assert :ok = IsolatedOwnerHelpers.await(child, Deadline.after_ms(10_000))
      assert Process.whereis(Store) === owner
      assert Process.alive?(owner)
    after
      IsolatedOwnerHelpers.cleanup(child)
    end
  end

  @doc false
  def filesystem_death_case(fixture) do
    with_context(fixture, fn c ->
      run = {c.opts.scope, c.opts.generation}
      before = :sys.get_state(Store).exports[run]
      journal = File.read!(Path.join(c.receipt.claim, "journal"))

      assert :ok = Runtime.with_io(context(c), &assert_filesystem_death(&1, c))

      assert eventually(fn -> :sys.get_state(Store).exports[run].phase == :cleanup_failed end)
      failure = :sys.get_state(Store).exports[run].failure
      refute is_nil(failure)
      send(c.observer, {c.key, :unproved_recovery, c.opts, before, failure, journal})
    end)

    key = fixture.key
    assert_receive {^key, :unproved_recovery, owned, before, failure, journal}, 1000
    run = {owned.scope, owned.generation}
    assert :ok = Store.dispose_scope(owned.scope, owned.generation)

    assert eventually(fn ->
             state = :sys.get_state(Store)
             recovery = state.exports[run]

             recovery.retired? and recovery.phase == :cleanup_failed and
               not Enum.any?(state.export_io, fn {_lease, row} -> row.run == run end) and
               not Enum.any?(state.executions, fn {_lease, row} ->
                 row.opts.scope == owned.scope
               end)
           end)

    state = :sys.get_state(Store)
    recovery = state.exports[run]

    assert Enum.filter(state.exports, fn {{scope, _}, _} -> scope == owned.scope end) == [
             {run, recovery}
           ]

    assert recovery.retired?
    assert recovery.phase == :cleanup_failed
    assert recovery.failure == failure
    assert recovery.cleanup_failure == {:snapshot, :cleanup_failed}
    assert recovery.filesystem == nil
    assert recovery.terminal == nil
    assert recovery.receipt == before.receipt
    assert recovery.reserved_bytes == before.reserved_bytes
    assert state.export_bytes == before.reserved_bytes
    assert {:ok, _} = Retained.bytes(recovery.receipt, recovery.reserved_bytes)
    refute Enum.any?(state.export_actors, fn {_pid, owner} -> owner == run end)
    refute Enum.any?(state.export_monitors, fn {_ref, {owner, _pid}} -> owner == run end)
    assert recovery.helper.session.pending == %{}
    assert recovery.helper.session.staged == %{}
    assert File.dir?(recovery.receipt.stage)
    assert File.dir?(recovery.receipt.claim)
    assert File.read!(Path.join(recovery.receipt.claim, "owner")) == recovery.receipt.header
    assert File.read!(Path.join(recovery.receipt.claim, "journal")) == journal
    refute File.exists?(Path.join([recovery.receipt.stage, "source", "after-fs-death"]))
    refute File.exists?(Path.join(fixture.root, "archive"))

    assert {:ok, %{state: :failed, reason: {:snapshot, :cleanup_failed}, ready?: false}} =
             Store.export_status(detached(owned))

    assert :stale = Store.dispose_scope(owned.scope, owned.generation)
    assert :sys.get_state(Store).exports[run] == recovery
    :ok
  end

  defp assert_filesystem_death(runtime, c) do
    monitor = Process.monitor(c.fs)
    Process.exit(c.fs, :kill)
    assert_receive {:DOWN, ^monitor, :process, filesystem, :killed} when filesystem == c.fs
    assert eventually(fn -> not Process.alive?(runtime.companion) end)

    assert {:error, _} =
             Runtime.stage_source(
               runtime,
               "after-fs-death",
               "body",
               make_ref(),
               :retained,
               c.funding
             )

    assert events(c) == []
    refute File.exists?(Path.join([c.receipt.stage, "source", "after-fs-death"]))
    :ok
  end

  test "Context requires every owner callback and refuses an invalid callback before startup",
       fixture do
    required = [
      :start_io,
      :render_funding,
      :finish_render,
      :reserve,
      :written,
      :custody,
      :deliver,
      :settled,
      :abandon
    ]

    with_context(fixture, fn c ->
      initial = context(c)

      for name <- required do
        assert {:error, :invalid_callbacks} =
                 Runtime.with_io(Map.put(initial, name, nil), fn _ ->
                   flunk("invalid context ran")
                 end)
      end

      assert :sys.get_state(Store).export_io[c.opts.execution_lease] == nil
      assert events(c) == []
    end)
  end

  defp parent_runtime_guard(fixture, controller, barrier) do
    with_context(fixture, fn c ->
      Runtime.with_io(context(c), fn runtime ->
        owner = Process.whereis(Store)
        before = parent_obligations(c, runtime, owner)
        send(controller, {barrier, :parent_ready, self(), c.opts.crawler_deadline})

        receive do
          {^barrier, :child_done} -> :ok
        after
          Deadline.remaining(c.opts.crawler_deadline) ->
            flunk("child did not complete within the parent lease")
        end

        assert Process.whereis(Store) === owner
        assert Process.alive?(owner)
        assert parent_obligations(c, runtime, owner) === before
        assert events(c) == []
        :ok
      end)
    end)
  end

  defp parent_obligations(c, runtime, owner) do
    state = :sys.get_state(owner)
    lease = c.opts.execution_lease
    row = Map.fetch!(state.export_io, lease)
    assert row.io === runtime.companion
    assert row.status == :idle
    assert Process.alive?(runtime.companion)
    assert Process.alive?(c.fs)
    assert Authority.execution_current?(lease, self())
    assert Authority.current?(c.opts.scope, c.opts.generation, c.opts.queue, lease)
    assert Authority.resource_current?(row.metadata_receipt, lease, owner)

    receipts =
      Map.filter(state.resources.receipts, fn {_reference, record} -> record.lease === lease end)

    for receipt <- Map.keys(c.funding.grants),
        do: assert(Authority.resource_current?(receipt, lease, self()))

    %{
      execution: Map.fetch!(state.executions, lease),
      export: Map.fetch!(state.exports, {c.opts.scope, c.opts.generation}),
      io: row,
      receipts: receipts,
      root_entries: Enum.sort(File.ls!(c.root))
    }
  end

  defp blocked_producer(fixture, controller, barrier, timeout \\ 10_000) do
    try do
      Execution.run_job(Map.put(options(fixture), :attempt_timeout, timeout), fn owned ->
        with_owned(fixture, owned, &blocked_runtime(&1, controller, barrier))
      end)
    catch
      :exit, reason -> {:executor_exit, reason}
    end
  end

  defp blocked_runtime(c, controller, barrier) do
    initial = context(c)

    context = %{
      initial
      | deliver: fn companion, credit, payload ->
          result = initial.deliver.(companion, credit, payload)
          send(controller, {barrier, self(), c.fs, companion, c.opts.execution_lease, credit})

          send(
            controller,
            {barrier, :original_deadline, c.opts.crawler_deadline, c.opts.target_handle}
          )

          receive do
            {^barrier, :write} -> result
          end
        end
    }

    Runtime.with_io(context, fn runtime ->
      Runtime.stage_source(runtime, "blocked", "body", make_ref(), :retained, workspace(c))
      flunk("the killed producer completed its blocked call")
    end)
  end

  defp discard_return_queued?(owner, caller, executor) do
    {:messages, messages} = Process.info(owner, :messages)

    Enum.any?(messages, fn
      {:"$gen_call", {^caller, _}, {:discard_execution_return, ^executor}} -> true
      _ -> false
    end)
  end

  defp filesystem_reservation_queued?(filesystem, companion) do
    {:messages, messages} = Process.info(filesystem, :messages)

    Enum.any?(messages, fn
      {:"$gen_call", {^companion, _}, {:reserve, :source, "blocked", 4}} -> true
      _ -> false
    end)
  end

  defp producer(c, runtime, child, mode) do
    assert %Crawler.Store.Page{} = page = Fetcher.fetch(Map.put(c.opts, :save_to, nil))
    revision = page.source_revision
    assert is_reference(revision)
    assert {:ok, export} = Store.export_context(c.opts)
    assignment = export.assignment
    assert Crawler.Export.Paths.public_id?(assignment.public_id)

    assert {:ok, source_ack} =
             Runtime.stage_source(
               runtime,
               assignment.source_path,
               page.body,
               revision,
               :borrowed,
               producer_workspace(c, page)
             )

    assert :ok =
             Store.export_source(
               c.opts,
               c.epoch,
               source_ack.operation,
               page.opts.content_type,
               page.opts.url
             )

    if mode == :copy do
      descriptor = %{
        source_operation: source_ack.operation,
        source_revision: revision,
        lexical_operation: nil,
        analysis_revision: nil,
        public_id: assignment.public_id,
        render_mode: :copy
      }

      assert {:ok, 1} = Store.export_candidate(c.opts, c.epoch, 0, descriptor, %{})

      bound = %{
        operation: source_ack.operation,
        source_revision: revision,
        analysis_revision: nil,
        css_stamp: nil,
        edges_digest: StagedIO.edge_digest([])
      }

      assert :ok = Store.export_discovered(c.opts, c.epoch, 1, %{}, bound)
    else
      analysis = page.analysis
      original = page.interpretation.collection

      assert {:ok, bound} = Analysis.bind(original, &child_target(&1, child))

      assert {:ok, metadata_ack} =
               Runtime.stage_metadata(
                 runtime,
                 assignment.lexical_path,
                 analysis,
                 original,
                 bound,
                 :final_css,
                 revision,
                 %{unavailable: page.credit.unavailable, root: :borrowed},
                 producer_workspace(c, page)
               )

      descriptor = %{
        source_operation: source_ack.operation,
        source_revision: revision,
        lexical_operation: metadata_ack.operation,
        analysis_revision: analysis.revision,
        public_id: assignment.public_id,
        render_mode: :rewrite
      }

      assert {:ok, 1} = Store.export_candidate(c.opts, c.epoch, 0, descriptor, %{})

      frozen = %{
        operation: metadata_ack.operation,
        source_revision: revision,
        analysis_revision: analysis.revision,
        css_stamp: :final_css,
        edges_digest: StagedIO.edge_digest(bound.occurrences)
      }

      assert :ok = Store.export_discovered(c.opts, c.epoch, 1, %{}, frozen)
    end

    :ok
  end

  defp child_target(%{value: "/child"}, child), do: child
  defp child_target(_occurrence, _child), do: nil

  defp produce_owned(fixture, owned, child, mode) do
    with_owned(fixture, owned, fn c ->
      Runtime.with_io(context(c), &producer(c, &1, child, mode))
    end)
  end

  defp produce_cycle(fixture) do
    parent = self()

    jobs =
      for letter <- ["a", "b"] do
        Task.async(fn ->
          assert :ok =
                   Execution.run_job(
                     %{options(fixture) | url: "https://user:secret@example.test/" <> letter},
                     fn owned ->
                       send(parent, {fixture.key, :target, letter, owned, self()})

                       receive do
                         {:child, child} -> produce_owned(fixture, owned, child, :rewrite)
                       end
                     end
                   )
        end)
      end

    assert_receive {key, :target, "a", first, first_executor} when key == fixture.key, 5000
    assert_receive {key, :target, "b", second, second_executor} when key == fixture.key, 5000
    send(first_executor, {:child, second.target_handle})
    send(second_executor, {:child, first.target_handle})
    for task <- jobs, do: assert(Task.await(task, 10_000) == :ok)
    assert_owned_completed(fixture, first.target_handle)
    assert_owned_completed(fixture, second.target_handle)
    opts = detached(first)
    assert eventually(fn -> idle?(opts) end)
    {opts, [first.target_handle, second.target_handle]}
  end

  defp produce_copy(fixture) do
    parent = self()

    assert :ok =
             Execution.run_job(%{options(fixture) | url: "https://example.test/copy"}, fn owned ->
               send(parent, {fixture.key, :copy_opts, owned})
               produce_owned(fixture, owned, nil, :copy)
             end)

    assert_receive {key, :copy_opts, owned} when key == fixture.key
    assert_owned_completed(fixture, owned.target_handle)
    opts = detached(owned)
    assert eventually(fn -> idle?(opts) end)
    opts
  end

  defp failed_target(fixture) do
    parent = self()

    assert {:error, :fixture_failure} =
             Execution.run_job(options(fixture), fn owned ->
               send(parent, {fixture.key, :failed_opts, owned})
               {:error, :fixture_failure}
             end)

    assert_receive {key, :failed_opts, owned} when key == fixture.key
    opts = detached(owned)
    assert eventually(fn -> idle?(opts) end)
    opts
  end

  defp prepare_all(c, closed, cursor \\ nil) do
    case Store.export_prepare_next(c.opts, c.epoch, closed.close_token, cursor) do
      {:ok, {:batch, rows, next}, receipt} ->
        try do
          for row <- rows, do: prepare_row(c, closed, row)
        after
          Store.release_resource(receipt)
        end

        prepare_all(c, closed, next)

      :done ->
        :ok
    end
  end

  defp prepare_row(c, closed, %{descriptor: %{render_mode: :copy}} = row) do
    assert :ok =
             Store.export_prepared(
               c.opts,
               c.epoch,
               closed.close_token,
               row.target,
               row.descriptor.source_operation,
               []
             )

    :ok
  end

  defp prepare_row(c, closed, %{descriptor: %{render_mode: :rewrite}} = row) do
    plan = row.plans.bound
    funding = workspace(c, 0, plan.read_capacity + 1 + plan.decoded_bytes, plan.unavailable)

    try do
      assert {:ok, payload} = StagedIO.replay(plan, c.receipt, funding)
      assert payload.analysis.limits.max_total_bytes == @analysis_limits.max_total_bytes
      edges = StagedIO.compact_edges(payload.bound.occurrences)

      assert :ok =
               Store.export_prepared(
                 c.opts,
                 c.epoch,
                 closed.close_token,
                 row.target,
                 row.bound.operation,
                 edges
               )

      assert Authority.resource_current?(funding.overlap, c.opts.execution_lease, self())
      :ok
    after
      Store.release_resource(funding.overlap)
    end
  end

  defp context(c) do
    %Context{
      job: c.job,
      opts: c.opts,
      executor: self(),
      filesystem: c.fs,
      recovery_receipt: c.receipt,
      resource_owner: Process.whereis(Store),
      start_io: &Store.start_export_io(c.opts, c.epoch, &1),
      render_funding: fn supplied ->
        assert Resources.receipt(ledger(), supplied.overlap).actual == nil
        Store.export_render_funding(c.opts, c.epoch, supplied)
      end,
      finish_render: fn supplied, bytes ->
        assert supplied.overlap_capacity <= @analysis_limits.max_total_bytes
        assert Resources.receipt(ledger(), supplied.overlap).actual == nil
        assert {:ok, ^supplied} = Store.export_render_funding(c.opts, c.epoch, supplied)
        assert {:ok, fresh} = Store.export_finish_render(c.opts, c.epoch, supplied, bytes)

        assert fresh == %{
                 supplied
                 | overlap_capacity: bytes,
                   grants:
                     Map.put(supplied.grants, supplied.overlap, %{
                       supplied.grants[supplied.overlap]
                       | capacity: bytes
                     })
               }

        assert StagedIO.credit_spec(fresh) == StagedIO.credit_spec(supplied)
        event(c, {:finish_render, supplied.overlap, bytes, fresh})
        {:ok, fresh}
      end,
      reserve: fn operation, plan ->
        credit = current_credit(c)

        retained =
          case plan.kind do
            :source -> plan.root_bytes
            :metadata -> plan.bound_budget.retained - plan.unavailable
            :archive -> 0
          end

        for receipt <- credit.retained, do: assert(:ok = Store.commit_resource(receipt, retained))

        if Resources.receipt(ledger(), credit.overlap).actual == nil do
          assert :ok =
                   Store.commit_resource(credit.overlap, max(plan.bytes, plan.root_bytes || 0))
        end

        assert :ok = Store.export_reserve(c.opts, c.epoch, operation, plan)
        event(c, {:reserved, operation})
      end,
      written: fn operation, ack ->
        assert :ok = Store.export_written(c.opts, c.epoch, operation, ack)
        event(c, {:written, operation})
      end,
      custody: fn operation, companion, credit ->
        assert :ok = Store.export_custody(c.opts, c.epoch, operation, companion, credit)

        for receipt <- receipts(credit),
            do:
              assert(
                Authority.resource_current?(
                  receipt,
                  c.opts.execution_lease,
                  Process.whereis(Store)
                )
              )

        event(c, {:custody, operation, companion})
      end,
      deliver: fn companion, credit, payload ->
        assert {:ok, before} = Store.resource_funding(c.opts, credit)

        assert {:ok, reference, io_funding} =
                 Store.export_deliver(c.opts, c.epoch, companion, credit, payload)

        assert StagedIO.credit_spec(io_funding) == credit
        assert io_funding.holder == companion
        assert Map.drop(io_funding, [:holder, :grants]) == Map.drop(before, [:holder, :grants])
        assert Map.take(io_funding.grants, Map.keys(before.grants)) == before.grants
        [payload_receipt] = Map.keys(io_funding.grants) -- Map.keys(before.grants)
        payload_row = Resources.receipt(ledger(), payload_receipt)
        assert payload_row.kind == :response
        assert {:ok, measured} = Retained.bytes(payload, c.opts.max_analysis_bytes)
        assert payload_row.actual >= measured
        assert is_integer(payload_row.copy_bytes) and payload_row.copy_bytes >= 0

        for receipt <- Map.keys(io_funding.grants),
            do: assert(Authority.resource_current?(receipt, c.opts.execution_lease, companion))

        {:ok, reference, io_funding}
      end,
      settled: fn operation, result ->
        assert :ok = Store.export_settled(c.opts, c.epoch, operation, result)
        assert :sys.get_state(Store).export_io[c.opts.execution_lease].status == :idle
        event(c, {:settled, operation})
      end,
      abandon: fn operation, reason ->
        assert :ok = Store.export_abandon(c.opts, c.epoch, operation, reason)
        event(c, {:abandon, operation, reason})
      end
    }
  end

  defp assert_render_commit(c, supplied, output) do
    [{:finish_render, _, bytes, fresh}] =
      Enum.filter(events(c), fn
        {:finish_render, overlap, _, _} -> overlap === supplied.overlap
        _ -> false
      end)

    assert bytes == :binary.referenced_byte_size(output)
    assert bytes < supplied.overlap_capacity
    assert Resources.receipt(ledger(), supplied.overlap).actual == bytes
    assert fresh.overlap_capacity == bytes

    assert {:error, :invalid_render_funding} =
             Store.export_render_funding(c.opts, c.epoch, supplied)

    assert {:error, :invalid_render_funding} =
             Store.export_finish_render(c.opts, c.epoch, fresh, bytes)
  end

  defp producer_workspace(c, page) do
    funding = workspace(c, 1_000_000, 4_000_000, page.credit.unavailable)
    credit = %{StagedIO.credit_spec(funding) | backing: page.credit.backing}
    Process.put({c.key, :credit}, credit)
    assert {:ok, funding} = Store.resource_funding(c.opts, credit)
    funding
  end

  defp workspace(c, retained_bytes \\ 1_000_000, overlap_bytes \\ 4_000_000, unavailable \\ 0) do
    previous = current_credit(c)

    for receipt <- previous.retained ++ List.wrap(previous.overlap),
        do: Store.release_resource(receipt)

    retained =
      if retained_bytes == 0 do
        []
      else
        assert {:ok, receipt} = Store.reserve_resource(c.opts, :analysis, retained_bytes)
        [receipt]
      end

    assert {:ok, overlap} = Store.reserve_resource(c.opts, :snapshot, overlap_bytes)
    credit = %{retained: retained, backing: [], overlap: overlap, unavailable: unavailable}
    Process.put({c.key, :credit}, credit)
    Process.put({c.key, :receipts}, receipts(credit) ++ Process.get({c.key, :receipts}, []))
    assert {:ok, funding} = Store.resource_funding(c.opts, credit)
    funding
  end

  defp with_context(fixture, callback) do
    completed = make_ref()
    caller = self()

    assert :ok =
             Execution.run_job(options(fixture), fn owned ->
               with_owned(fixture, owned, fn c ->
                 callback.(c)
                 send(caller, {completed, :callback_ran})
                 :ok
               end)
             end)

    assert_receive {^completed, :callback_ran}
    :ok
  end

  defp with_owned(fixture, owned, callback) do
    assert Authority.execution_current?(owned.execution_lease, self())
    assert {:ok, export} = Store.export_context(owned)
    assert export.job.id === owned.target_handle
    assert export.job.opts == %{}
    assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)

    c =
      Map.merge(fixture, %{
        opts: owned,
        fs: filesystem.filesystem,
        receipt: filesystem.receipt,
        epoch: export.epoch,
        job: export.job,
        credit: %{retained: [], backing: [], overlap: nil, unavailable: 0}
      })

    funding = workspace(c)
    c = Map.merge(c, %{funding: funding, retained: hd(funding.retained)})

    try do
      result = callback.(c)
      send(c.observer, {c.key, :owned_callback_ran, c.job.id})
      result
    after
      for receipt <- Process.get({c.key, :receipts}, []), do: Store.release_resource(receipt)
    end
  end

  defp options(c) do
    Map.merge(@limits, %{
      url: "https://example.test/root",
      scope: c.scope,
      save_to: Path.join(c.root, "archive"),
      max_body: @analysis_limits.max_bytes,
      max_analysis_bytes: @analysis_limits.max_total_bytes,
      max_analysis_regions: @analysis_limits.max_regions,
      max_analysis_depth: @analysis_limits.max_depth,
      max_analysis_facts: @analysis_limits.max_facts,
      max_analysis_occurrences: @analysis_limits.max_occurrences,
      max_analysis_edits: @analysis_limits.max_edits,
      max_interpretations: @limits.max_targets,
      attempt_timeout: 10_000,
      respect_robots: false,
      retries: 0,
      interval: 0,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    })
  end

  defp detached(owned),
    do: Map.drop(owned, [:execution_lease, :crawler_deadline, :scheduler_claim])

  defp idle?(opts),
    do: Crawler.Store.ExportRun.quiescent?(:sys.get_state(Store), {opts.scope, opts.generation})

  defp current_credit(c), do: Process.get({c.key, :credit}, c.credit)

  defp receipts(credit),
    do:
      credit.retained ++
        credit.backing ++ if(is_reference(credit.overlap), do: [credit.overlap], else: [])

  defp ledger, do: :sys.get_state(Store).resources

  defp session(c),
    do: :sys.get_state(Store).exports[{c.opts.scope, c.opts.generation}].helper.session

  defp assert_owned_completed(fixture, target) do
    assert_receive {key, :owned_callback_ran, ^target} when key == fixture.key, 1000
  end

  defp event(c, value) do
    Process.put({c.key, :events}, [value | events(c)])
    send(c.observer, {c.key, :event, value})
    :ok
  end

  defp events(c), do: Process.get({c.key, :events}, [])

  defp observed_events(c, acc \\ []) do
    receive do
      {key, :event, value} when key == c.key -> observed_events(c, [value | acc])
    after
      0 -> acc
    end
  end

  defp eventually(callback, attempts \\ 500)
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
