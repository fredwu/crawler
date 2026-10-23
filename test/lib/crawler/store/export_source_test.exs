defmodule Crawler.Store.ExportSourceTest do
  use ExUnit.Case, async: false

  import Crawler.TestHelpers, only: [wait: 1]

  alias Crawler.Export.Runtime
  alias Crawler.Export.Runtime.Context
  alias Crawler.Export.Stage
  alias Crawler.Fetcher
  alias Crawler.Frontier.Ring
  alias Crawler.Store
  alias Crawler.Store.Execution
  alias Crawler.Store.Page
  alias Crawler.Store.Resources

  @moduletag :tmp_dir
  @body <<0, 255, 1, 128>>

  setup %{tmp_dir: root} do
    File.chmod!(root, 0o700)
    Req.Test.set_req_test_to_shared()
    scope = make_ref()
    observer = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(observer, {:requested, conn.request_path})
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.resp(200, @body)
    end)

    on_exit(fn ->
      Store.dispose_scope(scope)

      wait(fn ->
        assert Enum.all?(:sys.get_state(Store).exports, fn {key, _} -> elem(key, 0) != scope end)
      end)

      Req.Test.set_req_test_to_private()
    end)

    %{root: root, scope: scope, barrier: make_ref()}
  end

  test "two canonical interpretations share one pending and acknowledged physical source", c do
    {first, second} = blocked_pair(c)

    try do
      before = assert_single_pending(c, first, second)
      assert before.failure == nil
      assert before.automatic == nil
      assert before.helper.session.manifest.responses == %{}
      refute File.exists?(source_file(first))

      assert :ok = :sys.resume(first.filesystem)
      barrier = c.barrier
      assert_receive {^barrier, :staged, :first, :ok, first_source}, 5_000
      assert_receive {^barrier, :staged, :second, :ok, second_source}, 5_000
      assert first_source === second_source
      assert is_reference(first_source)

      record = record(c, first)
      assert record.source_owners == %{}
      assert Ring.size(record.source_waiters) == 0
      assert Ring.size(record.source_ready) == 0
      assert record.helper.session.pending == %{}
      assert map_size(record.helper.session.staged) == 1
      assert map_size(record.helper.session.manifest.responses) == 1
      assert map_size(record.helper.session.manifest.targets) == 2

      assert Map.keys(record.helper.targets) |> MapSet.new() ==
               MapSet.new([first.target, second.target])

      for target <- [first.target, second.target] do
        row = record.helper.targets[target]
        assert row.descriptor.render_mode == :copy
        assert row.descriptor.source_operation === first_source
        assert row.bound.operation === first_source
      end

      assert :sys.get_state(first.filesystem).files == 1
      assert File.read!(source_file(first)) == @body
      assert_receive {:requested, "/copy"}
      refute_received {:requested, _}

      finish(c, first, :ok)
      finish(c, second, :ok)
    after
      cleanup_pair(c, first, second)
    end
  end

  for cause <- [:owner_down, :retirement] do
    test "#{cause} releases the source waiter but retains blocked filesystem custody", c do
      {first, second} = blocked_pair(c)
      cause = unquote(cause)

      try do
        pending = assert_single_pending(c, first, second)
        [operation] = Map.keys(pending.helper.session.pending)
        state = :sys.get_state(Store)
        custody = state.export_io[first.lease]
        assert custody.status == :delivered
        assert custody.operation === operation
        assert custody.filesystem === first.filesystem
        held = MapSet.to_list(custody.held)
        assert held != []
        assert_store_custody(held)
        filesystem_monitor = Process.monitor(first.filesystem)
        owner_monitor = Process.monitor(first.executor)

        case cause do
          :owner_down -> Process.exit(first.executor, :kill)
          :retirement -> Store.dispose_scope(c.scope)
        end

        assert_receive {:DOWN, ^owner_monitor, :process, _, _}, 5_000
        barrier = c.barrier
        assert_receive {^barrier, :returned, :first, first_result}, 5_000
        refute first_result == :ok
        assert_receive {^barrier, :returned, :second, second_result}, 5_000
        refute second_result == :ok

        wait(fn ->
          state = :sys.get_state(Store)
          record = state.exports[{c.scope, first.generation}]
          assert record
          assert record.retired? or not is_nil(record.failure)
          assert Ring.size(record.source_waiters) == 0
          assert Ring.size(record.source_ready) == 0
          assert state.export_io[first.lease].status == :poisoned
          assert state.export_io[first.lease].ended?
        end)

        if cause == :retirement do
          retired = %{scope: c.scope, generation: first.generation}

          assert {:ok, %{state: :cancelled, ready?: false, running?: false}} =
                   Crawler.export_status(retired)

          refute Store.generation(c.scope) === first.generation
          assert {:error, :stale} = Crawler.export_status(retired)
        end

        assert Process.alive?(first.filesystem)
        assert_store_custody(held)
        refute File.exists?(source_file(first))
        assert length(queued_source_reservations(first.filesystem)) == 1
        record = record(c, first)
        assert Map.keys(record.helper.session.pending) == [operation]
        assert record.helper.session.staged == %{}
        assert record.helper.session.manifest.responses == %{}
        refute File.exists?(source_file(first))
        refute File.exists?(Path.join(c.root, "archive"))

        assert :ok = :sys.resume(first.filesystem)
        assert_receive {:DOWN, ^filesystem_monitor, :process, _, _}, 5_000

        wait(fn ->
          state = :sys.get_state(Store)
          refute Map.has_key?(state.export_io, first.lease)
          refute Map.has_key?(state.export_io, second.lease)

          for receipt <- held, do: refute(Map.has_key?(state.export_io_resources, receipt))
        end)

        refute File.exists?(first.stage)
        refute File.exists?(Path.join(c.root, "archive"))

        if cause == :retirement,
          do:
            assert(
              {:error, :stale} =
                Crawler.export_status(%{scope: c.scope, generation: first.generation})
            )

        assert_receive {:requested, "/copy"}
        refute_received {:requested, _}
      after
        cleanup_pair(c, first, second)
      end
    end
  end

  defp blocked_pair(c) do
    first_call = start_producer(c, :first, %{})
    first = ready(c, :first, first_call)
    assert :ok = :sys.suspend(first.filesystem)

    on_exit(fn -> resume_filesystem(first.filesystem) end)
    send(first.executor, {c.barrier, :stage})

    wait(fn ->
      record = record(c, first)
      assert map_size(record.source_owners) == 1
      assert map_size(record.helper.session.pending) == 1
      assert length(queued_source_reservations(first.filesystem)) == 1
      assert :sys.get_state(Store).export_io[first.lease].status == :delivered
    end)

    second_call = start_producer(c, :second, %{generation: first.generation})
    second = ready(c, :second, second_call)
    assert second.filesystem === first.filesystem
    assert second.generation === first.generation
    assert second.representation === first.representation
    assert second.source_revision === first.source_revision
    refute second.target === first.target
    refute second.interpretation === first.interpretation
    send(second.executor, {c.barrier, :stage})

    wait(fn ->
      record = record(c, first)
      assert Ring.size(record.source_waiters) == 1
      assert Map.has_key?(record.source_waiters.members, second.lease)
    end)

    {first, second}
  end

  defp start_producer(c, label, extra) do
    observer = self()
    opts = Map.merge(options(c, label), extra)

    {caller, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            Execution.run_job(opts, &produce(&1, c.barrier, label, observer))
          catch
            kind, reason -> {kind, reason}
          end

        send(observer, {c.barrier, :returned, label, result})
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    %{caller: caller, monitor: monitor}
  end

  defp produce(owned, barrier, label, observer) do
    assert %Page{} = page = Fetcher.fetch(Map.put(owned, :save_to, nil))
    assert page.body === @body
    assert {:ok, export} = Store.export_context(owned)
    assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)

    try do
      Runtime.with_io(Context.new(owned, export.epoch, export.job, filesystem), fn runtime ->
        info = %{
          executor: self(),
          lease: owned.execution_lease,
          target: export.job.id,
          representation: export.job.representation_id,
          interpretation: export.job.interpretation_id,
          generation: owned.generation,
          filesystem: filesystem.filesystem,
          stage: filesystem.receipt.stage,
          path: export.assignment.source_path,
          source_revision: page.source_revision
        }

        send(observer, {barrier, :ready, label, info})
        assert_receive {^barrier, :stage}, 10_000
        result = Stage.source(runtime, page.interpretation, page.credit, export.assignment)
        stage_result(result, runtime, page, export, barrier, label, observer)
      end)
    after
      Store.release_resource(export.context_receipt)
    end
  end

  defp stage_result(:ok, runtime, page, export, barrier, label, observer) do
    assert {:ok, source, receipt} = Store.export_source_info(runtime.context.opts, export.epoch)

    operation = source.response.source_handle
    Store.release_resource(receipt)

    assert {:ok, 1} =
             Stage.stage(runtime, page.interpretation, page.credit, export.assignment, %{})

    send(observer, {barrier, :staged, label, :ok, operation})
    assert_receive {^barrier, :finish}, 10_000
    :ok
  end

  defp stage_result(error, _runtime, _page, _export, barrier, label, observer) do
    send(observer, {barrier, :staged, label, error, nil})
    error
  end

  defp ready(c, label, caller) do
    barrier = c.barrier
    assert_receive {^barrier, :ready, ^label, info}, 5_000
    Map.merge(info, caller)
  end

  defp assert_single_pending(c, first, second) do
    record = record(c, first)
    assert map_size(record.source_owners) == 1
    owner = record.source_owners[first.representation]
    assert owner.lease === first.lease
    assert Map.keys(owner.waiters.members) == [second.lease]
    assert Ring.size(record.source_waiters) == 1
    assert Ring.size(record.source_ready) == 0
    assert map_size(record.helper.session.pending) == 1
    assert record.helper.session.staged == %{}
    assert length(queued_source_reservations(first.filesystem)) == 1
    second_io = :sys.get_state(Store).export_io[second.lease]
    assert second_io.status == :idle
    assert second_io.operation == nil
    assert second_io.delivery_ref == nil
    record
  end

  defp queued_source_reservations(filesystem) do
    {:messages, messages} = Process.info(filesystem, :messages)

    Enum.filter(messages, fn
      {:"$gen_call", _, {:reserve, :source, _, _}} -> true
      _ -> false
    end)
  end

  defp assert_store_custody(receipts) do
    resources = :sys.get_state(Store).resources

    for receipt <- receipts,
        do: assert(Resources.receipt(resources, receipt).holders[Process.whereis(Store)])
  end

  defp finish(c, producer, expected) do
    send(producer.executor, {c.barrier, :finish})
    barrier = c.barrier
    caller = producer.caller
    monitor = producer.monitor
    assert_receive {^barrier, :returned, _, ^expected}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 5_000
  end

  defp cleanup_pair(c, first, second) do
    resume_filesystem(first.filesystem)
    for producer <- [first, second], do: send(producer.executor, {c.barrier, :finish})
    Store.dispose_scope(c.scope)

    wait(fn ->
      refute Process.alive?(first.filesystem)
      refute File.exists?(first.stage)
      refute Map.has_key?(:sys.get_state(Store).exports, {c.scope, first.generation})
    end)
  end

  defp resume_filesystem(filesystem) do
    if Process.alive?(filesystem), do: :sys.resume(filesystem)
  catch
    :exit, _ -> :ok
  end

  defp source_file(producer), do: Path.join([producer.stage, "source", producer.path])

  defp record(c, producer),
    do: :sys.get_state(Store).exports[{c.scope, producer.generation}]

  defp options(c, label),
    do: %{
      url: "https://export-source.test/copy",
      scope: c.scope,
      save_to: Path.join(c.root, "archive"),
      store: nil,
      style_group: "https://export-source.test/#{label}",
      respect_robots: false,
      cookie_navigation: false,
      max_body: 1_000_000,
      max_analysis_bytes: 16_000_000,
      max_manifest_bytes: 262_144,
      attempt_timeout: 15_000,
      interval: 0,
      retries: 0,
      req_options: [plug: {Req.Test, __MODULE__}, retry: false]
    }
end
