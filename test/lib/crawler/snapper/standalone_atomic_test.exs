defmodule Crawler.Snapper.StandaloneAtomicTest do
  use ExUnit.Case, async: true

  alias Crawler.Export.Filesystem
  alias Crawler.Parser
  alias Crawler.Snapper

  @id "standalone0000000000000001"
  @bom <<0xEF, 0xBB, 0xBF>>

  setup do
    root =
      Path.join([
        File.cwd!(),
        "test",
        "tmp",
        "standalone-snapper-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok,
     root: root,
     opts: %{
       public_id: @id,
       save_to: root,
       url: "https://private-user:private-password@example.test/fake.js",
       content_type: "text/html",
       html_tag: "a"
     }}
  end

  test "returns only the public identity and response-aware path after writing", %{
    root: root,
    opts: opts
  } do
    assert {:ok, %{public_id: @id, path: "resources/" <> filename} = artifact} =
             Snapper.snap("<p>source</p>", opts)

    assert map_size(artifact) == 2
    assert filename == @id <> ".html"
    assert File.read!(Path.join(root, artifact.path)) == @bom <> "<p>source</p>"
    refute inspect(artifact) =~ "private-"
    refute File.exists?(Path.join(root, "manifest.json"))
  end

  test "requires an explicit public ID without creating output", %{root: root, opts: opts} do
    assert {:error, {:snapshot, :path, :invalid_public_id}} =
             Snapper.snap("source", Map.delete(opts, :public_id))

    assert File.ls!(root) == []
  end

  test "path and root shape errors precede invalid text analysis", %{root: root, opts: opts} do
    assert {:error, {:snapshot, :path, :invalid_public_id}} =
             Snapper.snap(<<255>>, Map.delete(opts, :public_id))

    for invalid <- [nil, "", 12, <<0>>, <<255>>] do
      assert {:error, {:snapshot, :acquire, :invalid_root}} =
               Snapper.snap(<<255>>, %{opts | save_to: invalid})
    end

    assert File.ls!(root) == []
  end

  test "requires an existing isolated root and keeps failure logs private", %{
    root: root,
    opts: opts
  } do
    missing = Path.join(root, "missing")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:snapshot, :acquire, :enoent}} =
                 Snapper.snap("source", %{opts | save_to: missing})
      end)

    refute File.exists?(missing)
    refute log =~ "private-user"
    refute log =~ "private-password"
    assert log =~ "https://example.test/fake.js"
    File.chmod!(root, 0o777)

    assert {:error, {:snapshot, :acquire, :unsafe_root}} = Snapper.snap("source", opts)
  end

  test "real staging keeps the previous complete file until atomic replacement", %{
    root: root,
    opts: opts
  } do
    opts = %{opts | content_type: "application/octet-stream"}
    assert {:ok, artifact} = Snapper.snap("OLD", opts)
    target = Path.join(root, artifact.path)
    observer = self()
    body = :binary.copy(<<255, 0, 42>>, 100_000)

    task =
      Task.async(fn ->
        Snapper.snap(
          body,
          Map.put(opts, :before_publish, fn ->
            send(observer, {:staged, self()})

            receive do
              :publish -> :ignored_callback_return
            end
          end)
        )
      end)

    assert_receive {:staged, writer}, 2_000
    assert File.read!(target) == "OLD"

    [stage] =
      Enum.reject(
        Path.wildcard(Path.join(root, ".crawler-fs-*"), match_dot: true),
        &(Path.basename(&1) == ".crawler-fs-claims")
      )

    assert File.read!(Path.join([stage, "archive", artifact.path])) == body

    assert {:error, {:snapshot, :acquire, :destination_owned}} =
             Snapper.snap("COMPETING", %{opts | public_id: "standalone0000000000000002"})

    assert File.read!(target) == "OLD"
    send(writer, :publish)
    assert Task.await(task) == {:ok, artifact}
    assert File.read!(target) == body
    assert_clean(root)
  end

  for failure <- [:raise, :throw, :exit] do
    test "#{failure} callbacks propagate after real filesystem cleanup", %{root: root, opts: opts} do
      assert {:ok, artifact} = Snapper.snap("OLD", opts)
      observer = self()
      before = monitored_by()

      callback = fn ->
        [filesystem] = MapSet.to_list(MapSet.difference(monitored_by(), before))
        monitor = Process.monitor(filesystem)
        send(observer, {:filesystem, filesystem, monitor})

        case unquote(failure) do
          :raise -> raise "callback failed"
          :throw -> throw(:callback_failed)
          :exit -> exit(:callback_failed)
        end
      end

      opts = Map.put(opts, :before_publish, callback)

      case unquote(failure) do
        :raise ->
          assert_raise RuntimeError, "callback failed", fn -> Snapper.snap("NEW", opts) end

        :throw ->
          assert catch_throw(Snapper.snap("NEW", opts)) == :callback_failed

        :exit ->
          assert catch_exit(Snapper.snap("NEW", opts)) == :callback_failed
      end

      assert_receive {:filesystem, filesystem, monitor}
      assert_receive {:DOWN, ^monitor, :process, ^filesystem, :normal}, 5_000
      refute Process.alive?(filesystem)
      assert MapSet.subset?(monitored_by(), before)
      assert File.read!(Path.join(root, artifact.path)) == @bom <> "OLD"
      assert_clean(root)
    end
  end

  test "killing a caller lets the real filesystem owner clean its stage", %{
    root: root,
    opts: opts
  } do
    observer = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        before = monitored_by()

        Snapper.snap(
          "NEW",
          Map.put(opts, :before_publish, fn ->
            [filesystem] = MapSet.to_list(MapSet.difference(monitored_by(), before))
            send(observer, {:staged, filesystem})

            receive do
              :never -> :ok
            end
          end)
        )
      end)

    assert_receive {:staged, filesystem}, 2_000
    filesystem_monitor = Process.monitor(filesystem)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    assert_receive {:DOWN, ^filesystem_monitor, :process, ^filesystem, :normal}, 5_000
    refute File.exists?(Path.join(root, "resources"))
    assert_clean(root)
  end

  test "live and completed managed destinations refuse standalone writes", %{
    root: root,
    opts: opts
  } do
    assert {:ok, filesystem, _receipt} = Filesystem.acquire(root, "resources")
    assert {:error, {:snapshot, :acquire, :destination_owned}} = Snapper.snap("NEW", opts)
    assert {:ok, :aborted} = Filesystem.abort(filesystem)

    assert {:ok, filesystem, _receipt} = Filesystem.acquire(root, "archive")
    assert :ok = Filesystem.write(filesystem, :archive, "existing.bin", "COMPLETE")
    assert {:ok, prepared} = Filesystem.prepare(filesystem)
    assert :ok = Filesystem.promote(prepared)
    assert {:ok, :promoted} = Filesystem.abort(filesystem)

    assert {:error, {:snapshot, :acquire, :destination_owned}} =
             Snapper.snap("NEW", %{opts | save_to: Path.join(root, "archive")})

    assert File.read!(Path.join([root, "archive", "existing.bin"])) == "COMPLETE"
    refute File.exists?(Path.join([root, "archive", "resources"]))
  end

  test "symlink parents and targets cannot redirect a standalone write", %{root: root, opts: opts} do
    outside = Path.join(root, "outside")
    File.mkdir!(outside)
    File.ln_s!(outside, Path.join(root, "resources"))
    assert {:error, {:snapshot, :prepare, :unsafe_path}} = Snapper.snap("NEW", opts)
    assert File.ls!(outside) == []
    File.rm!(Path.join(root, "resources"))
    File.mkdir!(Path.join(root, "resources"))
    target = Path.join([root, "resources", @id <> ".html"])
    File.write!(Path.join(outside, "old.html"), "OLD")
    File.ln_s!(Path.join(outside, "old.html"), target)
    assert {:error, {:snapshot, :prepare, :unsafe_path}} = Snapper.snap("NEW", opts)
    assert File.read!(Path.join(outside, "old.html")) == "OLD"
    assert_clean(root)
  end

  test "opaque binary input uses the actual filesystem file cap", %{root: root, opts: opts} do
    body = :binary.copy(<<255>>, 32 * 1024 * 1024 + 1)
    opts = %{opts | content_type: "application/octet-stream", html_tag: "img"}
    assert {:error, {:snapshot, :write, :file_limit}} = Snapper.snap(body, opts)
    refute File.exists?(Path.join(root, "resources"))
    assert_clean(root)
  end

  for marker <- [:generation, :execution_lease, :scheduler_claim] do
    test "refuses supplied #{marker} before analysis and filesystem access", %{
      root: root,
      opts: opts
    } do
      opts = Map.put(opts, unquote(marker), make_ref())

      assert {:error, {:snapshot, :managed_export_required}} = Snapper.snap(<<255>>, opts)
      assert File.ls!(root) == []
    end

    test "refuses Prepared #{marker} even when supplied options omit it", %{
      root: root,
      opts: opts
    } do
      assert {:ok, prepared} = Parser.prepare_for_parse("source", opts)
      prepared = %{prepared | opts: Map.put(prepared.opts, unquote(marker), make_ref())}

      assert {:error, {:snapshot, :managed_export_required}} = Snapper.snap(prepared, opts)
      assert File.ls!(root) == []
    end
  end

  test "refuses the actual process execution marker", %{root: root, opts: opts} do
    Process.put(:crawler_execution_lease, make_ref())

    try do
      assert {:error, {:snapshot, :managed_export_required}} = Snapper.snap(<<255>>, opts)
      assert File.ls!(root) == []
    after
      Process.delete(:crawler_execution_lease)
    end
  end

  defp monitored_by, do: self() |> Process.info(:monitored_by) |> elem(1) |> MapSet.new()

  defp assert_clean(root) do
    assert File.ls!(Path.join(root, ".crawler-fs-claims")) == [".crawler-fs-owner"]

    assert Path.wildcard(Path.join(root, ".crawler-fs-*"), match_dot: true) ==
             [Path.join(root, ".crawler-fs-claims")]
  end
end
