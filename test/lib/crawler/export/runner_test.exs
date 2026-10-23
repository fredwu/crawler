defmodule Crawler.Export.RunnerTest do
  use ExUnit.Case, async: false

  import Crawler.TestHelpers, only: [wait: 1]

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Export.Runner
  alias Crawler.Export.Runtime
  alias Crawler.Export.Runtime.Context
  alias Crawler.Export.StagedIO
  alias Crawler.Fetcher
  alias Crawler.IsolatedOwnerHelpers
  alias Crawler.Options
  alias Crawler.Store
  alias Crawler.Store.Authority
  alias Crawler.Store.Execution
  alias Crawler.Store.Retained

  @moduletag :tmp_dir
  @html ~s|<meta charset="utf-8"><a href="https://user:secret@example.test/missing#frag">missing</a>|

  setup %{tmp_dir: tmp_dir} do
    root = Path.expand(tmp_dir)
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    scope = make_ref()

    opts = options(root, scope)

    on_exit(fn ->
      Store.dispose_scope(scope)

      wait(fn ->
        refute Enum.any?(:sys.get_state(Store).exports, fn {{owner, _}, _} -> owner === scope end)
      end)
    end)

    %{root: root, opts: opts}
  end

  test "a successful copy publishes exact bytes with response-aware path and public manifest",
       c do
    body = <<0, 255, 13, 10, 239, 187, 191>>
    opts = stage(c.opts, "/misleading.html", "image/png", body, :copy)
    closed = close(opts)
    assert Runner.finalize(opts, closed) == {:ok, :committed}

    wait(fn ->
      assert {:ok, %{state: :ready, ready?: true, running?: false}} = Store.export_status(opts)
    end)

    manifest = manifest(c)
    [artifact] = manifest["resources"]
    assert Path.extname(artifact["path"]) == ".png"
    assert File.read!(Path.join([c.root, "archive", artifact["path"]])) == body
    assert Store.target_outcome(closed.target_handle).status == :succeeded
    assert Enum.sort(File.ls!(c.root)) == [".crawler-fs-claims", "archive"]
    assert_no_run_grants(opts)
  end

  test "a real parsed rewrite preserves bytes and BOM and keeps an absent target safely online",
       c do
    opts = stage(c.opts, "/document", "text/html", @html, :rewrite)
    assert Runner.finalize(opts, close(opts)) == {:ok, :committed}
    [artifact] = manifest(c)["resources"]
    assert artifact["content_type"] == "text/html"
    assert Path.extname(artifact["path"]) == ".html"
    expected = <<239, 187, 191>> <> String.replace(@html, "user:secret@", "")
    assert File.read!(Path.join([c.root, "archive", artifact["path"]])) == expected
    refute File.read!(Path.join([c.root, "archive", "manifest.json"])) =~ "secret"
    assert_no_run_grants(opts)
  end

  test "a manifest ceiling larger than the arena does not reserve the full ceiling", c do
    opts =
      c.opts
      |> Map.merge(%{
        max_body: 65_536,
        max_analysis_bytes: 4_194_304,
        max_manifest_bytes: 16_777_216
      })
      |> stage("/copy", "image/png", "png", :copy)

    closed = close(opts)
    assert Runner.finalize(opts, closed) == {:ok, :committed}

    wait(fn ->
      assert {:ok, %{state: :ready}} = Store.export_status(opts)
    end)

    [artifact] = manifest(c)["resources"]
    assert File.read!(Path.join([c.root, "archive", artifact["path"]])) == "png"
    assert_no_run_grants(opts)
  end

  test "failed targets are skipped and the archive has no invented artifact", c do
    opts = failed(c.opts)
    assert Runner.finalize(opts, close(opts)) == {:ok, :committed}
    assert manifest(c)["resources"] == []
    assert_no_run_grants(opts)
  end

  test "a retired parked finalizer cannot run or publish", c do
    opts = stage(c.opts, "/copy", "image/png", "png", :copy)
    closed = close(opts)
    Store.dispose_scope(opts.scope)
    assert {:error, _} = Runner.finalize(opts, closed)
    refute File.exists?(Path.join(c.root, "archive"))
    assert_no_run_grants(opts)
  end

  test "the original manifest cap refuses finalization without publishing ready", c do
    opts =
      stage(%{c.opts | max_manifest_bytes: 131_072}, "/document", "text/html", @html, :rewrite)

    closed = close(opts)
    assert {:error, {:limit, limit}} = Runner.finalize(opts, closed)
    assert limit in [:max_manifest_bytes, :max_retained_bytes]
    refute File.exists?(Path.join(c.root, "archive"))
    assert {:ok, %{ready?: false}} = Store.export_status(opts)
    assert_no_run_grants(opts)
  end

  test "an archive output cap fails finalization without publishing ready", c do
    opts = stage(%{c.opts | max_file_bytes: 16}, "/copy", "image/png", "png", :copy)
    assert Runner.finalize(opts, close(opts)) == {:error, {:limit, :max_file_bytes}}
    refute File.exists?(Path.join(c.root, "archive"))
    assert {:ok, %{ready?: false}} = Store.export_status(opts)
    assert_no_run_grants(opts)
  end

  test "a live finalizer keeps its seal structural receipt across retirement and filesystem DOWN",
       c do
    child =
      IsolatedOwnerHelpers.start(c.root, __MODULE__, :seal_receipt_retirement_case, __ENV__.file)

    try do
      assert :ok = IsolatedOwnerHelpers.await(child, Crawler.Deadline.after_ms(10_000))
    after
      IsolatedOwnerHelpers.cleanup(child)
    end
  end

  @doc false
  def seal_receipt_retirement_case(c) do
    c = Map.put(c, :opts, options(c.root, c.scope))
    opts = stage(c.opts, "/" <> String.duplicate("long", 256), "image/png", "png", :copy)
    closed = close(opts)
    parent = self()

    {executor, monitor} =
      spawn_monitor(fn ->
        deadline = Crawler.Deadline.after_ms(10_000)

        assert {:ok, _claim, :finalize, admitted} =
                 Store.await_finalizer(closed.target_handle, deadline)

        assert {:ok, lease} = Store.begin_execution(admitted, deadline)
        Process.put(:crawler_execution_lease, lease)
        owned = Map.merge(admitted, %{execution_lease: lease, crawler_deadline: deadline})
        assert {:ok, filesystem} = Store.export_filesystem(owned, closed.epoch)

        assert {:ok, {:batch, [row], cursor}, batch_receipt} =
                 Store.export_prepare_next(owned, closed.epoch, closed.close_token, nil)

        assert :ok =
                 Store.export_prepared(
                   owned,
                   closed.epoch,
                   closed.close_token,
                   row.target,
                   row.descriptor.source_operation,
                   []
                 )

        Store.release_resource(batch_receipt)
        assert :done = Store.export_prepare_next(owned, closed.epoch, closed.close_token, cursor)
        hold_seal(owned, closed, filesystem.filesystem, parent)
        Store.end_execution(lease)
        Process.delete(:crawler_execution_lease)
      end)

    assert_receive {:seal_held, ^executor, filesystem, receipt, structural, complete}, 5000
    assert complete > structural
    run = {opts.scope, opts.generation}
    before = :sys.get_state(Store).exports[run]
    fs_monitor = Process.monitor(filesystem)
    assert {:ok, _} = Crawler.Export.Filesystem.abort(filesystem)
    assert_receive {:DOWN, ^fs_monitor, :process, ^filesystem, _}, 5000
    assert Process.alive?(executor)

    assert [{{:grant, ^receipt, ^executor}, _, _, _}] =
             :ets.lookup(Crawler.Store.Resources, {:grant, receipt, executor})

    send(executor, :verify_held_snapshot)
    assert_receive {:held_snapshot_verified, ^executor}, 5000
    assert Process.alive?(executor)
    Store.dispose_scope(opts.scope)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}, 5000
    assert_no_run_grants(opts)

    wait(fn ->
      state = :sys.get_state(Store)
      recovery = state.exports[run]
      assert recovery.retired?
      assert recovery.phase == :cleanup_failed
      assert recovery.filesystem == nil
      refute Enum.any?(state.executions, fn {_lease, row} -> row.opts.scope == opts.scope end)
      refute Enum.any?(state.export_io, fn {_lease, row} -> row.run == run end)
    end)

    state = :sys.get_state(Store)
    recovery = state.exports[run]
    assert recovery.cleanup_failure == {:snapshot, :cleanup_failed}
    assert recovery.receipt == before.receipt
    assert recovery.reserved_bytes == before.reserved_bytes
    assert state.export_bytes == before.reserved_bytes
    refute Enum.any?(state.export_actors, fn {_pid, owner} -> owner == run end)
    refute Enum.any?(state.export_monitors, fn {_ref, {owner, _pid}} -> owner == run end)
    refute File.exists?(recovery.receipt.stage)
    refute File.exists?(recovery.receipt.claim)
    refute File.exists?(Path.join(c.root, "archive"))

    assert {:ok, %{state: :failed, reason: {:snapshot, :cleanup_failed}, ready?: false}} =
             Store.export_status(opts)

    :ok
  end

  for order <- [["a", "b"], ["b", "a"]] do
    test "cyclic pages and a bound failed target finalize in order #{Enum.join(order, " then ")}",
         c do
      with_cycle(c, unquote(order), 1_048_576, fn opts, base, failed ->
        closed = close(opts)
        assert Runner.finalize(opts, closed) == {:ok, :committed}

        wait(fn ->
          assert {:ok, %{state: :ready, ready?: true, running?: false}} =
                   Store.export_status(opts)
        end)

        public = manifest(c)
        assert public["format"] == 1
        assert length(public["resources"]) == 2
        assert length(public["references"]) == 4

        for {name, child} <- [{"a", "b"}, {"b", "a"}] do
          artifact = Enum.find(public["resources"], &(&1["url"] == base <> "/" <> name))
          other = Enum.find(public["resources"], &(&1["url"] == base <> "/" <> child))
          assert artifact["content_type"] == "text/html"
          assert Path.extname(artifact["path"]) == ".html"

          expected =
            <<239, 187, 191>> <>
              ~s|<meta charset="utf-8"><a href="./#{Path.basename(other["path"])}#part">other</a><a href="#{base}/failed#lost">failed</a>|

          assert File.read!(Path.join([c.root, "archive", artifact["path"]])) == expected
          references = Enum.filter(public["references"], &(&1["from"] == artifact["id"]))

          assert Enum.any?(
                   references,
                   &(&1["target"] == other["id"] and &1["outcome"] == "succeeded")
                 )

          assert Enum.any?(
                   references,
                   &(&1["target"] == nil and &1["outcome"] == "failed" and
                       &1["url"] == base <> "/failed")
                 )
        end

        assert Store.target_outcome(failed).status == :failed
        assert Store.target_outcome(closed.target_handle).status == :succeeded
        assert_no_run_grants(opts)
      end)
    end
  end

  test "a small body cap permits cyclic rendering with one command workspace", c do
    with_cycle(c, ["a", "b"], 4096, fn opts, base, failed ->
      assert opts.max_body == 4096
      assert opts.max_analysis_bytes == c.opts.max_analysis_bytes
      assert opts.max_manifest_bytes == c.opts.max_manifest_bytes
      closed = close(opts)
      assert Runner.finalize(opts, closed) == {:ok, :committed}

      wait(fn ->
        assert {:ok, %{state: :ready, ready?: true, running?: false}} = Store.export_status(opts)
      end)

      assert Store.target_outcome(closed.target_handle).status == :succeeded
      assert Store.target_outcome(failed).status == :failed
      public = manifest(c)
      assert length(public["resources"]) == 2
      assert length(public["references"]) == 4

      for {name, child} <- [{"a", "b"}, {"b", "a"}] do
        artifact = Enum.find(public["resources"], &(&1["url"] == base <> "/" <> name))
        other = Enum.find(public["resources"], &(&1["url"] == base <> "/" <> child))

        expected =
          <<239, 187, 191>> <>
            ~s|<meta charset="utf-8"><a href="./#{Path.basename(other["path"])}#part">other</a><a href="#{base}/failed#lost">failed</a>|

        assert File.read!(Path.join([c.root, "archive", artifact["path"]])) == expected
      end

      assert_no_run_grants(opts)
    end)
  end

  defp options(root, scope) do
    %{
      scope: scope,
      save_to: Path.join(root, "archive"),
      respect_robots: false,
      max_body: 4096,
      max_analysis_bytes: 16_000_000,
      max_manifest_bytes: 1_048_576,
      attempt_timeout: 10_000,
      retries: 0
    }
    |> Options.assign_defaults()
    |> Store.bind_run()
  end

  defp with_cycle(c, order, body_cap, callback) do
    routes =
      Map.new([{"a", "b"}, {"b", "a"}], fn {name, child} ->
        body =
          ~s|<meta charset="utf-8"><a href="/#{child}#part">other</a><a href="/failed#lost">failed</a>|

        {"/" <> name, {"text/html", body}}
      end)

    {base, listener, server} = serve_routes(routes)
    parent = self()
    tag = make_ref()
    opts = c.opts |> Map.put(:url, base <> "/failed") |> Map.put(:max_body, body_cap)

    try do
      assert {:error, :fixture_failure} =
               Execution.run_job(opts, fn owned ->
                 send(parent, {tag, :failed, owned.target_handle})
                 {:error, :fixture_failure}
               end)

      assert_receive {^tag, :failed, failed}, 5000

      jobs = Enum.map(order, &admit_cycle_target(opts, &1, failed, tag))
      bind_cycle_targets(jobs)

      for {_, _, _, task} <- jobs, do: assert(Task.await(task, 10_000) == :ok)
      callback.(opts, base, failed)
    after
      stop_server(listener, server)
    end
  end

  defp admit_cycle_target(opts, name, failed, tag) do
    parent = self()

    task =
      Task.async(fn ->
        Execution.run_job(
          %{opts | url: String.replace_suffix(opts.url, "/failed", "/" <> name)},
          fn owned ->
            await_cycle_binding(owned, parent, tag, name, failed)
          end
        )
      end)

    assert_receive {^tag, :admitted, ^name, target, executor}, 5000
    {name, target, executor, task}
  end

  defp await_cycle_binding(owned, parent, tag, name, failed) do
    send(parent, {tag, :admitted, name, owned.target_handle, self()})

    receive do
      {:bind, child_name, child} ->
        produce_owned(owned, :rewrite, &cycle_target(&1, child_name, child, failed))
    after
      5000 -> flunk("fixture did not supply the actual admitted child")
    end
  end

  defp cycle_target(occurrence, child_name, child, failed) do
    cond do
      occurrence.value == "/" <> child_name <> "#part" -> child
      occurrence.value == "/failed#lost" -> failed
      true -> nil
    end
  end

  defp bind_cycle_targets(jobs) do
    for {name, _, executor, _} <- jobs do
      {child_name, child, _, _} = Enum.find(jobs, fn {other, _, _, _} -> other != name end)
      send(executor, {:bind, child_name, child})
    end
  end

  defp hold_seal(owned, closed, filesystem, parent) do
    assert {:ok, scratch} = Store.reserve_resource(owned, :scratch, 98_304)

    try do
      assert {:ok, payload, receipt} = Store.export_seal(owned, closed.epoch, closed.close_token)
      credit = %{retained: [], backing: [], overlap: receipt, unavailable: 0}
      assert {:ok, funding} = Store.resource_funding(owned, credit)
      assert {:ok, complete} = Retained.return_bytes(payload, nil, owned.max_retained_bytes)
      send(parent, {:seal_held, self(), filesystem, receipt, funding.overlap_capacity, complete})

      receive do
        :verify_held_snapshot ->
          assert map_size(payload.snapshot.artifacts) == 1
          assert map_size(payload.staged) == 1

          assert Enum.any?(elem(Process.info(self(), :binary), 1), fn {_, size, _} ->
                   size > 1000
                 end)

          send(parent, {:held_snapshot_verified, self()})

          receive do
            :release_held_snapshot -> :ok
          after
            5000 -> flunk("retirement did not end the actual finalizer")
          end
      after
        5000 -> flunk("retirement test did not release held snapshot")
      end

      Store.release_resource(receipt)
    after
      Store.release_resource(scratch)
    end
  end

  defp stage(opts, path, type, body, mode) do
    {url, listener, server} = serve(path, type, body)
    opts = Map.put(opts, :url, url)

    try do
      assert :ok =
               Execution.run_job(opts, fn owned ->
                 produce_owned(owned, mode, fn _ -> nil end)
               end)

      opts
    after
      stop_server(listener, server)
    end
  end

  defp produce_owned(owned, mode, resolver) do
    source = fetch_source(owned, mode)
    assert {:ok, export} = Store.export_context(owned)
    receipt = export.context_receipt

    try do
      assert {:ok, filesystem} = Store.export_filesystem(owned, export.epoch)
      assert {:ok, overlap} = Store.reserve_resource(owned, :snapshot, 65_536)

      try do
        Runtime.with_io(context(owned, export, filesystem), fn runtime ->
          produce_source(owned, export, runtime, source, mode, resolver, overlap)
        end)
      after
        Store.release_resource(overlap)
      end
    after
      Store.release_resource(receipt)
    end
  end

  defp fetch_source(owned, :copy) do
    assert {:ok, response} = Fetcher.control_request(owned)
    revision = Req.Response.get_private(response, :crawler_source_revision)
    response_receipt = Req.Response.get_private(response, :crawler_response_receipt)
    assert is_reference(revision)
    assert Authority.resource_current?(response_receipt, owned.execution_lease, self())

    %{
      body: response.body,
      source_revision: revision,
      opts: %{
        url: owned.url,
        content_type: hd(Req.Response.get_header(response, "content-type"))
      },
      credit: %{retained: [], backing: [response_receipt], unavailable: 0}
    }
  end

  defp fetch_source(owned, :rewrite) do
    assert %Crawler.Store.Page{} = page = Fetcher.fetch(Map.put(owned, :save_to, nil))
    assert page.analysis.limits.max_total_bytes == 16_000_000
    assert page.target_handle === owned.target_handle
    page
  end

  defp produce_source(owned, export, runtime, source, mode, resolver, overlap) do
    credit =
      Map.put(Map.take(source.credit, [:retained, :backing, :unavailable]), :overlap, overlap)

    assert {:ok, funding} = Store.resource_funding(owned, credit)

    assert {:ok, ack} =
             Runtime.stage_source(
               runtime,
               export.assignment.source_path,
               source.body,
               source.source_revision,
               :borrowed,
               funding
             )

    assert is_reference(ack.operation)

    assert :ok =
             Store.export_source(
               owned,
               export.epoch,
               ack.operation,
               source.opts.content_type,
               source.opts.url
             )

    if mode == :copy do
      descriptor = %{
        source_operation: ack.operation,
        source_revision: source.source_revision,
        lexical_operation: nil,
        analysis_revision: nil,
        public_id: export.assignment.public_id,
        render_mode: :copy
      }

      assert {:ok, version} =
               Store.export_candidate(
                 owned,
                 export.epoch,
                 export.assignment.version,
                 descriptor,
                 %{}
               )

      bound = %{
        operation: ack.operation,
        source_revision: source.source_revision,
        analysis_revision: nil,
        css_stamp: nil,
        edges_digest: StagedIO.edge_digest([])
      }

      assert :ok = Store.export_discovered(owned, export.epoch, version, %{}, bound)
      :ok
    else
      produce_rewrite(owned, export, runtime, source, resolver, overlap, ack.operation)
    end
  end

  defp produce_rewrite(owned, export, runtime, page, resolver, overlap, source_operation) do
    assert {:ok, workspace} = Store.reserve_resource(owned, :scratch, 98_304)
    result = binding_frame(owned, export, runtime, page, resolver, overlap, source_operation)
    Store.release_resource(workspace)
    result
  end

  defp binding_frame(owned, export, runtime, page, resolver, overlap, source_operation) do
    original = page.interpretation.collection
    assert {:ok, physical} = Retained.bytes({page.analysis, original}, owned.max_retained_bytes)
    binding_bytes = length(original.occurrences) * Budget.cost(:occurrence)
    capacity = max(physical, original.budget.retained - page.credit.unavailable) + binding_bytes
    assert {:ok, retained} = Store.reserve_resource(owned, :analysis, capacity)

    try do
      stage_bound(
        owned,
        export,
        runtime,
        page,
        resolver,
        overlap,
        source_operation,
        retained,
        capacity
      )
    after
      Store.release_resource(retained)
    end
  end

  defp stage_bound(
         owned,
         export,
         runtime,
         page,
         resolver,
         overlap,
         source_operation,
         retained,
         capacity
       ) do
    original = page.interpretation.collection
    assert {:ok, bound} = Analysis.bind(original, resolver)
    assert :ok = Store.commit_resource(retained, capacity)

    credit = %{
      retained: [retained],
      backing: page.credit.backing,
      overlap: overlap,
      unavailable: page.credit.unavailable
    }

    assert {:ok, funding} = Store.resource_funding(owned, credit)
    css = page.interpretation.css_revision

    assert {:ok, ack} =
             Runtime.stage_metadata(
               runtime,
               export.assignment.lexical_path,
               page.analysis,
               original,
               bound,
               css,
               page.source_revision,
               %{unavailable: page.credit.unavailable, root: :borrowed},
               funding
             )

    descriptor = %{
      source_operation: source_operation,
      source_revision: page.source_revision,
      lexical_operation: ack.operation,
      analysis_revision: page.analysis.revision,
      public_id: export.assignment.public_id,
      render_mode: :rewrite
    }

    assert {:ok, version} =
             Store.export_candidate(
               owned,
               export.epoch,
               export.assignment.version,
               descriptor,
               %{}
             )

    frozen = %{
      operation: ack.operation,
      source_revision: page.source_revision,
      analysis_revision: page.analysis.revision,
      css_stamp: css,
      edges_digest: StagedIO.edge_digest(bound.occurrences)
    }

    assert :ok = Store.export_discovered(owned, export.epoch, version, %{}, frozen)
    :ok
  end

  defp context(owned, export, filesystem) do
    %Context{
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
  end

  defp failed(opts) do
    opts = Map.put(opts, :url, "http://127.0.0.1/failed")

    assert {:error, :fixture_failure} =
             Execution.run_job(opts, fn _ -> {:error, :fixture_failure} end)

    opts
  end

  defp close(opts, attempts \\ 2000)
  defp close(_opts, 0), do: flunk("export did not become quiescent")

  defp close(opts, attempts) do
    case Store.close_export(opts) do
      {:ok, closed} ->
        closed

      :busy ->
        receive do
        after
          2 -> close(opts, attempts - 1)
        end

      error ->
        flunk("close failed: #{inspect(error)}")
    end
  end

  defp manifest(c),
    do: Path.join([c.root, "archive", "manifest.json"]) |> File.read!() |> Jason.decode!()

  defp assert_no_run_grants(opts, attempts \\ 1000) do
    if attempts == 1000, do: Store.dispose_scope(opts.scope)

    grants =
      :ets.match_object(
        Crawler.Store.Resources,
        {{:grant, :_, :_}, :_, {opts.scope, opts.generation}, :_}
      )

    if grants != [] and attempts > 0 do
      receive do
      after
        2 -> assert_no_run_grants(opts, attempts - 1)
      end
    else
      assert grants == []
    end
  end

  defp serve(path, type, body) do
    {base, listener, server} = serve_routes(%{path => {type, body}})
    {base <> path, listener, server}
  end

  defp serve_routes(routes) do
    assert {:ok, listener} =
             :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    assert {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    server = spawn(fn -> serve_loop(listener, routes) end)
    {"http://127.0.0.1:#{port}", listener, server}
  end

  defp stop_server(listener, server) do
    :gen_tcp.close(listener)
    monitor = Process.monitor(server)
    assert_receive {:DOWN, ^monitor, :process, ^server, _}, 2000
  end

  defp serve_loop(listener, routes) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        request = read_headers(socket, "")
        [line | _] = String.split(request, "\r\n")
        ["GET", path, _] = String.split(line, " ")

        {status, type, body} =
          case routes[path] do
            {type, body} -> {"200 OK", type, body}
            nil -> {"404 Not Found", "text/plain", "not found"}
          end

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 ",
            status,
            "\r\nContent-Type: ",
            type,
            "\r\nContent-Length: ",
            Integer.to_string(byte_size(body)),
            "\r\nConnection: close\r\n\r\n",
            body
          ])

        :gen_tcp.close(socket)
        serve_loop(listener, routes)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_headers(socket, bytes) do
    if String.contains?(bytes, "\r\n\r\n") do
      bytes
    else
      {:ok, next} = :gen_tcp.recv(socket, 0, 5000)
      read_headers(socket, bytes <> next)
    end
  end
end
