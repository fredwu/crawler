defmodule Crawler.Phase2.ExportIOStartupTest do
  use ExUnit.Case, async: false

  alias Crawler.Store
  alias Crawler.Store.Authority
  alias Crawler.Store.Execution

  setup do
    {tmp, 0} = System.cmd("pwd", ["-P"], cd: System.tmp_dir!())

    root =
      Path.join(
        String.trim(tmp),
        "crawler-io-start-" <> Base.encode16(:crypto.strong_rand_bytes(8))
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

  test "the owner records one scalar actor and ignores a false ready sender", c do
    assert :ok =
             Execution.run_job(options(c), fn owned ->
               {:ok, export} = Store.export_context(owned)
               {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)
               nonce = make_ref()
               assert {:ok, io} = Store.start_export_io(owned, export.epoch, nonce)

               assert {:error, :stale_start} =
                        Store.export_io_ready(
                          Process.whereis(Store),
                          owned.execution_lease,
                          nonce
                        )

               lease = owned.execution_lease
               assert_receive {:crawler_export_io_ready, ^nonce, ^io, ^lease}, 1000
               before = :sys.get_state(Store)
               row = before.export_io[lease]
               assert row.io === io
               assert row.startup_nonce === nonce
               assert row.status == :idle
               assert row.filesystem === filesystem.filesystem

               assert Authority.resource_current?(
                        row.metadata_receipt,
                        lease,
                        Process.whereis(Store)
                      )

               assert before.resources.receipts[row.metadata_receipt].actual == 32_768
               assert {:ok, ^io} = Store.start_export_io(owned, export.epoch, nonce)

               assert {:error, :already_running} =
                        Store.start_export_io(owned, export.epoch, make_ref())

               assert :sys.get_state(Store).export_io[lease].metadata_receipt ===
                        row.metadata_receipt

               send(io, {:stop, nonce})
               :ok
             end)
  end

  test "metadata remains funded until its owner observes actor death", c do
    parent = self()

    task =
      Task.async(fn ->
        Execution.run_job(options(c), fn owned ->
          {:ok, export} = Store.export_context(owned)
          {:ok, _} = Store.export_filesystem(owned, export.epoch)
          nonce = make_ref()
          {:ok, io} = Store.start_export_io(owned, export.epoch, nonce)
          lease = owned.execution_lease
          assert_receive {:crawler_export_io_ready, ^nonce, ^io, ^lease}, 1000
          metadata = :sys.get_state(Store).export_io[lease].metadata_receipt
          send(parent, {:held_actor, io, lease, metadata, self()})

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive {:held_actor, io, lease, metadata, executor}, 5000
    owner = Process.whereis(Store)
    monitor = Process.monitor(io)
    :ok = :sys.suspend(owner)

    try do
      Process.exit(io, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^io, :killed}, 1000
      assert Authority.resource_current?(metadata, lease, owner)
    after
      :ok = :sys.resume(owner)
    end

    send(executor, :finish)
    assert Task.await(task, 5000) == :ok
    assert eventually(fn -> :sys.get_state(Store).resources.receipts[metadata] == nil end)
    sibling = make_ref()
    assert :ok = Execution.run_job(%{options(c) | scope: sibling, save_to: nil}, fn _ -> :ok end)
    Store.dispose_scope(sibling)
  end

  test "idle actors share the original attempt deadline and release their row", c do
    parent = self()

    assert {:error, {:deadline, :attempt}} =
             Execution.run_job(Map.put(options(c), :attempt_timeout, 1000), fn owned ->
               {:ok, export} = Store.export_context(owned)
               {:ok, _} = Store.export_filesystem(owned, export.epoch)
               nonce = make_ref()
               {:ok, io} = Store.start_export_io(owned, export.epoch, nonce)
               lease = owned.execution_lease
               assert_receive {:crawler_export_io_ready, ^nonce, ^io, ^lease}, 1000
               send(parent, {:idle_actor, io, lease})

               receive do
                 :unreachable -> flunk("deadline was not enforced")
               end
             end)

    assert_receive {:idle_actor, io, lease}

    assert eventually(fn ->
             not Process.alive?(io) and :sys.get_state(Store).export_io[lease] == nil
           end)
  end

  defp options(c) do
    %{
      url: "https://example.test/actor",
      scope: c.scope,
      save_to: Path.join(c.root, "archive"),
      max_body: 1024,
      max_analysis_bytes: 1_048_576,
      max_manifest_bytes: 262_144,
      respect_robots: false,
      retries: 0,
      interval: 0
    }
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
