defmodule Crawler.Store.ExportIOTest do
  use ExUnit.Case, async: false

  alias Crawler.Export.Finalizer
  alias Crawler.Export.Runtime
  alias Crawler.Export.Runtime.Context
  alias Crawler.Export.Session
  alias Crawler.Export.StagedIO
  alias Crawler.Export.StagedIO.Funding
  alias Crawler.IsolatedOwnerHelpers
  alias Crawler.Store
  alias Crawler.Store.Authority
  alias Crawler.Store.Execution
  alias Crawler.Store.Resources

  @body "export IO public service fixture"

  test "tiny copied payload rejection keeps Store alive and permits a subsequent real stage" do
    with_context(fn c ->
      store = Process.whereis(Store)
      credit = credit(c)
      io = companion()

      try do
        payload = {:write, :invalid, @body}
        assert {:ok, retained} = Crawler.Store.Retained.bytes(payload, c.opts.max_retained_bytes)

        assert {:ok, copied} =
                 Crawler.Store.Retained.copy_bytes(payload, c.opts.max_retained_bytes)

        assert copied > retained
        before = :sys.get_state(Store).resources
        assert {:error, _} = Store.export_deliver(c.opts, c.epoch, io, credit, payload)
        assert Process.whereis(Store) == store
        after_rejection = :sys.get_state(Store).resources
        assert after_rejection.used == before.used
        assert after_rejection.receipts == before.receipts
        assert {:ok, funding} = Store.resource_funding(c.opts, credit)

        assert :ok =
                 Runtime.with_io(runtime_context(c), fn runtime ->
                   assert {:ok, _ack} =
                            Runtime.stage_source(
                              runtime,
                              "after-tiny.bin",
                              @body,
                              make_ref(),
                              :retained,
                              funding
                            )

                   assert Process.whereis(Store) == store
                   :ok
                 end)
      after
        stop_companion(io)
        release_credit(credit)
      end
    end)
  end

  test "real admitted execution stages twice through public owner callbacks" do
    with_context(fn c ->
      credit = credit(c)
      assert {:ok, funding} = Store.resource_funding(c.opts, credit)

      assert :ok =
               Runtime.with_io(runtime_context(c), fn runtime ->
                 assert {:ok, first} =
                          Runtime.stage_source(
                            runtime,
                            "one.bin",
                            @body,
                            make_ref(),
                            :retained,
                            funding
                          )

                 assert {:ok, second} =
                          Runtime.stage_source(
                            runtime,
                            "two.bin",
                            @body,
                            make_ref(),
                            :retained,
                            funding
                          )

                 assert first.plan.path == "one.bin"
                 assert second.plan.path == "two.bin"
                 assert File.read!(Path.join([c.receipt.stage, "source", "one.bin"])) == @body
                 assert File.read!(Path.join([c.receipt.stage, "source", "two.bin"])) == @body
                 assert_idle(c)
                 :ok
               end)

      release_credit(credit)
    end)
  end

  test "all four retained and four backing roles survive with distinct tenth payload grant" do
    with_context(fn c ->
      credit = credit(c, 4, 4)
      io = companion()

      try do
        {operation, plan} = reserve(c, "ten.bin")
        assert :ok = Store.export_custody(c.opts, c.epoch, operation, io, credit)

        assert {:ok, delivery, %Funding{holder: ^io} = funding} =
                 Store.export_deliver(c.opts, c.epoch, io, credit, {:write, plan, @body})

        assert StagedIO.credit_spec(funding) == credit
        assert length(credit.retained) == 4
        assert length(credit.backing) == 4
        assert map_size(funding.grants) == 10
        assert Enum.all?(refs(credit), &Map.has_key?(funding.grants, &1))
        assert [payload] = Map.keys(funding.grants) -- refs(credit)
        refute payload in refs(credit)

        assert Resources.receipt(:sys.get_state(Store).resources, payload).actual >
                 byte_size(@body)

        send(io, {:perform, self(), delivery, funding, :all})
        assert_receive {:performed, ^io, ^delivery, {:ok, ack}, []}, 2000
        assert :ok = Store.export_written(c.opts, c.epoch, operation, ack)
        assert :ok = Store.export_settled(c.opts, c.epoch, operation, {:ok, ack})
        assert_idle(c)
        assert Resources.receipt(:sys.get_state(Store).resources, payload) == nil
      after
        stop_companion(io)
        release_credit(credit)
      end
    end)
  end

  test "settlement blocks until the final actual release acknowledgement is consumed" do
    parent = self()

    task =
      Task.async(fn ->
        with_context(fn c ->
          credit = credit(c)
          io = companion()

          try do
            {operation, plan} = reserve(c, "barrier.bin")
            assert :ok = Store.export_custody(c.opts, c.epoch, operation, io, credit)

            assert {:ok, delivery, funding} =
                     Store.export_deliver(c.opts, c.epoch, io, credit, {:write, plan, @body})

            send(io, {:perform, self(), delivery, funding, :hold_last})
            assert_receive {:performed, ^io, ^delivery, {:ok, ack}, [held]}, 2000
            assert :ok = Store.export_written(c.opts, c.epoch, operation, ack)
            send(parent, {:at_barrier, self(), io, held, credit})
            assert :ok = Store.export_settled(c.opts, c.epoch, operation, {:ok, ack})
            send(parent, {:settled, self()})

            assert {:ok, next_plan} =
                     StagedIO.plan_source("after-barrier.bin", @body, make_ref(), :retained)

            write_public(c, io, credit, next_plan, @body)
            send(parent, {:regranted, self(), io})
            release_credit(credit)
          after
            stop_companion(io)
          end
        end)
      end)

    assert_receive {:at_barrier, producer, io, held, credit}, 5000
    refute_receive {:settled, ^producer}, 50
    state = :sys.get_state(Store)
    assert map_size(state.export_io) == 1
    [row] = Map.values(state.export_io)
    assert row.status == :delivered
    assert elem(row.settled_from, 0) == producer
    assert MapSet.size(row.released) == MapSet.size(row.expected) - 1

    assert Enum.all?(refs(credit), fn ref ->
             Map.has_key?(Resources.receipt(state.resources, ref).holders, Process.whereis(Store))
           end)

    send(io, {:release, [held]})
    assert_receive {:settled, ^producer}, 2000
    assert_receive {:regranted, ^producer, ^io}, 2000
    assert :ok = Task.await(task, 5000)
  end

  test "duplicate and unrelated events cannot refund completed grants twice" do
    with_context(fn c ->
      credit = credit(c)
      io = companion()

      try do
        {operation, plan} = reserve(c, "duplicate.bin")
        assert :ok = Store.export_custody(c.opts, c.epoch, operation, io, credit)

        assert {:ok, delivery, funding} =
                 Store.export_deliver(c.opts, c.epoch, io, credit, {:write, plan, @body})

        send(io, {:perform, self(), delivery, funding, :all})
        assert_receive {:performed, ^io, ^delivery, {:ok, ack}, []}, 2000
        assert :ok = Store.export_written(c.opts, c.epoch, operation, ack)
        assert :ok = Store.export_settled(c.opts, c.epoch, operation, {:ok, ack})
        before = :sys.get_state(Store).resources
        send(io, {:repeat, Map.keys(funding.grants), self()})
        assert_receive {:repeated, ^io}, 2000
        after_events = :sys.get_state(Store).resources
        assert after_events.used == before.used
        assert after_events.receipts == before.receipts
        assert_idle(c)
      after
        stop_companion(io)
        release_credit(credit)
      end
    end)
  end

  test "a stale outer custody RPC releases every unused Store pregrant" do
    with_context(fn c ->
      credit = credit(c)
      io = companion()

      try do
        before = :sys.get_state(Store).resources
        stale = %{c.opts | scheduler_claim: make_ref()}
        assert {:error, :stale} = Store.export_custody(stale, c.epoch, make_ref(), io, credit)
        after_rejection = :sys.get_state(Store).resources
        assert after_rejection.used == before.used
        assert after_rejection.receipts == before.receipts
        assert :sys.get_state(Store).export_io == %{}

        assert {:error, :stale} =
                 Store.export_deliver(stale, c.epoch, io, credit, {:write, :invalid, @body})

        after_delivery = :sys.get_state(Store).resources
        assert after_delivery.used == before.used
        assert after_delivery.receipts == before.receipts
      after
        stop_companion(io)
        release_credit(credit)
      end
    end)
  end

  test "malformed role lists are rejected before grants or delivery" do
    with_context(fn c ->
      credit = credit(c)
      io = companion()

      try do
        {operation, _plan} = reserve(c, "rejected.bin")
        invalid = %{credit | retained: List.duplicate(hd(credit.retained), 5)}
        before = :sys.get_state(Store).resources
        assert {:error, _} = Store.export_custody(c.opts, c.epoch, operation, io, invalid)
        after_rejection = :sys.get_state(Store).resources
        assert after_rejection.used == before.used
        assert after_rejection.receipts == before.receipts
        assert :sys.get_state(Store).export_io == %{}
        send(io, {:mailbox, self()})
        assert_receive {:mailbox, ^io, messages}, 2000
        refute Enum.any?(messages, &match?({:crawler_resource_delivery, _, _, _, _, _}, &1))
      after
        stop_companion(io)
        release_credit(credit)
      end
    end)
  end

  test "an oversized payload is rejected before a large delivery or receipt survives" do
    with_context(fn c ->
      credit = credit(c)
      io = companion()

      try do
        {operation, plan} = reserve(c, "oversized.bin")
        assert :ok = Store.export_custody(c.opts, c.epoch, operation, io, credit)
        before = :sys.get_state(Store).resources
        oversized = %{c.opts | max_retained_bytes: 1}

        assert {:error, {:limit, :max_retained_bytes}} =
                 Store.export_deliver(oversized, c.epoch, io, credit, {:write, plan, @body})

        after_rejection = :sys.get_state(Store).resources
        assert after_rejection.used == before.used
        assert after_rejection.receipts == before.receipts
        send(io, {:mailbox, self()})
        assert_receive {:mailbox, ^io, messages}, 2000
        refute Enum.any?(messages, &match?({:crawler_resource_delivery, _, _, _, _, _}, &1))
        assert :ok = Store.export_abandon(c.opts, c.epoch, operation, :test_abandon)
      after
        stop_companion(io)
        release_credit(credit)
      end
    end)
  end

  test "companion DOWN after delivery keeps Store custody until actual filesystem cleanup" do
    with_context(fn c ->
      credit = credit(c)
      io = companion()

      try do
        {operation, plan} = reserve(c, "down.bin")
        assert :ok = Store.export_custody(c.opts, c.epoch, operation, io, credit)

        assert {:ok, _delivery, funding} =
                 Store.export_deliver(c.opts, c.epoch, io, credit, {:write, plan, @body})

        assert true = :erlang.suspend_process(c.filesystem)

        try do
          stop_companion(io)
          eventually(fn -> :sys.get_state(Store).exports[c.run].failure != nil end)
          state = :sys.get_state(Store)
          row = state.export_io[c.opts.execution_lease]
          assert row.status == :poisoned
          assert MapSet.size(row.held) == map_size(funding.grants) + 1
          assert Process.alive?(c.filesystem)

          for ref <- Map.keys(funding.grants) ++ [row.metadata_receipt] do
            assert Resources.receipt(state.resources, ref).holders[Process.whereis(Store)]
          end

          assert {:error, _} = Store.export_context(c.opts)
          assert {:error, _} = Store.export_custody(c.opts, c.epoch, make_ref(), io, credit)
        after
          :erlang.resume_process(c.filesystem)
        end

        eventually(fn -> not Process.alive?(c.filesystem) end)

        eventually(fn ->
          MapSet.size(:sys.get_state(Store).export_io[c.opts.execution_lease].held) == 1
        end)
      after
        stop_companion(io)
        release_credit(credit)
      end
    end)
  end

  test "filesystem DOWN drains custody and all IO indexes within bounded owner work" do
    {physical_tmp, 0} = System.cmd("pwd", ["-P"], cd: System.tmp_dir!())

    child =
      IsolatedOwnerHelpers.start(
        String.trim(physical_tmp),
        __MODULE__,
        :filesystem_down_case,
        __ENV__.file
      )

    try do
      assert :ok = IsolatedOwnerHelpers.await(child, Crawler.Deadline.after_ms(10_000))
    after
      IsolatedOwnerHelpers.cleanup(child)
    end
  end

  @doc false
  def filesystem_down_case(fixture) do
    opts =
      %{
        scope: fixture.scope,
        url: "https://example.test/export.bin",
        respect_robots: false,
        save_to: Path.join(fixture.root, "archive")
      }
      |> Crawler.Options.assign_defaults()
      |> Store.bind_run()

    caller = self()
    completed = make_ref()

    callback = &capture_filesystem_down(&1, caller, completed)

    assert :ok =
             Execution.run_job(opts, fn admitted ->
               Execution.run(
                 admitted,
                 &run_active_callback(&1, callback, fixture.scope, caller, completed)
               )
             end)

    assert_receive {^completed, :callback_started}, 2000
    assert_receive {^completed, :callback_ran}, 2000
    assert_receive {^completed, :recovery, c, before}, 2000
    assert :ok = Store.dispose_scope(fixture.scope)

    eventually(fn ->
      state = :sys.get_state(Store)

      state.exports[c.run].retired? and state.exports[c.run].phase == :cleanup_failed and
        not Enum.any?(state.export_io, fn {_lease, row} -> row.run == c.run end) and
        not Enum.any?(state.executions, fn {_lease, row} -> row.opts.scope == fixture.scope end)
    end)

    state = :sys.get_state(Store)
    recovery = state.exports[c.run]
    assert recovery.phase == :cleanup_failed
    assert recovery.retired?
    assert recovery.cleanup_failure == {:snapshot, :cleanup_failed}
    assert recovery.filesystem == nil
    assert recovery.receipt == before.receipt
    assert recovery.reserved_bytes == before.reserved_bytes
    assert state.export_bytes == before.reserved_bytes
    assert map_size(recovery.helper.session.pending) == 1
    assert recovery.helper.session.staged == %{}
    assert File.dir?(recovery.receipt.stage)
    assert File.dir?(recovery.receipt.claim)
    refute File.exists?(Path.join([recovery.receipt.stage, "source", "filesystem-down.bin"]))
    refute File.exists?(Path.join(fixture.root, "archive"))
    refute Enum.any?(state.export_actors, fn {_pid, run} -> run == c.run end)
    refute Enum.any?(state.export_monitors, fn {_ref, {run, _pid}} -> run == c.run end)
    assert state.export_io_monitors == %{}
    assert state.export_io_holders == %{}

    assert {:ok, %{state: :failed, reason: {:snapshot, :cleanup_failed}, ready?: false}} =
             Store.export_status(
               Map.drop(c.opts, [:execution_lease, :crawler_deadline, :scheduler_claim])
             )

    :ok
  end

  defp capture_filesystem_down(c, caller, completed) do
    before = :sys.get_state(Store).exports[c.run]
    filesystem_down_context(c)
    send(caller, {completed, :recovery, c, before})
  end

  defp filesystem_down_context(c) do
    credit = credit(c)
    io = companion()

    try do
      {operation, _plan} = reserve(c, "filesystem-down.bin")
      assert :ok = Store.export_custody(c.opts, c.epoch, operation, io, credit)
      fs_monitor = Process.monitor(c.filesystem)
      Process.exit(c.filesystem, :kill)
      assert_receive {:DOWN, ^fs_monitor, :process, _, _}, 2000

      eventually(fn ->
        row = :sys.get_state(Store).export_io[c.opts.execution_lease]
        row.status == :poisoned and MapSet.size(row.held) == 1
      end)

      state = :sys.get_state(Store)
      assert map_size(state.export_io_monitors) == 1
      assert map_size(state.export_io_holders) == 1
      assert {:error, _} = Store.export_context(c.opts)
    after
      stop_companion(io)
      release_credit(credit)
    end
  end

  test "direct funded render uses real staged metadata and public archive rejects an unsealed owner" do
    with_context(fn c ->
      body = ~s|<!doctype html><html><body><a href="/missing">missing</a></body></html>|
      revision = make_ref()
      io = companion()

      source_credit = %{
        retained: [reserve_committed(c, :analysis, byte_size(body))],
        backing: [],
        overlap: reserve_committed(c, :snapshot, 4096),
        unavailable: 0
      }

      try do
        assert {:ok, source_plan} =
                 StagedIO.plan_source("render.source", body, revision, :retained)

        source_operation = write_public(c, io, source_credit, source_plan, body)

        limits = %{
          max_bytes: 1_000_000,
          max_total_bytes: 16_000_000,
          max_regions: 1000,
          max_depth: 16,
          max_facts: 10_000,
          max_occurrences: 1000,
          max_edits: 1000,
          max_output_bytes: 1_000_000
        }

        analysis_opts =
          Map.merge(limits, %{
            url: "https://example.test/render.html",
            content_type: "text/html",
            assets: [],
            css_tokens: %{},
            css_references: %{},
            css_revision: :final_css
          })

        assert {:ok, analysis} = Crawler.Analysis.analyze(body, analysis_opts)
        assert {:ok, original} = Crawler.Analysis.occurrences_result(analysis, analysis_opts)
        assert {:ok, bound} = Crawler.Analysis.bind(original, fn _ -> nil end)
        edges = StagedIO.compact_edges(bound.occurrences)

        assert {:ok, plan} =
                 StagedIO.plan_metadata(
                   "render.etf",
                   analysis,
                   original,
                   bound,
                   :final_css,
                   revision,
                   %{unavailable: 0, root: :retained}
                 )

        retained = reserve_committed(c, :analysis, bound.budget.retained)
        assert {:ok, overlap} = Store.reserve_resource(c.opts, :snapshot, limits.max_total_bytes)
        metadata_credit = %{retained: [retained], backing: [], overlap: overlap, unavailable: 0}
        assert {:ok, encode_funding} = Store.resource_funding(c.opts, metadata_credit)

        assert {:ok, plan, metadata, _budget} =
                 StagedIO.encode(plan, analysis, original, bound, encode_funding)

        assert :ok = Store.commit_resource(overlap, :binary.referenced_byte_size(metadata))
        metadata_operation = write_public(c, io, metadata_credit, plan, metadata)
        session = :sys.get_state(Store).exports[c.run].helper.session
        assert {:ok, session} = Session.admit(session, c.epoch, c.job)

        assert {:ok, session} =
                 Session.response(
                   session,
                   c.epoch,
                   c.job.id,
                   source_operation,
                   "text/html",
                   "https://example.test/render.html"
                 )

        assert {:ok, session} =
                 Session.interpretation(
                   session,
                   c.epoch,
                   c.job.id,
                   metadata_operation,
                   String.duplicate("a", 24),
                   edges
                 )

        assert {:ok, session} =
                 Session.settle(session, c.epoch, c.job.id, Crawler.Job.Outcome.new(:succeeded))

        finalizer_fixture =
          Crawler.Job.new(:finalize, {c.opts.scope, c.opts.generation, c.opts.queue}, %{})

        assert {:ok, snapshot, _sealed} =
                 Session.seal(session, c.epoch, make_ref(), finalizer_fixture)

        assert {:ok, render_overlap} =
                 Store.reserve_resource(c.opts, :snapshot, limits.max_total_bytes)

        render_credit = %{retained: [], backing: [], overlap: render_overlap, unavailable: 0}
        assert {:ok, render_funding} = Store.resource_funding(c.opts, render_credit)

        assert {:ok, output, stats} =
                 Finalizer.render(snapshot, c.job.id, session.staged, c.receipt, render_funding)

        assert stats.budget.limit == limits.max_total_bytes
        assert output =~ "https://example.test/missing"
        assert {:ok, output_plan} = Finalizer.plan_output(snapshot, c.job.id, output)
        assert :ok = Store.commit_resource(render_overlap, :binary.referenced_byte_size(output))
        assert {:ok, fresh} = Store.resource_funding(c.opts, render_credit)
        assert fresh.overlap_capacity == :binary.referenced_byte_size(output)
        assert fresh.overlap_capacity < render_funding.overlap_capacity

        assert {:error, :closed_export} =
                 Store.export_reserve(c.opts, c.epoch, make_ref(), output_plan)

        refute File.exists?(Path.join([c.receipt.stage, "archive", output_plan.path]))

        IO.puts(
          "Direct render: source=#{byte_size(body)} metadata=#{byte_size(metadata)} output=#{byte_size(output)}; renewed overlap=#{fresh.overlap_capacity}; archive owner remains unsealed"
        )

        release_credit(metadata_credit)
        release_credit(render_credit)
      after
        stop_companion(io)
        release_credit(source_credit)
      end
    end)
  end

  test "partial adoption then release before adoption poisons the export and keeps FS custody until cleanup" do
    with_context(fn c ->
      credit = credit(c)
      io = companion()

      try do
        {operation, plan} = reserve(c, "unadopted.bin")
        assert :ok = Store.export_custody(c.opts, c.epoch, operation, io, credit)

        assert {:ok, delivery, funding} =
                 Store.export_deliver(c.opts, c.epoch, io, credit, {:write, plan, @body})

        assert true = :erlang.suspend_process(c.filesystem)

        try do
          send(io, {:release_without_adoption, self(), delivery, funding})
          eventually(fn -> :sys.get_state(Store).exports[c.run].failure != nil end)
          state = :sys.get_state(Store)
          assert state.export_io[c.opts.execution_lease].status == :poisoned

          assert Enum.all?(refs(credit), fn ref ->
                   Map.has_key?(
                     Resources.receipt(state.resources, ref).holders,
                     Process.whereis(Store)
                   )
                 end)

          assert {:error, _} = Store.export_context(c.opts)
        after
          :erlang.resume_process(c.filesystem)
        end
      after
        stop_companion(io)
        release_credit(credit)
      end
    end)
  end

  test "a real published response Store grant survives successful helper cleanup" do
    with_context(fn c ->
      ref = published_response(c)

      before =
        Resources.receipt(:sys.get_state(Store).resources, ref).holders[Process.whereis(Store)]

      assert before.status == :adopted

      credit = %{
        retained: [],
        backing: [ref],
        overlap: reserve_committed(c, :snapshot, 4096),
        unavailable: 0
      }

      io = companion()

      try do
        assert {:ok, plan} = StagedIO.plan_source("preexisting.bin", @body, make_ref(), :borrowed)
        write_public(c, io, credit, plan, @body)
        state = :sys.get_state(Store)
        assert Resources.receipt(state.resources, ref).holders[Process.whereis(Store)] == before
        assert MapSet.member?(state.source_resources, ref)
      after
        stop_companion(io)
        release_credit(credit)
      end
    end)
  end

  test "wrong-kind real pending Store grants survive helper and outer RPC rejection" do
    with_context(fn c ->
      credit = credit(c)
      io = companion()

      assert {:ok, wrong_kind} =
               Store.reserve_resource(c.opts, :analysis, 32_768, Process.whereis(Store))

      assert :ok = Store.commit_resource(wrong_kind, 32_768)

      try do
        {operation, plan} = reserve(c, "wrong-kind.bin")
        before = Resources.receipt(:sys.get_state(Store).resources, wrong_kind)
        command = {:io_custody, c.epoch, operation, io, credit, wrong_kind}
        assert {:error, _} = export_rpc(c.opts, command)
        assert Resources.receipt(:sys.get_state(Store).resources, wrong_kind) == before
        stale = %{c.opts | scheduler_claim: make_ref()}
        assert {:error, :stale} = export_rpc(stale, command)
        assert Resources.receipt(:sys.get_state(Store).resources, wrong_kind) == before

        assert {:error, _} =
                 export_rpc(
                   c.opts,
                   {:io_deliver, c.epoch, io, credit, wrong_kind, {:write, plan, @body}}
                 )

        assert Resources.receipt(:sys.get_state(Store).resources, wrong_kind) == before
      after
        Store.release_resource(wrong_kind, Process.whereis(Store))
        Store.release_resource(wrong_kind)
        stop_companion(io)
        release_credit(credit)
      end
    end)
  end

  for cause <- [:producer_down, :deadline] do
    @tag cause: cause
    test "#{cause} after delivery preserves custody until filesystem DOWN", %{cause: cause} do
      parent = self()

      expected =
        if cause == :producer_down, do: {:exit, :killed}, else: {:error, {:deadline, :attempt}}

      overrides = if cause == :deadline, do: %{attempt_timeout: 1000}, else: %{}

      task =
        Task.async(fn ->
          with_context(
            fn c ->
              credit = credit(c)
              io = companion()
              {operation, plan} = reserve(c, "producer-ended.bin")
              assert :ok = Store.export_custody(c.opts, c.epoch, operation, io, credit)

              assert {:ok, _delivery, funding} =
                       Store.export_deliver(c.opts, c.epoch, io, credit, {:write, plan, @body})

              assert true = :erlang.suspend_process(c.filesystem)
              send(parent, {:execution_waiting, self(), c, io, funding})

              receive do
                :unexpected_resume -> flunk("execution must end before callback completion")
              end
            end,
            expected,
            overrides
          )
        end)

      assert_receive {:execution_waiting, producer, c, io, funding}, 5000
      assert true = :erlang.suspend_process(c.filesystem)

      try do
        if cause == :producer_down, do: Process.exit(producer, :kill)

        eventually(
          fn ->
            state = :sys.get_state(Store)

            case state.export_io[c.opts.execution_lease] do
              %{status: :poisoned} -> true
              _ -> false
            end
          end,
          500
        )

        state = :sys.get_state(Store)
        row = state.export_io[c.opts.execution_lease]
        assert Process.alive?(c.filesystem)

        for ref <- Map.keys(funding.grants) ++ [row.metadata_receipt] do
          assert Resources.receipt(state.resources, ref).holders[Process.whereis(Store)]
        end

        refute Process.alive?(io)
      after
        :erlang.resume_process(c.filesystem)
      end

      assert :ok = Task.await(task, 5000)
    end
  end

  test "real source retirement defers its Store release until delivered IO and filesystem custody end" do
    parent = self()

    task =
      Task.async(fn ->
        with_context(
          fn c ->
            ref = published_response(c)

            credit = %{
              retained: [],
              backing: [ref],
              overlap: reserve_committed(c, :snapshot, 4096),
              unavailable: 0
            }

            io = companion()

            assert {:ok, plan} =
                     StagedIO.plan_source("retired-source.bin", @body, make_ref(), :borrowed)

            operation = make_ref()
            assert :ok = Store.export_reserve(c.opts, c.epoch, operation, plan)
            assert :ok = Store.export_custody(c.opts, c.epoch, operation, io, credit)

            assert {:ok, _delivery, _funding} =
                     Store.export_deliver(c.opts, c.epoch, io, credit, {:write, plan, @body})

            assert :ok = Store.release_resource(ref)
            send(parent, {:retirement_ready, self(), c, ref})

            receive do
              :finish_callback -> :ok
            end
          end,
          :ok
        )
      end)

    assert_receive {:retirement_ready, producer, c, ref}, 5000
    assert true = :erlang.suspend_process(c.filesystem)

    try do
      send(producer, :finish_callback)

      eventually(fn ->
        state = :sys.get_state(Store)

        case state.export_io[c.opts.execution_lease] do
          %{deferred_owner_releases: deferred} ->
            not MapSet.member?(state.source_resources, ref) and MapSet.member?(deferred, ref)

          _ ->
            false
        end
      end)

      state = :sys.get_state(Store)
      row = state.export_io[c.opts.execution_lease]
      assert Process.alive?(c.filesystem)
      assert MapSet.member?(row.held, ref)
      assert MapSet.size(row.deferred_owner_releases) <= 11
      assert Resources.receipt(state.resources, ref).holders[Process.whereis(Store)]
    after
      :erlang.resume_process(c.filesystem)
    end

    eventually(fn -> Resources.receipt(:sys.get_state(Store).resources, ref) == nil end, 500)
    assert :ok = Task.await(task, 5000)
  end

  defp published_response(c) do
    source =
      Req.Response.new(status: 200, body: @body)
      |> Req.Response.put_private(:crawler_source_revision, make_ref())
      |> Req.Response.put_private(
        :crawler_reuse,
        %Crawler.Fetcher.Requester.PreparedRequest.ReuseDisposition{
          dependency: :initial,
          disposition: :candidate
        }
      )

    assert {:ok, bytes} = Crawler.Store.Retained.bytes(source, c.opts.max_retained_bytes)
    assert {:ok, copy} = Crawler.Store.Retained.copy_bytes(source, c.opts.max_retained_bytes)
    actual = max(bytes, copy)

    assert {:ok, ref} =
             Store.reserve_resource(c.opts, :response, actual, Process.whereis(Store))

    assert :ok = Store.commit_response_resource(ref, actual, copy)
    assert :ok = Store.publish_source(c.opts, ref, source)

    ref
  end

  defp export_rpc(opts, command),
    do: GenServer.call(Store, {:execution, opts.execution_lease, {:export, opts, command}})

  defp write_public(c, io, credit, plan, bytes) do
    operation = make_ref()
    assert :ok = Store.export_reserve(c.opts, c.epoch, operation, plan)
    assert :ok = Store.export_custody(c.opts, c.epoch, operation, io, credit)

    assert {:ok, delivery, funding} =
             Store.export_deliver(c.opts, c.epoch, io, credit, {:write, plan, bytes})

    assert StagedIO.credit_spec(funding) == credit
    send(io, {:perform, self(), delivery, funding, :all})
    assert_receive {:performed, ^io, ^delivery, {:ok, ack}, []}, 2000
    assert :ok = Store.export_written(c.opts, c.epoch, operation, ack)
    assert :ok = Store.export_settled(c.opts, c.epoch, operation, {:ok, ack})
    assert_idle(c)
    operation
  end

  defp with_context(callback, expected \\ :ok, overrides \\ %{}) do
    scope = make_ref()
    {physical_tmp, 0} = System.cmd("pwd", ["-P"], cd: System.tmp_dir!())

    root =
      Path.join(
        String.trim(physical_tmp),
        "crawler-export-io-test-" <>
          Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)

    opts =
      %{
        scope: scope,
        url: "https://example.test/export.bin",
        respect_robots: false,
        save_to: Path.join(root, "archive")
      }
      |> Map.merge(overrides)
      |> Crawler.Options.assign_defaults()
      |> Store.bind_run()

    caller = self()
    completed = make_ref()

    try do
      execute = fn ->
        Execution.run_job(opts, fn admitted ->
          Execution.run(admitted, &run_active_callback(&1, callback, scope, caller, completed))
        end)
      end

      case expected do
        :ok ->
          assert :ok = execute.()
          assert_receive {^completed, :callback_ran}, 2000

        {:exit, reason} ->
          assert catch_exit(execute.()) == reason

        error ->
          assert execute.() == error
      end

      assert_receive {^completed, :callback_started}, 2000
      :ok
    after
      Store.dispose_scope(scope)

      eventually(fn ->
        not Enum.any?(:sys.get_state(Store).exports, fn {{candidate, _}, _} ->
          candidate == scope
        end)
      end)

      eventually(fn ->
        state = :sys.get_state(Store)
        not Enum.any?(state.export_io, fn {_, row} -> row.run == {scope, opts.generation} end)
      end)

      File.rm_rf!(root)
    end
  end

  defp run_active_callback(bound, callback, scope, caller, completed) do
    assert Authority.execution_current?(bound.execution_lease, self())
    assert is_reference(bound.scheduler_claim)
    assert {:ok, export} = Store.export_context(bound)
    assert {:ok, fs} = Store.export_filesystem(bound, export.epoch)
    state = :sys.get_state(Store)
    job = state.scheduler.frontier.jobs[bound.target_handle].job
    assert job.id == bound.target_handle

    send(caller, {completed, :callback_started})

    callback.(%{
      opts: bound,
      epoch: export.epoch,
      filesystem: fs.filesystem,
      receipt: fs.receipt,
      run: {scope, bound.generation},
      job: job
    })

    send(caller, {completed, :callback_ran})
    :ok
  end

  defp assert_idle(c) do
    row = :sys.get_state(Store).export_io[c.opts.execution_lease]
    assert row.status == :idle
    assert row.expected == MapSet.new()
    assert MapSet.size(row.held) == 1
  end

  defp runtime_context(c) do
    %Context{
      job: c.job,
      opts: c.opts,
      executor: self(),
      filesystem: c.filesystem,
      recovery_receipt: c.receipt,
      resource_owner: Process.whereis(Store),
      start_io: &Store.start_export_io(c.opts, c.epoch, &1),
      render_funding: &Store.export_render_funding(c.opts, c.epoch, &1),
      finish_render: &Store.export_finish_render(c.opts, c.epoch, &1, &2),
      reserve: &Store.export_reserve(c.opts, c.epoch, &1, &2),
      written: &Store.export_written(c.opts, c.epoch, &1, &2),
      custody: &Store.export_custody(c.opts, c.epoch, &1, &2, &3),
      deliver: &Store.export_deliver(c.opts, c.epoch, &1, &2, &3),
      settled: &Store.export_settled(c.opts, c.epoch, &1, &2),
      abandon: &Store.export_abandon(c.opts, c.epoch, &1, &2)
    }
  end

  defp credit(c, retained_count \\ 1, backing_count \\ 0) do
    retained = for _ <- 1..retained_count, do: reserve_committed(c, :analysis, byte_size(@body))

    backing =
      if backing_count == 0,
        do: [],
        else: for(_ <- 1..backing_count, do: reserve_committed(c, :source, byte_size(@body)))

    overlap = reserve_committed(c, :snapshot, 4096)
    %{retained: retained, backing: backing, overlap: overlap, unavailable: 0}
  end

  defp reserve_committed(c, kind, bytes) do
    assert {:ok, receipt} = Store.reserve_resource(c.opts, kind, bytes)
    assert :ok = Store.commit_resource(receipt, bytes)
    receipt
  end

  defp reserve(c, path) do
    operation = make_ref()
    assert {:ok, plan} = StagedIO.plan_source(path, @body, make_ref(), :retained)
    assert :ok = Store.export_reserve(c.opts, c.epoch, operation, plan)
    {operation, plan}
  end

  defp refs(credit), do: credit.retained ++ credit.backing ++ [credit.overlap]
  defp release_credit(credit), do: Enum.each(refs(credit), &Store.release_resource/1)

  defp companion do
    spawn(fn -> companion_loop(%{}) end)
  end

  defp companion_loop(deliveries) do
    receive do
      {:crawler_resource_delivery, _, _, _, reference, _} = delivery ->
        companion_loop(Map.put(deliveries, reference, delivery))

      {:perform, caller, reference, funding, release} ->
        delivery = Map.fetch!(deliveries, reference)
        deliveries = Map.delete(deliveries, reference)
        {:ok, {:write, plan, bytes}, _} = StagedIO.delivery(delivery, funding)
        owner = Process.whereis(Store)
        refs = Map.keys(funding.grants)
        for ref <- refs, do: send(owner, {:crawler_resource_adopted, ref, self()})
        filesystem = :sys.get_state(Store).exports[funding.run].filesystem
        result = StagedIO.write(plan, bytes, filesystem, funding)

        {released, held} =
          if release == :all, do: {refs, []}, else: Enum.split(refs, length(refs) - 1)

        for ref <- released, do: send(owner, {:crawler_resource_settled, ref, self(), :released})
        send(caller, {:performed, self(), reference, result, held})
        companion_loop(deliveries)

      {:release_without_adoption, _caller, reference, funding} ->
        delivery = Map.fetch!(deliveries, reference)
        {:ok, _, _} = StagedIO.delivery(delivery, funding)
        [adopted, receipt | _] = Map.keys(funding.grants)
        send(Store, {:crawler_resource_adopted, adopted, self()})
        send(Store, {:crawler_resource_settled, receipt, self(), :released})
        companion_loop(Map.delete(deliveries, reference))

      {:release, refs} ->
        for ref <- refs, do: send(Store, {:crawler_resource_settled, ref, self(), :released})
        companion_loop(deliveries)

      {:repeat, refs, caller} ->
        for ref <- refs do
          send(Store, {:crawler_resource_adopted, ref, self()})
          send(Store, {:crawler_resource_settled, ref, self(), :released})
        end

        send(Store, {:crawler_resource_settled, make_ref(), self(), :released})
        send(caller, {:repeated, self()})
        companion_loop(deliveries)

      {:mailbox, caller} ->
        {:messages, messages} = Process.info(self(), :messages)
        send(caller, {:mailbox, self(), messages ++ Map.values(deliveries)})
        companion_loop(deliveries)

      :stop ->
        :ok
    end
  end

  defp stop_companion(pid) do
    if Process.alive?(pid) do
      monitor = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2000
    end
  end

  defp eventually(callback, attempts \\ 200)
  defp eventually(callback, 0), do: assert(callback.())

  defp eventually(callback, attempts) do
    unless callback.() do
      receive do
      after
        5 -> eventually(callback, attempts - 1)
      end
    end
  end
end
