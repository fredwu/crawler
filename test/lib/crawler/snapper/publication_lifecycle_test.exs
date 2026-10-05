defmodule Crawler.Snapper.PublicationLifecycleTest do
  use ExUnit.Case, async: false

  import Crawler.TestHelpers, only: [tmp: 1, unique_scope: 1, wait: 1]
  import Crawler.SnapshotHelpers, only: [saved: 2]

  alias Crawler.Options
  alias Crawler.Snapper
  alias Crawler.Store

  @url "http://private-snapshot-user:private-snapshot-password@example.com/page.bin"

  for failure <- [:direct, :temp, :rename] do
    test "#{failure} filesystem failures do not expose credentialed archive paths" do
      root = root()
      scope = unique_scope("snapshot-privacy")
      on_exit(fn -> Store.drop_scope(scope) end)
      failure = unquote(failure)
      save_to = if failure == :rename, do: root, else: Path.join(root, "missing")
      file = saved(save_to, @url)
      if failure == :rename, do: File.mkdir_p!(file)

      opts =
        Options.assign_defaults(%{
          url: @url,
          scope: scope,
          save_to: save_to,
          store: nil,
          retries: 0,
          req_options: [
            adapter: fn request ->
              {request,
               Req.Response.new(
                 status: 200,
                 headers: [{"content-type", "application/octet-stream"}],
                 body: "BODY"
               )}
            end
          ]
        })

      opts =
        if failure == :direct,
          do: opts,
          else: Map.put(opts, :generation, Store.generation(scope))

      operation = if failure == :rename, do: :rename, else: :write
      reason = if failure == :rename, do: :eisdir, else: :enoent

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert {:error, {:snapshot, ^operation, ^reason}} = result = Crawler.crawl_now(opts)
          assert_private(inspect(result))
        end)

      assert log =~ "Snapshot #{operation} failed for http://example.com/page.bin: #{reason}"
      assert log =~ "Crawl failed"
      assert_private(log)
      refute log =~ file
      assert Path.basename(Path.dirname(file)) =~ "__user_"
      assert Path.wildcard(Path.join(root, "**/.crawler-*.tmp"), match_dot: true) == []
    end
  end

  for outcome <- [:success, :stale, :rename_error, :raise, :throw, :exit] do
    test "repeated #{outcome} publications release staging watchers before returning" do
      root = root()
      scope = unique_scope("publication-watchers")
      on_exit(fn -> Store.drop_scope(scope) end)
      file = saved(root, @url)
      outcome = unquote(outcome)
      if outcome == :rename_error, do: File.mkdir_p!(file)

      ExUnit.CaptureLog.capture_log(fn ->
        before_monitors = monitored_by()

        for _ <- 1..8 do
          before_publish = fn ->
            watcher = staging_watcher(before_monitors)
            send(self(), {:staging_watcher, watcher, Process.monitor(watcher)})

            case outcome do
              :stale -> Store.drop_scope(scope)
              :raise -> raise "callback failed"
              :throw -> throw(:callback_failed)
              :exit -> exit(:callback_failed)
              _ -> :ok
            end
          end

          opts = %{
            url: @url,
            content_type: "application/octet-stream",
            save_to: root,
            scope: scope,
            generation: Store.generation(scope),
            before_publish: before_publish
          }

          case outcome do
            :success ->
              assert {:ok, ^opts} = Snapper.snap("BODY", opts)

            :stale ->
              assert {:error, :stale} = Snapper.snap("BODY", opts)

            :rename_error ->
              assert {:error, {:snapshot, :rename, _}} = Snapper.snap("BODY", opts)

            :raise ->
              assert_raise RuntimeError, "callback failed", fn -> Snapper.snap("BODY", opts) end

            :throw ->
              assert catch_throw(Snapper.snap("BODY", opts)) == :callback_failed

            :exit ->
              assert catch_exit(Snapper.snap("BODY", opts)) == :callback_failed
          end

          assert_receive {:staging_watcher, watcher, ref}
          assert_receive {:DOWN, ^ref, :process, ^watcher, :normal}
          refute Process.alive?(watcher)
          assert monitored_by() == before_monitors
          assert Path.wildcard(Path.join(root, "**/.crawler-*.tmp"), match_dot: true) == []
        end
      end)

      if outcome == :success, do: assert(File.read!(file) == "BODY")
    end
  end

  test "repeated staging write errors release caller monitors" do
    root = root()
    scope = unique_scope("failed-staging-watchers")
    on_exit(fn -> Store.drop_scope(scope) end)

    ExUnit.CaptureLog.capture_log(fn ->
      before_monitors = monitored_by()

      for _ <- 1..8 do
        assert {:error, {:snapshot, :write, :enoent}} =
                 Snapper.snap("BODY", %{
                   url: @url,
                   content_type: "application/octet-stream",
                   save_to: Path.join(root, "missing"),
                   scope: scope,
                   generation: Store.generation(scope)
                 })

        assert monitored_by() == before_monitors
        assert File.ls!(root) == []
      end
    end)
  end

  test "killing a caller still removes its staging file and watcher" do
    root = root()
    scope = unique_scope("killed-publication")
    on_exit(fn -> Store.drop_scope(scope) end)
    observer = self()

    {caller, caller_ref} =
      spawn_monitor(fn ->
        before_monitors = monitored_by()

        Snapper.snap("BODY", %{
          url: @url,
          content_type: "application/octet-stream",
          save_to: root,
          scope: scope,
          generation: Store.generation(scope),
          before_publish: fn ->
            send(observer, {:staged, staging_watcher(before_monitors)})

            receive do
              :never -> :ok
            end
          end
        })
      end)

    assert_receive {:staged, watcher}, 1_000
    watcher_ref = Process.monitor(watcher)
    assert [_] = Path.wildcard(Path.join(root, "**/.crawler-*.tmp"), match_dot: true)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    assert_receive {:DOWN, ^watcher_ref, :process, ^watcher, :normal}
    assert Path.wildcard(Path.join(root, "**/.crawler-*.tmp"), match_dot: true) == []
    refute File.exists?(saved(root, @url))
  end

  defp root do
    path = tmp(unique_scope("publication-lifecycle"))
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp monitored_by, do: self() |> Process.info(:monitored_by) |> elem(1) |> MapSet.new()

  defp staging_watcher(before_monitors) do
    wait(fn -> assert MapSet.size(MapSet.difference(monitored_by(), before_monitors)) == 1 end)
    [watcher] = monitored_by() |> MapSet.difference(before_monitors) |> MapSet.to_list()
    watcher
  end

  defp assert_private(text) do
    refute text =~ "private-snapshot-user"
    refute text =~ "private-snapshot-password"
    refute String.downcase(text) =~ "__user_"
    refute String.downcase(text) =~ "%3a"
  end
end
