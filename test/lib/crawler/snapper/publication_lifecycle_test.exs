defmodule Crawler.Snapper.PublicationLifecycleTest do
  use ExUnit.Case, async: false

  import Crawler.TestHelpers, only: [tmp: 1, unique_scope: 1, wait: 1]
  import Crawler.ManagedSnapshotHelpers

  alias Crawler.Store

  @url "http://private-snapshot-user:private-snapshot-password@example.com/page.bin"

  for failure <- [:direct, :temp, :rename] do
    test "#{failure} filesystem failures do not expose credentialed archive paths" do
      parent = root()
      failure = unquote(failure)
      destination = Path.join(parent, "archive")
      opts = options(destination)

      previous =
        if failure == :rename do
          assert {:ok, prior} = stage_copy(options(destination))
          assert {:ok, :committed} = finalize_copy(prior)
          export = ready_export(prior)
          resource = resource_for_url(export, @url)

          {prior, artifact_path(export, resource),
           File.read!(Path.join(destination, "manifest.json"))}
        end

      opts =
        if failure == :rename,
          do: opts,
          else: %{opts | save_to: Path.join([parent, "missing", "archive"])}

      opts =
        if failure == :temp,
          do: Map.put(opts, :generation, Store.generation(opts.scope)),
          else: opts

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert {:error, _} = result = Crawler.crawl_now(Crawler.Options.assign_defaults(opts))
          assert_private(inspect(result))
        end)

      assert_private(log)
      refute log =~ destination

      if failure == :rename do
        {prior, file, manifest} = previous
        assert File.read!(file) == "BODY"
        assert File.read!(Path.join(destination, "manifest.json")) == manifest
        Crawler.stop(prior)
      else
        refute File.exists?(Path.join(opts.save_to, "manifest.json"))
      end

      assert_no_stages(parent)
    end
  end

  for outcome <- [:success, :stale, :rename_error, :raise, :throw, :exit] do
    test "repeated #{outcome} publications release managed staging actors before returning" do
      parent_root = root()
      outcome = unquote(outcome)
      observer = self()

      ExUnit.CaptureLog.capture_log(fn ->
        before_monitors = monitored_by()

        for index <- 1..8 do
          destination = Path.join(parent_root, "archive-#{index}")
          assert {:ok, opts} = stage_copy(options(destination))

          before_commit = fn frame ->
            send(
              observer,
              {:staging_actors, frame.filesystem.filesystem, frame.runtime.companion}
            )

            case outcome do
              :stale ->
                Store.drop_scope(opts.scope)

              :rename_error ->
                File.mkdir!(destination)
                File.write!(Path.join(destination, "previous.bin"), "PREVIOUS COMPLETE")

              :raise ->
                raise "callback failed"

              :throw ->
                throw(:callback_failed)

              :exit ->
                exit(:callback_failed)

              _ ->
                :ok
            end
          end

          case outcome do
            :success ->
              assert {:ok, :committed} = finalize_copy(opts, before_commit)

            :stale ->
              assert {:error, :stale} = finalize_copy(opts, before_commit)

            :rename_error ->
              assert {:error, :destination_exists} = finalize_copy(opts, before_commit)

            :raise ->
              assert_raise RuntimeError, "callback failed", fn ->
                finalize_copy(opts, before_commit)
              end

            :throw ->
              assert catch_throw(finalize_copy(opts, before_commit)) == :callback_failed

            :exit ->
              assert catch_exit(finalize_copy(opts, before_commit)) == :callback_failed
          end

          assert_receive {:staging_actors, filesystem, companion}

          wait(fn ->
            refute Process.alive?(filesystem)
            refute Process.alive?(companion)
          end)

          wait(fn ->
            assert monitored_by() == publication_monitors(outcome, opts, before_monitors)
          end)

          if outcome == :success do
            export = ready_export(opts)
            assert read_resource(export, resource_for_url(export, @url)) == "BODY"
            assert_private(File.read!(Path.join(destination, "manifest.json")))
          else
            refute File.exists?(Path.join(destination, "manifest.json"))

            if outcome == :rename_error,
              do:
                assert(File.read!(Path.join(destination, "previous.bin")) == "PREVIOUS COMPLETE")
          end

          Crawler.stop(opts)
          assert_no_stages(parent_root)
        end
      end)
    end
  end

  test "repeated staging write errors release caller monitors" do
    parent = root()
    before_monitors = monitored_by()

    for index <- 1..8 do
      opts = options(Path.join(parent, "archive-#{index}"))

      assert {:error, :injected_write_ack} =
               stage_copy(opts, fn context ->
                 written = context.written

                 %{
                   context
                   | written: fn operation, ack ->
                       assert File.read!(
                                Path.join([
                                  context.recovery_receipt.stage,
                                  "source",
                                  ack.plan.path
                                ])
                              ) == "BODY"

                       assert :ok = written.(operation, ack)
                       {:error, :injected_write_ack}
                     end
                 }
               end)

      Store.drop_scope(opts.scope)
      wait(fn -> assert_no_stages(parent) end)
      assert monitored_by() == before_monitors
      refute File.exists?(opts.save_to)
    end
  end

  test "killing a caller still removes its staging file and watcher" do
    parent = root()
    assert {:ok, opts} = stage_copy(options(Path.join(parent, "archive")))
    observer = self()

    {caller, caller_ref} =
      spawn_monitor(fn ->
        finalize_copy(opts, fn frame ->
          send(
            observer,
            {:staged, self(), frame.filesystem.filesystem, frame.runtime.companion,
             frame.filesystem.receipt.stage}
          )

          receive do
            :never -> :ok
          end
        end)
      end)

    assert_receive {:staged, executor, filesystem, companion, stage}, 2_000
    assert File.dir?(stage)
    filesystem_ref = Process.monitor(filesystem)
    companion_ref = Process.monitor(companion)
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, _}, 2_000
    assert_receive {:DOWN, ^filesystem_ref, :process, ^filesystem, _}, 2_000
    assert_receive {:DOWN, ^companion_ref, :process, ^companion, _}, 2_000
    refute File.exists?(opts.save_to)
    assert_no_stages(parent)
    Store.drop_scope(opts.scope)
  end

  defp options(destination) do
    scope = unique_scope("publication")
    on_exit(fn -> Store.drop_scope(scope) end)

    %{
      url: @url,
      scope: scope,
      save_to: destination,
      store: nil,
      workers: 1,
      max_body: 1_048_576,
      max_analysis_bytes: 16_777_216,
      max_manifest_bytes: 16_777_216,
      retries: 0,
      respect_robots: false,
      req_options: [
        adapter: fn request ->
          {request,
           Req.Response.new(
             status: 200,
             headers: [{"content-type", "application/octet-stream"}],
             body: "BODY"
           )}
        end,
        retry: false
      ]
    }
  end

  defp assert_no_stages(root) do
    entries = Path.wildcard(Path.join(root, ".crawler-fs-*"), match_dot: true)
    assert Enum.reject(entries, &(Path.basename(&1) == ".crawler-fs-claims")) == []
  end

  defp root do
    path = tmp(unique_scope("publication-lifecycle"))
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp publication_monitors(outcome, opts, before_monitors)
       when outcome in [:raise, :throw, :exit] do
    state = :sys.get_state(Store)
    caller = self()
    store = Process.whereis(Store)
    run = {opts.scope, opts.generation}

    assert [{_token, %{state: :accepted, refs: [backing]} = returned}] =
             Enum.filter(state.execution_returns, fn {_token, record} ->
               record.caller == caller and
                 Enum.any?(record.refs, fn ref ->
                   match?(%{run: ^run}, state.resources.receipts[ref])
                 end)
             end)

    backing_receipt = state.resources.receipts[backing]

    for {ref, kind, holder} <- [
          {backing, :response, caller},
          {returned.copy, :return_copy, store},
          {returned.metadata, :source, store}
        ] do
      receipt = state.resources.receipts[ref]
      assert receipt.kind == kind
      assert receipt.run == run
      assert receipt.lease == backing_receipt.lease
      assert receipt.arena == backing_receipt.arena
      assert is_integer(receipt.actual) and receipt.actual > 0
      assert receipt.capacity >= receipt.actual
      assert receipt.metadata > 0
      grant = receipt.holders[holder]
      assert grant.status in [:adopted, :retained]
      assert grant.metadata > 0
      assert grant.lease == receipt.lease
      assert grant.arena == receipt.arena

      refute Crawler.Store.Authority.resource_current?(ref, receipt.lease, holder)
    end

    assert state.resources.receipts[returned.copy].actual >= 1024
    assert state.resources.receipts[returned.metadata].actual == 4096
    MapSet.put(before_monitors, store)
  end

  defp publication_monitors(_outcome, _opts, before_monitors), do: before_monitors

  defp monitored_by, do: self() |> Process.info(:monitored_by) |> elem(1) |> MapSet.new()

  defp assert_private(text) do
    refute text =~ "private-snapshot-user"
    refute text =~ "private-snapshot-password"
    refute String.downcase(text) =~ "__user_"
    refute String.downcase(text) =~ "%3a"
  end
end
