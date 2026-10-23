defmodule Crawler.Export.FilesystemTest do
  use ExUnit.Case, async: true

  alias Crawler.Export.Filesystem, as: FS

  @source Path.expand("../../../../lib/crawler/export/filesystem.ex", __DIR__)

  setup do
    {tmp, 0} = System.cmd("pwd", ["-P"], cd: System.tmp_dir!())
    root = Path.join(String.trim(tmp), "crawler-fs-test-" <> random())
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "dormant acquisition does no IO before exact activation and keeps one actor", %{root: root} do
    owner = self()
    nonce = make_ref()
    tracer = spawn(fn -> acquisition_trace([]) end)
    on_exit(fn -> Process.exit(tracer, :kill) end)
    modules = [File, :file, :prim_file, System, IO, :os]

    for module <- modules do
      {:module, ^module} = Code.ensure_loaded(module)
      :erlang.trace_pattern({module, :_, :_}, true, [:local])
    end

    {filesystem, monitor} =
      try do
        :erlang.trace(self(), true, [:call, :send, :procs, :set_on_spawn, {:tracer, tracer}])
        assert {:error, :not_owner} = FS.spawn_acquisition(root, "archive", nonce, owner: tracer)
        {:ok, filesystem, monitor} = FS.spawn_acquisition(root, "archive", nonce, owner: owner)
        {:flags, flags} = :erlang.trace_info(filesystem, :flags)
        assert :call in flags and :send in flags
        send(filesystem, {:crawler_filesystem_activate, make_ref(), owner})
        send(filesystem, {:crawler_filesystem_activate, nonce, filesystem})
        await_dormant_acquisition(filesystem, owner, 1000)
        delivered = :erlang.trace_delivered(filesystem)
        assert_receive {:trace_delivered, ^filesystem, ^delivered}
        reference = make_ref()
        send(tracer, {:events, self(), reference})
        assert_receive {^reference, events}

        assert Enum.any?(events, &match?({:trace, ^owner, :spawn, ^filesystem, _}, &1))

        refute Enum.any?(events, fn
                 {:trace, _, :call, _} -> true
                 {:trace, ^filesystem, :send, _, _} -> true
                 _ -> false
               end)

        assert File.ls!(root) == []
        refute_received {:crawler_filesystem_acquired, _, ^filesystem, _}
        :erlang.trace(filesystem, false, [:all])
        {filesystem, monitor}
      after
        :erlang.trace(self(), false, [:all])
        for module <- modules, do: :erlang.trace_pattern({module, :_, :_}, false, [:local])
        send(tracer, :stop)
      end

    send(filesystem, {:crawler_filesystem_activate, nonce, owner})
    send(filesystem, {:crawler_filesystem_activate, nonce, owner})
    assert_receive {:crawler_filesystem_acquired, ^nonce, ^filesystem, {:ok, receipt}}, 5000
    assert :ok = FS.write(filesystem, :archive, "one.bin", "one")
    send(filesystem, {:crawler_filesystem_activate, make_ref(), owner})
    {:ok, prepared} = FS.prepare(filesystem)
    assert FS.prepared_for?(prepared, receipt)
    assert :ok = FS.promote(prepared)
    refute FS.prepared_for?(prepared, receipt)
    assert {:ok, :promoted} = FS.finish(filesystem)
    assert_receive {:DOWN, ^monitor, :process, ^filesystem, :normal}
    refute_received {:crawler_filesystem_acquired, _, ^filesystem, _}
    assert File.read!(Path.join(root, "archive/one.bin")) == "one"
    assert {:ok, :promoted} = FS.recover(receipt)
  end

  test "dormant acquisition rejects a foreign owner, invalid nonce, and unsupported options", %{
    root: root
  } do
    other = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(other, :kill) end)
    nonce = make_ref()
    assert {:error, :not_owner} = FS.spawn_acquisition(root, "archive", nonce, owner: other)
    assert {:error, :invalid_nonce} = FS.spawn_acquisition(root, "archive", :nonce)
    assert {:error, :invalid_path} = FS.spawn_acquisition(root, "../archive", nonce)
    assert {:error, :invalid_limits} = FS.spawn_acquisition(root, "archive", nonce, deadline: 1)
    assert {:error, :invalid_limits} = FS.spawn_acquisition(root, "archive", nonce, max_files: 0)
    assert File.ls!(root) == []
  end

  test "owner death before activation stops the dormant acquisition without IO", %{root: root} do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, filesystem, _} = FS.spawn_acquisition(root, "archive", make_ref())
        send(parent, {:dormant_filesystem, self(), filesystem})
        receive do: (:never -> :ok)
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    assert_receive {:dormant_filesystem, ^owner, filesystem}
    monitor = Process.monitor(filesystem)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^filesystem, :normal}, 5000
    assert File.ls!(root) == []
  end

  test "activated acquisition reports setup failure directly and terminates", %{root: root} do
    nonce = make_ref()

    {:ok, filesystem, monitor} =
      FS.spawn_acquisition(Path.join(root, "missing"), "archive", nonce)

    send(filesystem, {:crawler_filesystem_activate, nonce, self()})

    assert_receive {:crawler_filesystem_acquired, ^nonce, ^filesystem,
                    {:error, :unclaimed, :enoent}},
                   5000

    assert_receive {:DOWN, ^monitor, :process, ^filesystem, :normal}
    assert File.ls!(root) == []
  end

  test "activated acquisition keeps normal abort and selected-owner death cleanup", %{root: root} do
    nonce = make_ref()
    {:ok, filesystem, monitor} = FS.spawn_acquisition(root, "aborted", nonce)
    send(filesystem, {:crawler_filesystem_activate, nonce, self()})
    assert_receive {:crawler_filesystem_acquired, ^nonce, ^filesystem, {:ok, receipt}}, 5000
    assert :ok = FS.write(filesystem, :archive, "one.bin", "one")
    assert {:ok, :aborted} = FS.abort(filesystem)
    assert_receive {:DOWN, ^monitor, :process, ^filesystem, :normal}
    refute File.exists?(receipt.stage)
    parent = self()

    owner =
      spawn(fn ->
        nonce = make_ref()
        {:ok, filesystem, _} = FS.spawn_acquisition(root, "owner-down", nonce)
        send(filesystem, {:crawler_filesystem_activate, nonce, self()})

        receive do
          {:crawler_filesystem_acquired, ^nonce, ^filesystem, {:ok, receipt}} ->
            send(parent, {:owned_filesystem, self(), filesystem, receipt})
        end

        receive do: (:never -> :ok)
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    assert_receive {:owned_filesystem, ^owner, filesystem, receipt}, 5000
    monitor = Process.monitor(filesystem)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^filesystem, :normal}, 5000
    refute File.exists?(receipt.stage)
    refute File.exists?(receipt.claim)
    assert root_entries(root) == []
  end

  test "actor death during acquisition preserves an unknown partial claim for manual recovery", %{
    root: root
  } do
    child = child(root, :blocked_acquisition)

    assert {:blocked_acquisition, :killed, {:error, :destination_owned}, false, []} =
             child_result(child)

    kill(child)
    claim = Path.join([root, ".crawler-fs-claims", "archive"])
    assert File.dir?(claim)
    assert File.ls!(claim) == []
    assert {:error, :destination_owned} = FS.acquire(root, "archive")
    assert {:error, :invalid_receipt} = FS.recover(%{})
    assert File.dir?(claim)
  end

  test "registered owner death during setup keeps the original PID and cleans after IO returns",
       %{
         root: root
       } do
    child = child(root, :owner_down_acquisition)
    assert {:owner_down_acquisition, :normal, false} = child_result(child)
    kill(child)
    refute File.exists?(Path.join([root, ".crawler-fs-claims", "archive"]))
    refute File.exists?(Path.join(root, "archive"))
  end

  test "private stage and complete same-filesystem archive promotion", %{root: root} do
    {:ok, owner, receipt} = FS.acquire(root, "archive")
    assert Bitwise.band(File.stat!(receipt.stage).mode, 0o777) == 0o700
    assert File.stat!(receipt.stage).major_device == File.stat!(root).major_device
    assert :ok = FS.write(owner, :source, "body.bin", "original")
    assert :ok = FS.write(owner, :metadata, "analysis.bin", "analysis")
    assert :ok = FS.write(owner, :archive, "assets/style.css", "body {}")
    refute File.exists?(Path.join(root, "archive"))
    assert :ok = commit(owner)
    assert File.read!(Path.join(root, "archive/assets/style.css")) == "body {}"
    assert {:error, :sealed} = FS.write(owner, :archive, "late.bin", "late")
    assert {:ok, :promoted} = FS.abort(owner)
    refute File.exists?(receipt.stage)
    assert File.dir?(receipt.claim)
    assert {:ok, :promoted} = FS.recover(receipt)
    assert File.read!(Path.join(root, "archive/assets/style.css")) == "body {}"
    assert {:error, :destination_exists} = FS.acquire(root, "archive")
    assert {:error, :destination_owned} = FS.publish_file(root, "archive/new.bin", "intrude")

    assert {:error, :destination_owned} =
             FS.publish_file(Path.join(root, "archive"), "new.bin", "intrude")

    assert {:error, :destination_owned} =
             FS.publish_file(Path.join(root, "archive/assets"), "new.bin", "intrude")
  end

  test "source, metadata, and outstanding reservations share bounded disk accounting", %{
    root: root
  } do
    {:ok, owner, _} =
      FS.acquire(root, "archive", max_bytes: 10, max_file_bytes: 8, max_metadata_bytes: 3)

    assert {:ok, reservation} = FS.reserve(owner, :source, "source.bin", 6)
    assert {:error, :file_limit} = FS.reserve(owner, :archive, "large.bin", 9)
    assert {:error, :metadata_limit} = FS.write(owner, :metadata, "large.bin", "four")
    assert :ok = FS.write(owner, :metadata, "meta.bin", "abc")
    assert {:error, :byte_limit} = FS.write(owner, :archive, "result.bin", "ab")
    assert :ok = FS.write(owner, reservation, "source")
    assert {:error, :invalid_reservation} = FS.write(owner, reservation, "source")
    assert :ok = FS.write(owner, :archive, "result.bin", "x")
    assert {:ok, :aborted} = FS.abort(owner)
    assert root_entries(root) == []
  end

  test "a reservation cannot be reused or written with a different size", %{root: root} do
    {:ok, owner, _} = FS.acquire(root, "archive", max_files: 1)
    {:ok, ticket} = FS.reserve(owner, :archive, "one.bin", 2)
    assert {:error, :file_count_limit} = FS.reserve(owner, :archive, "two.bin", 0)
    assert {:error, :reservation_size} = FS.write(owner, ticket, "bad")
    assert {:error, :failed} = commit(owner)
    assert {:ok, :aborted} = FS.abort(owner)
  end

  test "exclusive artifact creation refuses colliding names and preserves the existing bytes", %{
    root: root
  } do
    {:ok, owner, receipt} = FS.acquire(root, "archive")
    assert :ok = FS.write(owner, :archive, "one.bin", "one")
    assert {:error, :eexist} = FS.write(owner, :archive, "one.bin", "two")
    foreign = Path.join(receipt.stage, "archive/foreign.bin")
    File.write!(foreign, "unrelated")
    assert {:error, :eexist} = FS.write(owner, :archive, "foreign.bin", "replace")
    assert File.read!(foreign) == "unrelated"
    assert {:error, :failed} = commit(owner)
    assert {:error, reason} = FS.abort(owner)
    assert reason in [:enotempty, :eexist]
    assert File.read!(foreign) == "unrelated"
    assert File.exists?(receipt.claim)
    refute File.exists?(Path.join(root, "archive"))
  end

  test "pending reservations cannot be promoted", %{root: root} do
    {:ok, owner, _} = FS.acquire(root, "archive")
    assert {:ok, _} = FS.reserve(owner, :source, "pending.bin", 8)
    assert {:error, :pending_reservations} = commit(owner)
    refute File.exists?(Path.join(root, "archive"))
    assert {:ok, :aborted} = FS.abort(owner)
  end

  test "rejects a shared root, symlink root, and symlink ancestors", %{root: root} do
    File.chmod!(root, 0o777)
    assert {:error, :unsafe_root} = FS.acquire(root, "archive")
    File.chmod!(root, 0o700)
    real = Path.join(root, "real")
    File.mkdir!(real)
    File.chmod!(real, 0o700)
    link = Path.join(root, "link")
    File.ln_s!(real, link)
    assert {:error, :unsafe_path} = FS.acquire(link, "archive")
    File.mkdir!(Path.join(real, "child"))
    File.chmod!(Path.join(real, "child"), 0o700)
    assert {:error, :unsafe_path} = FS.acquire(Path.join(link, "child"), "archive")
    assert File.ls!(real) == ["child"]
  end

  test "a private root below a shared non-sticky ancestor is refused", %{root: root} do
    shared = Path.join(root, "shared")
    private = Path.join(shared, "private")
    File.mkdir!(shared)
    File.chmod!(shared, 0o777)
    File.mkdir!(private)
    File.chmod!(private, 0o700)
    assert {:error, :unsafe_root} = FS.acquire(private, "archive")
    assert File.ls!(private) == []
    assert {_, 0} = System.cmd("chmod", ["+t", shared])
    {:ok, owner, _} = FS.acquire(private, "archive")
    assert {:ok, :aborted} = FS.abort(owner)
  end

  test "managed and standalone destinations never follow symlinks", %{root: root} do
    outside = Path.join(root, "outside")
    File.mkdir!(outside)
    File.chmod!(outside, 0o700)
    File.write!(Path.join(outside, "existing.bin"), "previous")
    File.ln_s!(outside, Path.join(root, "archive"))
    assert {:error, :destination_exists} = FS.acquire(root, "archive")
    assert {:error, :unsafe_path} = FS.publish_file(root, "archive/next.bin", "new")
    File.ln_s!(Path.join(outside, "existing.bin"), Path.join(root, "link.bin"))
    assert {:error, :unsafe_path} = FS.publish_file(root, "link.bin", "replace")
    assert File.read!(Path.join(outside, "existing.bin")) == "previous"
    refute File.exists?(Path.join(outside, "next.bin"))
  end

  test "rejects stage-area symlinks even for direct children", %{root: root} do
    {:ok, owner, receipt} = FS.acquire(root, "archive")
    outside = Path.join(root, "outside")
    File.mkdir!(outside)
    File.chmod!(outside, 0o700)
    area = Path.join(receipt.stage, "archive")
    File.rmdir!(area)
    File.ln_s!(outside, area)
    assert {:error, :unsafe_path} = FS.write(owner, :archive, "escape.bin", "no")
    assert {:error, :ownership_changed} = FS.abort(owner)
    assert File.ls!(outside) == []
    assert File.lstat!(area).type == :symlink
  end

  test "a replaced owned file and unrelated nested files survive cleanup", %{root: root} do
    {:ok, owner, receipt} = FS.acquire(root, "archive")
    assert :ok = FS.write(owner, :source, "nested/source.bin", "owned")
    file = Path.join(receipt.stage, "source/nested/source.bin")
    File.rename!(file, file <> ".saved")
    File.write!(file, "replacement")
    unrelated = Path.join(receipt.stage, "source/nested/unrelated.bin")
    File.write!(unrelated, "unrelated")
    assert {:error, :ownership_changed} = FS.abort(owner)
    assert File.read!(file) == "replacement"
    assert File.read!(unrelated) == "unrelated"
    assert File.read!(file <> ".saved") == "owned"
    assert File.exists?(receipt.claim)
  end

  test "promotion refuses every existing destination and preserves the previous archive", %{
    root: root
  } do
    {:ok, owner, receipt} = FS.acquire(root, "archive")
    assert :ok = FS.write(owner, :archive, "new.bin", "new")
    previous = Path.join(root, "archive")
    File.mkdir!(previous)
    File.write!(Path.join(previous, "previous.bin"), "previous complete archive")
    assert {:error, :destination_exists} = commit(owner)
    assert {:ok, :aborted} = FS.abort(owner)
    refute File.exists?(receipt.stage)
    assert File.ls!(previous) == ["previous.bin"]
    assert File.read!(Path.join(previous, "previous.bin")) == "previous complete archive"
    assert {:error, :destination_exists} = FS.acquire(root, "archive")
  end

  test "entry exhaustion during promotion leaves no destination", %{root: root} do
    {:ok, owner, receipt} = FS.acquire(root, "archive", max_entries: 4)
    assert :ok = FS.write(owner, :archive, "one.bin", "one")
    assert {:error, :entry_limit} = commit(owner)
    refute File.exists?(Path.join(root, "archive"))
    assert {:ok, :aborted} = FS.abort(owner)
    refute File.exists?(receipt.stage)
  end

  test "bounded metadata refuses oversize and corrupt recovery journals", %{root: root} do
    {:ok, owner, receipt} = FS.acquire(root, "archive", max_journal_bytes: 8192)
    journal = Path.join(receipt.claim, "journal")
    original = File.read!(journal)
    File.write!(journal, String.duplicate("x", 8193))
    assert {:error, :metadata_limit} = FS.recover(receipt)
    assert File.dir?(receipt.stage)
    File.write!(journal, original <> <<0, 0, 0, 9, 1>>)
    assert {:error, :invalid_journal} = FS.recover(receipt)
    assert File.dir?(receipt.stage)
    File.write!(journal, original)
    assert {:ok, :aborted} = FS.abort(owner)
  end

  test "invalid path and limit contracts do not claim a destination", %{root: root} do
    for path <- [
          "../outside",
          "/absolute",
          "a//b",
          "a/./b",
          "a/../b",
          "http://user:pass@host",
          ".crawler-fs-secret",
          "a\\b"
        ] do
      assert {:error, :invalid_path} = FS.publish_file(root, path, "no")
    end

    for opts <- [[max_bytes: 0], [max_bytes: :infinity], [unknown: 1]] do
      assert {:error, :invalid_limits} = FS.acquire(root, "archive", opts)
    end

    assert root_entries(root) == []
  end

  test "only the selected owner can use the prepared handle, while an IO worker can abort", %{
    root: root
  } do
    {:ok, filesystem, _} = FS.acquire(root, "archive")
    assert :ok = FS.write(filesystem, :archive, "one.bin", "one")
    {:ok, prepared} = FS.prepare(filesystem)
    task = Task.async(fn -> {FS.promote(prepared), FS.cancel(prepared)} end)
    assert {{:error, :not_owner}, {:error, :not_owner}} = Task.await(task)
    assert {:ok, :aborted} = Task.async(fn -> FS.abort(filesystem) end) |> Task.await()
    assert {:error, :closed} = FS.promote(prepared)
    refute File.exists?(Path.join(root, "archive"))
  end

  test "an IO worker can prepare staging for a separately selected commit owner", %{root: root} do
    commit_owner = self()

    worker =
      Task.async(fn ->
        {:ok, filesystem, receipt} = FS.acquire(root, "archive", owner: commit_owner)
        assert :ok = FS.write(filesystem, :archive, "one.bin", "one")
        {:ok, prepared} = FS.prepare(filesystem)
        assert {:error, :not_owner} = FS.promote(prepared)
        {filesystem, receipt, prepared}
      end)

    {filesystem, receipt, prepared} = Task.await(worker)
    assert Process.alive?(filesystem)
    assert :ok = FS.promote(prepared)
    assert {:ok, :promoted} = FS.finish(filesystem)
    refute File.exists?(receipt.stage)
    assert File.read!(Path.join(root, "archive/one.bin")) == "one"
  end

  test "same-VM owner death triggers bounded owned cleanup", %{root: root} do
    parent = self()

    {caller, ref} =
      spawn_monitor(fn ->
        {:ok, owner, receipt} = FS.acquire(root, "archive")
        :ok = FS.write(owner, :archive, "one.bin", "one")
        send(parent, {:staged, owner, receipt})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:staged, owner, receipt}, 5000
    owner_ref = Process.monitor(owner)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, _, _, :killed}, 5000
    assert_receive {:DOWN, ^owner_ref, _, _, :normal}, 5000
    refute File.exists?(receipt.stage)
    assert root_entries(root) == []
  end

  test "standalone replacement is complete and leaves unrelated files intact", %{root: root} do
    File.write!(Path.join(root, "keep.bin"), "keep")
    assert :ok = FS.publish_file(root, "nested/file.bin", "old")
    assert :ok = FS.publish_file(root, "nested/file.bin", String.duplicate("new", 10000))
    assert File.read!(Path.join(root, "nested/file.bin")) == String.duplicate("new", 10000)
    assert File.read!(Path.join(root, "keep.bin")) == "keep"
    assert Enum.sort(root_entries(root)) == ["keep.bin", "nested"]
  end

  test "standalone paths starting above a nested managed destination cannot enter it", %{
    root: root
  } do
    container = Path.join(root, "container")
    File.mkdir!(container)
    File.chmod!(container, 0o700)
    {:ok, owner, _} = FS.acquire(container, "archive")
    assert :ok = FS.write(owner, :archive, "one.bin", "one")

    assert {:error, :destination_owned} =
             FS.publish_file(root, "container/archive/next.bin", "no")

    refute File.exists?(Path.join(container, "archive"))
    assert :ok = commit(owner)
    assert {:ok, :promoted} = FS.abort(owner)

    assert {:error, :destination_owned} =
             FS.publish_file(root, "container/archive/next.bin", "no")

    assert File.ls!(Path.join(container, "archive")) == ["one.bin"]
  end

  test "a live managed claim refuses standalone access before promotion", %{root: root} do
    {:ok, owner, receipt} = FS.acquire(root, "archive")
    assert {:error, :destination_owned} = FS.acquire(root, "archive")
    assert {:error, :destination_owned} = FS.publish_file(root, "archive/entry.bin", "intrude")
    assert {:ok, :aborted} = FS.abort(owner)
    refute File.exists?(receipt.stage)
    assert :ok = FS.publish_file(root, "archive/entry.bin", "standalone")
  end

  test "two real VMs contend for one destination and only its receipt permits recovery", %{
    root: root
  } do
    first = child(root, :staged)
    second = child(root, :staged)
    results = [child_result(first), child_result(second)]
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :destination_owned})) == 1
    {:ok, receipt} = Enum.find(results, &match?({:ok, _}, &1))
    kill(first)
    kill(second)
    assert {:error, :destination_owned} = FS.acquire(root, "archive")
    assert {:error, :ownership_changed} = FS.recover(%{receipt | header: "different capability"})
    assert {:ok, :aborted} = FS.recover(receipt)
    assert root_entries(root) == []
    {:ok, owner, _} = FS.acquire(root, "archive")
    assert {:ok, :aborted} = FS.abort(owner)
  end

  for {window, expected} <- [{:before_rename, :aborted}, {:after_rename, :promoted}] do
    test "whole-VM kill #{window} recovers the rename intent without deleting unrelated files", %{
      root: root
    } do
      window = unquote(window)
      child = child(root, window)
      assert {:ok, receipt} = child_result(child)
      unrelated = Path.join(root, "unrelated.bin")
      File.write!(unrelated, "keep")
      kill(child)
      outcome = unquote(expected)
      assert {:ok, ^outcome} = FS.recover(receipt)
      assert File.read!(unrelated) == "keep"
      refute File.exists?(receipt.stage)

      if outcome == :promoted do
        assert File.read!(Path.join(root, "archive/one.bin")) == "one"
        assert {:error, :destination_owned} = FS.publish_file(root, "archive/next.bin", "intrude")
        assert {:ok, :promoted} = FS.recover(receipt)
      else
        refute File.exists?(Path.join(root, "archive"))
      end
    end
  end

  test "standalone reservation failure preserves the previous complete file", %{root: root} do
    target = Path.join(root, "file.bin")
    File.write!(target, "previous")
    {:ok, owner, _} = FS.acquire_file(root, "file.bin")
    assert {:error, :destination_owned} = FS.publish_file(root, "file.bin", "intrude")
    assert :ok = FS.write(owner, :archive, "file.bin", "next")
    {:ok, _} = FS.reserve(owner, :source, "pending.bin", 1)
    assert {:error, :pending_reservations} = commit(owner)
    assert File.read!(target) == "previous"
    assert {:ok, :aborted} = FS.abort(owner)
    assert File.read!(target) == "previous"
  end

  test "unknown stage children are preserved without a recursive cleanup scan", %{root: root} do
    {:ok, owner, receipt} = FS.acquire(root, "archive")
    assert :ok = FS.write(owner, :archive, "owned.bin", "owned")
    foreign = Path.join(receipt.stage, "unknown")
    File.mkdir!(foreign)

    for number <- 1..20 do
      File.write!(Path.join(foreign, Integer.to_string(number)), "unrelated")
    end

    assert {:error, reason} = FS.abort(owner)
    assert reason in [:enotempty, :eexist]
    assert length(File.ls!(foreign)) == 20
    assert File.exists?(Path.join(receipt.claim, "owner"))
    assert File.exists?(Path.join(receipt.claim, "journal"))
  end

  test "changing the stage root or an area directory prevents writes and promotion", %{root: root} do
    {:ok, owner, receipt} = FS.acquire(root, "archive")
    area = Path.join(receipt.stage, "archive")
    File.rename!(area, area <> ".original")
    File.mkdir!(area)
    File.chmod!(area, 0o700)
    assert {:error, :ownership_changed} = FS.write(owner, :archive, "next.bin", "no")
    assert {:error, :ownership_changed} = FS.abort(owner)
    assert File.ls!(area) == []
    assert File.dir?(area <> ".original")
  end

  test "existing empty destinations are also refused", %{root: root} do
    File.mkdir!(Path.join(root, "archive"))
    assert {:error, :destination_exists} = FS.acquire(root, "archive")
    assert File.ls!(Path.join(root, "archive")) == []
  end

  test "recovery rejects compressed external terms and malformed receipts", %{root: root} do
    {:ok, owner, receipt} = FS.acquire(root, "archive")
    assert {:error, :invalid_receipt} = FS.recover(%{})
    journal = Path.join(receipt.claim, "journal")
    original = File.read!(journal)
    compressed = :erlang.term_to_binary(String.duplicate("x", 1_000_000), [:compressed])
    assert byte_size(compressed) < 4096
    File.write!(journal, original <> <<byte_size(compressed)::32, compressed::binary>>)
    assert {:error, :invalid_journal} = FS.recover(receipt)
    File.write!(journal, original)
    assert {:ok, :aborted} = FS.abort(owner)
  end

  for {window, expected} <- [
        {:standalone_before_rename, :aborted},
        {:standalone_after_rename, :promoted}
      ] do
    test "whole-VM standalone kill #{window} preserves complete file replacement", %{root: root} do
      File.write!(Path.join(root, "file.bin"), "previous")
      child = child(root, unquote(window))
      assert {:ok, receipt} = child_result(child)
      kill(child)
      assert {:ok, unquote(expected)} = FS.recover(receipt)
      expected_body = unquote(if expected == :promoted, do: "one", else: "previous")
      assert File.read!(Path.join(root, "file.bin")) == expected_body
      refute File.exists?(receipt.claim)
      refute File.exists?(receipt.stage)
    end
  end

  test "prepared association binds each usable handle to its exact receipt and selected owner", %{
    root: root
  } do
    selected_owner = self()
    {:ok, first, first_receipt} = FS.acquire(root, "first", owner: selected_owner)
    {:ok, second, second_receipt} = FS.acquire(root, "second", owner: selected_owner)
    assert :ok = FS.write(first, :archive, "one.bin", "one")
    assert :ok = FS.write(second, :archive, "two.bin", "two")
    {:ok, first_handle} = FS.prepare(first)
    {:ok, second_handle} = FS.prepare(second)
    :ok = :sys.suspend(first)
    :ok = :sys.suspend(second)

    try do
      assert FS.prepared_for?(first_handle, first_receipt)
      assert FS.prepared_for?(second_handle, second_receipt)
      refute FS.prepared_for?(first_handle, second_receipt)
      refute FS.prepared_for?(second_handle, first_receipt)
      refute FS.prepared_for?(first_handle, Map.put(first_receipt, :extra, true))
      refute FS.prepared_for?(first_handle, Map.delete(first_receipt, :header))
      refute FS.prepared_for?(first_handle, %{first_receipt | id: "wrong"})

      refute FS.prepared_for?(first_handle, %{
               first_receipt
               | limits: %{first_receipt.limits | max_files: first_receipt.limits.max_files * 1.0}
             })

      assert {false, false} =
               Task.async(fn ->
                 {FS.prepared_for?(first_handle, first_receipt),
                  FS.prepared_for?(second_handle, second_receipt)}
               end)
               |> Task.await()

      guarded_promotion =
        if FS.prepared_for?(second_handle, first_receipt),
          do: FS.promote(second_handle),
          else: {:error, :wrong_preparation}

      assert guarded_promotion == {:error, :wrong_preparation}
      refute File.exists?(Path.join(root, "first"))
      refute File.exists?(Path.join(root, "second"))
      refute String.contains?(inspect(first_handle), first_receipt.stage)
      refute String.contains?(inspect(second_handle), second_receipt.claim)
      assert FS.prepared_for?(first_handle, first_receipt)
      assert FS.prepared_for?(second_handle, second_receipt)
      assert :ok = FS.promote(first_handle)
      refute FS.prepared_for?(first_handle, first_receipt)
      assert :ok = FS.cancel(second_handle)
      refute FS.prepared_for?(second_handle, second_receipt)
      assert {:error, :closed} = FS.promote(first_handle)
      assert {:error, :closed} = FS.promote(second_handle)
    after
      :sys.resume(first)
      :sys.resume(second)
    end

    assert {:ok, :promoted} = FS.finish(first)
    assert {:ok, :aborted} = FS.finish(second)
    assert File.read!(Path.join(root, "first/one.bin")) == "one"
    refute File.exists?(Path.join(root, "second"))
    assert {:ok, :promoted} = FS.recover(first_receipt)
    refute File.exists?(second_receipt.stage)
  end

  test "prepared association rejects malformed handles and receipts", %{root: root} do
    {:ok, filesystem, receipt} = FS.acquire(root, "archive")
    {:ok, prepared} = FS.prepare(filesystem)

    for invalid <- [
          nil,
          filesystem,
          {},
          {:crawler_filesystem_prepared, :not_a_function},
          {:crawler_filesystem_prepared, fn -> true end},
          {:wrong_tag, fn _ -> true end},
          {:crawler_filesystem_prepared, fn _ -> :ok end},
          {:crawler_filesystem_prepared, fn :promote -> :ok end}
        ] do
      refute FS.prepared_for?(invalid, receipt)
    end

    for invalid <- [nil, %{}, receipt.stage, {:receipt, receipt}] do
      refute FS.prepared_for?(prepared, invalid)
    end

    assert FS.prepared_for?(prepared, receipt)
    assert :ok = FS.cancel(prepared)
    assert {:ok, :aborted} = FS.finish(filesystem)
    refute FS.prepared_for?(prepared, receipt)
  end

  test "preparation seals writes and owner-local promotion does not wait on the filesystem actor",
       %{root: root} do
    {:ok, filesystem, _} = FS.acquire(root, "archive")
    assert :ok = FS.write(filesystem, :archive, "one.bin", "one")
    {:ok, prepared} = FS.prepare(filesystem)
    assert {:error, :sealed} = FS.reserve(filesystem, :source, "late.bin", 1)
    assert {:error, :sealed} = FS.write(filesystem, :archive, "late.bin", "no")
    assert {:error, :not_terminal} = FS.finish(filesystem)
    :ok = :sys.suspend(filesystem)

    try do
      assert :ok = FS.promote(prepared)
      assert {:error, :closed} = FS.promote(prepared)
      assert {:error, :closed} = FS.cancel(prepared)
      assert File.read!(Path.join(root, "archive/one.bin")) == "one"
    after
      :sys.resume(filesystem)
    end

    assert {:ok, :promoted} = Task.async(fn -> FS.finish(filesystem) end) |> Task.await()
  end

  test "owner-local cancellation does no worker IO and prevents stale prepared promotion", %{
    root: root
  } do
    {:ok, filesystem, receipt} = FS.acquire(root, "archive")
    assert :ok = FS.write(filesystem, :archive, "one.bin", "one")
    {:ok, prepared} = FS.prepare(filesystem)
    :ok = :sys.suspend(filesystem)

    try do
      assert :ok = FS.cancel(prepared)
      assert {:error, :closed} = FS.promote(prepared)
      refute File.exists?(Path.join(root, "archive"))
    after
      :sys.resume(filesystem)
    end

    assert {:ok, :aborted} = Task.async(fn -> FS.finish(filesystem) end) |> Task.await()
    refute File.exists?(receipt.stage)
  end

  test "a blocked preparation cannot occupy or outlive its selected commit owner's authority", %{
    root: root
  } do
    parent = self()

    selected_owner =
      spawn(fn ->
        receive do
          {:ping, caller} -> send(caller, :owner_responsive)
        end

        receive do
          :never -> :ok
        end
      end)

    owner_ref = Process.monitor(selected_owner)
    {:ok, filesystem, receipt} = FS.acquire(root, "archive", owner: selected_owner)
    fs_ref = Process.monitor(filesystem)
    assert :ok = FS.write(filesystem, :archive, "one.bin", "one")
    :ok = :sys.suspend(filesystem)

    worker =
      Task.async(fn ->
        send(parent, :preparing)
        FS.prepare(filesystem)
      end)

    assert_receive :preparing
    await_prepare_request(filesystem, 1000)
    send(selected_owner, {:ping, self()})
    assert_receive :owner_responsive
    assert Task.yield(worker, 0) == nil
    Process.exit(selected_owner, :kill)
    assert_receive {:DOWN, ^owner_ref, _, _, :killed}
    :ok = :sys.resume(filesystem)
    assert {:error, :owner_down} = Task.await(worker)
    assert_receive {:DOWN, ^fs_ref, _, _, :normal}, 5000
    refute File.exists?(Path.join(root, "archive"))
    refute File.exists?(receipt.stage)
  end

  test "an independent filesystem actor cannot promote after selected owner death", %{root: root} do
    parent = self()

    selected_owner =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    owner_ref = Process.monitor(selected_owner)
    {:ok, filesystem, receipt} = FS.acquire(root, "archive", owner: selected_owner)
    assert :ok = FS.write(filesystem, :archive, "one.bin", "one")
    {:ok, prepared} = FS.prepare(filesystem)
    :ok = :sys.suspend(filesystem)
    fs_ref = Process.monitor(filesystem)
    Process.exit(selected_owner, :kill)
    assert_receive {:DOWN, ^owner_ref, _, _, :killed}

    :sys.replace_state(filesystem, fn state ->
      send(parent, {:actor_result, FS.promote(prepared)})
      state
    end)

    assert_receive {:actor_result, {:error, :not_owner}}
    assert {:error, :not_owner} = FS.promote(prepared)
    refute File.exists?(Path.join(root, "archive"))
    :ok = :sys.resume(filesystem)
    assert_receive {:DOWN, ^fs_ref, _, _, :normal}
    refute File.exists?(receipt.stage)
  end

  test "fixed local checks preserve a destination created after preparation", %{root: root} do
    {:ok, filesystem, receipt} = FS.acquire(root, "archive")
    assert :ok = FS.write(filesystem, :archive, "one.bin", "one")
    {:ok, prepared} = FS.prepare(filesystem)
    File.mkdir!(Path.join(root, "archive"))
    File.write!(Path.join(root, "archive/previous.bin"), "previous")
    assert FS.prepared_for?(prepared, receipt)
    assert {:error, :destination_exists} = FS.promote(prepared)
    refute FS.prepared_for?(prepared, receipt)
    assert {:ok, :aborted} = FS.finish(filesystem)
    assert File.read!(Path.join(root, "archive/previous.bin")) == "previous"
  end

  test "standalone local checks preserve an unrelated replacement after preparation", %{
    root: root
  } do
    file = Path.join(root, "file.bin")
    File.write!(file, "previous")
    {:ok, filesystem, _} = FS.acquire_file(root, "file.bin")
    assert :ok = FS.write(filesystem, :archive, "file.bin", "next")
    {:ok, prepared} = FS.prepare(filesystem)
    File.rename!(file, file <> ".previous")
    File.write!(file, "unrelated replacement")
    assert {:error, :ownership_changed} = FS.promote(prepared)
    assert {:ok, :aborted} = FS.finish(filesystem)
    assert File.read!(file) == "unrelated replacement"
    assert File.read!(file <> ".previous") == "previous"
  end

  test "normal read-accessible parents and ordinary Unicode names are supported without chmod", %{
    root: root
  } do
    File.chmod!(root, 0o755)
    destination = "My archive – 日本 (v1)"
    {:ok, filesystem, receipt} = FS.acquire(root, destination)
    assert Bitwise.band(File.stat!(root).mode, 0o777) == 0o755
    assert Bitwise.band(File.stat!(receipt.stage).mode, 0o777) == 0o700
    assert Bitwise.band(File.stat!(receipt.claim).mode, 0o777) == 0o700
    assert :ok = FS.write(filesystem, :archive, "sub dir/café @2x.svg", "svg")
    assert :ok = commit(filesystem)
    assert {:ok, :promoted} = FS.finish(filesystem)
    assert File.read!(Path.join([root, destination, "sub dir/café @2x.svg"])) == "svg"
    existing_parent = Path.join(root, "existing parent")
    File.mkdir!(existing_parent)
    File.chmod!(existing_parent, 0o755)
    assert :ok = FS.publish_file(root, "existing parent/file name.json", "json")
    assert Bitwise.band(File.stat!(existing_parent).mode, 0o777) == 0o755
    assert Bitwise.band(File.stat!(root).mode, 0o777) == 0o755
  end

  test "ordinary safe destination segments retain filesystem name bounds", %{root: root} do
    destination = String.duplicate("a", 255)
    {:ok, filesystem, _} = FS.acquire(root, destination)
    assert {:ok, :aborted} = FS.abort(filesystem)
    assert {:error, :invalid_path} = FS.acquire(root, destination <> "a")

    for name <- [".", "..", "has/slash", "has\\slash", "nul" <> <<0>>, ".CRAWLER-FS-reserved"] do
      assert {:error, :invalid_path} = FS.acquire(root, name)
    end
  end

  test "claim names follow native filesystem case and Unicode alias rules", %{root: root} do
    for {left, right} <- [{"Archive", "archive"}, {"café", "cafe\u0301"}] do
      probe = Path.join(root, left)
      File.mkdir!(probe)
      aliases = File.dir?(Path.join(root, right))
      File.rmdir!(probe)
      {:ok, first, _} = FS.acquire(root, left)

      if aliases do
        assert {:error, :destination_owned} = FS.acquire(root, right)
      else
        {:ok, second, _} = FS.acquire(root, right)
        assert {:ok, :aborted} = FS.abort(second)
      end

      assert {:ok, :aborted} = FS.abort(first)
    end
  end

  test "an unrelated registry is refused and preserved", %{root: root} do
    registry = Path.join(root, ".crawler-fs-claims")
    File.mkdir!(registry)
    File.chmod!(registry, 0o700)
    File.write!(Path.join(registry, "unrelated.bin"), "keep")
    assert {:error, :destination_owned} = FS.acquire(root, "archive")
    assert File.read!(Path.join(registry, "unrelated.bin")) == "keep"
    assert File.ls!(registry) == ["unrelated.bin"]
  end

  test "replaced journal files are never appended to or removed", %{root: root} do
    {:ok, filesystem, receipt} = FS.acquire(root, "archive")
    journal = Path.join(receipt.claim, "journal")
    File.rename!(journal, journal <> ".original")
    File.write!(journal, "unrelated")
    assert {:error, :ownership_changed} = FS.write(filesystem, :archive, "one.bin", "one")
    assert File.read!(journal) == "unrelated"
    assert {:error, :ownership_changed} = FS.abort(filesystem)
    assert File.read!(journal) == "unrelated"
  end

  test "preparation validates the bounded journal before issuing a promotion handle", %{
    root: root
  } do
    {:ok, filesystem, receipt} = FS.acquire(root, "archive")
    journal = Path.join(receipt.claim, "journal")
    original = File.read!(journal)
    File.write!(journal, original <> <<1, 2, 3>>)
    assert {:error, :invalid_journal} = FS.prepare(filesystem)
    refute File.exists?(Path.join(root, "archive"))
    File.write!(journal, original)
    assert {:ok, :aborted} = FS.abort(filesystem)
  end

  test "owner death during blocked preparation IO cannot cause independent publication", %{
    root: root
  } do
    child = child(root, :blocked_prepare_io)

    assert {:blocked_prepare, {:error, :owner_down}, :owner_responsive, true} =
             child_result(child)

    refute File.exists?(Path.join(root, "archive"))
    kill(child)
  end

  test "owner-local rename avoids both a suspended filesystem actor and OTP file server", %{
    root: root
  } do
    child = child(root, :blocked_servers)
    assert {:ok, receipt} = child_result(child)
    assert File.read!(Path.join(root, "archive/one.bin")) == "one"
    kill(child)
    assert {:ok, :promoted} = FS.recover(receipt)
  end

  defp acquisition_trace(events) do
    receive do
      {:events, caller, reference} ->
        send(caller, {reference, Enum.reverse(events)})
        acquisition_trace(events)

      :stop ->
        :ok

      event ->
        acquisition_trace([event | events])
    end
  end

  defp await_dormant_acquisition(filesystem, owner, attempts) when attempts > 0 do
    case Process.info(filesystem, [:status, :message_queue_len, :monitors]) do
      [status: :waiting, message_queue_len: 0, monitors: [{:process, ^owner}]] ->
        :ok

      _ ->
        Process.sleep(1)
        await_dormant_acquisition(filesystem, owner, attempts - 1)
    end
  end

  defp await_dormant_acquisition(_, _, 0), do: flunk("acquisition did not wait for activation")

  defp await_prepare_request(filesystem, attempts) when attempts > 0 do
    {:messages, messages} = Process.info(filesystem, :messages)

    if Enum.any?(messages, &match?({:"$gen_call", _, :prepare}, &1)) do
      :ok
    else
      Process.sleep(1)
      await_prepare_request(filesystem, attempts - 1)
    end
  end

  defp await_prepare_request(_, 0), do: flunk("prepare request was not queued")

  defp child(root, window) do
    code = ~S"""
    alias Crawler.Export.Filesystem, as: FS
    [root, window] = System.argv()

    if window in ["blocked_acquisition", "owner_down_acquisition"] do
      scripts = Path.join(root, "scripts")
      :ok = File.mkdir(scripts)
      marker = Path.join(root, "id-blocked")
      release = Path.join(root, "id-release")
      helper_pid_path = Path.join(root, "id-pid")
      claim = Path.join([root, ".crawler-fs-claims", "archive"])
      script = Path.join(scripts, "id")
      contents = Enum.join([
        "#!/bin/sh",
        "if [ -d \"$CRAWLER_TEST_CLAIM\" ]; then",
        "  /bin/echo $$ > \"$CRAWLER_TEST_ID_PID\"",
        "  /usr/bin/touch \"$CRAWLER_TEST_ID_MARKER\"",
        "  attempt=0",
        "  while [ ! -f \"$CRAWLER_TEST_ID_RELEASE\" ] && [ $attempt -lt 500 ]; do /bin/sleep 0.01; attempt=$((attempt+1)); done",
        "fi",
        "exec /usr/bin/id \"$@\"",
        ""
      ], "\n")
      :ok = File.write(script, contents)
      :ok = File.chmod(script, 0o700)
      System.put_env("CRAWLER_TEST_CLAIM", claim)
      System.put_env("CRAWLER_TEST_ID_MARKER", marker)
      System.put_env("CRAWLER_TEST_ID_RELEASE", release)
      System.put_env("CRAWLER_TEST_ID_PID", helper_pid_path)
      System.put_env("PATH", scripts <> ":" <> System.fetch_env!("PATH"))
      {owner, nonce, filesystem, monitor} = if window == "owner_down_acquisition" do
        parent = self()
        owner = spawn(fn ->
          true = Process.register(self(), :crawler_filesystem_acquisition_owner)
          nonce = make_ref()
          {:ok, filesystem, _} = FS.spawn_acquisition(root, "archive", nonce)
          send(parent, {:acquisition_started, self(), nonce, filesystem})
          receive do :never -> :ok end
        end)
        receive do
          {:acquisition_started, ^owner, nonce, filesystem} ->
            {owner, nonce, filesystem, Process.monitor(filesystem)}
          after 3000 -> raise "registered owner did not start acquisition"
        end
      else
        nonce = make_ref()
        {:ok, filesystem, monitor} = FS.spawn_acquisition(root, "archive", nonce)
        {self(), nonce, filesystem, monitor}
      end
      send(filesystem, {:crawler_filesystem_activate, nonce, owner})
      wait = fn wait, count ->
        cond do
          File.exists?(marker) -> :ok
          count == 0 -> raise "acquisition never reached the partial claim"
          true -> Process.sleep(1); wait.(wait, count - 1)
        end
      end
      :ok = wait.(wait, 3000)
      if window == "owner_down_acquisition" do
        owner_monitor = Process.monitor(owner)
        Process.exit(owner, :kill)
        receive do
          {:DOWN, ^owner_monitor, :process, ^owner, :killed} -> :ok
          after 3000 -> raise "registered owner did not stop"
        end
        :ok = File.write(release, "release")
      else
        Process.exit(filesystem, :kill)
      end
      reason = receive do
        {:DOWN, ^monitor, :process, ^filesystem, reason} -> reason
        after 3000 -> raise "acquisition actor did not stop"
      end
      :ok = File.write(release, "release")
      helper_pid = helper_pid_path |> File.read!() |> String.trim()
      wait_helper = fn wait_helper, count ->
        {_output, status} = System.cmd("kill", ["-0", helper_pid], stderr_to_stdout: true)
        cond do
          status != 0 -> :ok
          count == 0 -> raise "test id helper did not stop"
          true -> Process.sleep(1); wait_helper.(wait_helper, count - 1)
        end
      end
      :ok = wait_helper.(wait_helper, 1000)
      acquired = receive do
        {:crawler_filesystem_acquired, ^nonce, ^filesystem, _} -> true
        after 0 -> false
      end
      result = if window == "owner_down_acquisition" do
        {:owner_down_acquisition, reason, File.exists?(claim)}
      else
        {:blocked_acquisition, reason, FS.acquire(root, "archive"), acquired, File.ls!(claim)}
      end
      IO.puts("RESULT:" <> Base.encode64(:erlang.term_to_binary(result)))
      receive do :never -> :ok end
    end
    selected_owner = if window == "blocked_prepare_io" do
      spawn(fn ->
        receive do {:ping, caller} -> send(caller, :owner_responsive) end
        receive do :never -> :ok end
      end)
    else
      self()
    end
    acquired = if String.starts_with?(window, "standalone_") do
      FS.acquire_file(root, "file.bin")
    else
      FS.acquire(root, "archive", owner: selected_owner)
    end
    result = case acquired do
      {:ok, owner, receipt} ->
        path = if String.starts_with?(window, "standalone_"), do: "file.bin", else: "one.bin"
        :ok = FS.write(owner, :archive, path, "one")
        if window == "blocked_prepare_io" do
          scripts = Path.join(root, "scripts")
          :ok = File.mkdir(scripts)
          marker = Path.join(root, "id-blocked")
          release = Path.join(root, "id-release")
          script = Path.join(scripts, "id")
          contents = "#!/bin/sh\n/usr/bin/touch \"$CRAWLER_TEST_ID_MARKER\"\nattempt=0\nwhile [ ! -f \"$CRAWLER_TEST_ID_RELEASE\" ] && [ $attempt -lt 500 ]; do /bin/sleep 0.01; attempt=$((attempt+1)); done\nexec /usr/bin/id \"$@\"\n"
          :ok = File.write(script, contents)
          :ok = File.chmod(script, 0o700)
          System.put_env("CRAWLER_TEST_ID_MARKER", marker)
          System.put_env("CRAWLER_TEST_ID_RELEASE", release)
          System.put_env("PATH", scripts <> ":" <> System.fetch_env!("PATH"))
          fs_ref = Process.monitor(owner)
          selected_ref = Process.monitor(selected_owner)
          task = Task.async(fn -> FS.prepare(owner) end)
          wait = fn wait, count ->
            cond do
              File.exists?(marker) -> :ok
              count == 0 -> raise "id command never blocked"
              true -> Process.sleep(1); wait.(wait, count - 1)
            end
          end
          :ok = wait.(wait, 3000)
          send(selected_owner, {:ping, self()})
          pong = receive do :owner_responsive -> :owner_responsive after 1000 -> raise "owner blocked" end
          Process.exit(selected_owner, :kill)
          receive do {:DOWN, ^selected_ref, _, _, :killed} -> :ok after 1000 -> raise "owner not dead" end
          :ok = File.write(release, "release")
          result = Task.await(task, 5000)
          receive do {:DOWN, ^fs_ref, _, _, :normal} -> :ok after 5000 -> raise "filesystem did not stop" end
          {:blocked_prepare, result, pong, not File.exists?(receipt.stage)}
        else
          if window != "staged" do
            {:ok, prepared} = FS.prepare(owner)
            if window == "blocked_servers" do
              :ok = :sys.suspend(owner)
              :ok = :sys.suspend(:file_server_2)
              true = FS.prepared_for?(prepared, receipt)
              false = FS.prepared_for?(prepared, %{receipt | id: "wrong"})
              :ok = FS.promote(prepared)
              false = FS.prepared_for?(prepared, receipt)
              :ok = :sys.resume(:file_server_2)
              :ok = :sys.resume(owner)
            else
              if window in ["after_rename", "standalone_after_rename"], do: :ok = FS.promote(prepared)
            end
          end
          {:ok, receipt}
        end
      error -> error
    end
    IO.puts("RESULT:" <> Base.encode64(:erlang.term_to_binary(result)))
    receive do :never -> :ok end
    """

    port =
      Port.open(
        {:spawn_executable, System.find_executable("elixir")},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["-r", @source, "-e", code, "--", root, Atom.to_string(window)],
          env: [{~c"ERL_FLAGS", ~c"+S 4:4"}]
        ]
      )

    {:os_pid, pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      if window in [:blocked_prepare_io, :blocked_acquisition, :owner_down_acquisition],
        do: File.write(Path.join(root, "id-release"), "release")

      {command, status} =
        System.cmd("ps", ["-ww", "-p", Integer.to_string(pid), "-o", "command="],
          stderr_to_stdout: true
        )

      if status == 0 and String.contains?(command, root) and String.contains?(command, @source) do
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      end
    end)

    {port, pid}
  end

  defp child_result({port, _}, buffer \\ "") do
    case Regex.run(~r/RESULT:([^\r\n]+)\r?\n/, buffer) do
      [_, encoded] ->
        encoded |> Base.decode64!() |> :erlang.binary_to_term()

      nil ->
        receive do
          {^port, {:data, data}} -> child_result({port, nil}, buffer <> data)
          {^port, {:exit_status, status}} -> flunk("child exited #{status}: #{buffer}")
        after
          10_000 -> flunk("child produced no result: #{buffer}")
        end
    end
  end

  defp kill({port, pid}) do
    System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      5000 -> flunk("child did not exit")
    end
  end

  defp commit(filesystem) do
    with {:ok, prepared} <- FS.prepare(filesystem), do: FS.promote(prepared)
  end

  defp root_entries(root), do: File.ls!(root) -- [".crawler-fs-claims"]

  defp random, do: Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
end
