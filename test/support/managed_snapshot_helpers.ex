defmodule Crawler.ManagedSnapshotHelpers do
  @moduledoc false

  import ExUnit.Assertions
  import Crawler.TestHelpers, only: [wait: 2]

  alias Crawler.Deadline
  alias Crawler.Export.Paths
  alias Crawler.Export.Runtime
  alias Crawler.Export.Runtime.Context
  alias Crawler.Export.Stage
  alias Crawler.Export.StagedIO
  alias Crawler.Fetcher
  alias Crawler.Fetcher.HeaderPreparer
  alias Crawler.Fetcher.Recorder
  alias Crawler.Options
  alias Crawler.Parser
  alias Crawler.Store
  alias Crawler.Store.Execution

  defmodule GateParser do
    def parse(%Crawler.Store.Page{opts: opts} = page) do
      for {url, role, observer, key} <- opts[:managed_test_gates] || [],
          url == page.url and role == opts[:html_tag] do
        send(
          observer,
          {:managed_parser_held, key, self(), opts[:content_type], page.source_revision,
           page.target_handle}
        )

        receive do
          {:managed_parser_release, ^key} -> :ok
        after
          Crawler.Deadline.remaining(opts.crawler_deadline) ->
            raise "managed parser gate was not released"
        end
      end

      Crawler.Parser.parse(page)
    end

    def parse(other), do: Crawler.Parser.parse(other)
  end

  def ready_export(opts) do
    assert {:ok, %Deadline{} = deadline} = Store.run_deadline(opts[:scope], opts.generation)
    timeout = Deadline.remaining(deadline)

    status =
      wait(timeout, fn ->
        assert {:ok, status} = Crawler.export_status(opts)
        assert status.state in [:ready, :failed, :limited, :cancelled], inspect(status)
        status
      end)

    assert %{state: :ready, ready?: true, running?: false} = status, inspect(status)

    manifest = opts.save_to |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    assert {:ok, %{id: id, ready?: true}} = Crawler.export_status(opts)
    assert manifest["id"] == id
    %{root: opts.save_to, manifest: manifest}
  end

  def resource_for_url(export, url) do
    {:ok, online} = Paths.online(url)
    matches = Enum.filter(export.manifest["resources"], &(&1["url"] == online))

    assert [resource] = matches,
           "expected one manifest resource for #{online}, got #{length(matches)}"

    resource
  end

  def resource_by_id(export, id) do
    assert [resource] = Enum.filter(export.manifest["resources"], &(&1["id"] == id))
    resource
  end

  def artifact_path(export, resource) do
    assert resource_by_id(export, resource["id"]) == resource
    assert Paths.relative_file?(resource["path"])
    path = Path.expand(resource["path"], export.root)
    assert String.starts_with?(path, Path.expand(export.root) <> "/resources/")
    assert File.regular?(path)
    path
  end

  def read_resource(export, resource), do: File.read!(artifact_path(export, resource))

  def edge_target(export, source, index) do
    assert [edge] =
             Enum.filter(export.manifest["references"], fn edge ->
               edge["from"] == source["id"] and edge["edge"] == index
             end)

    assert edge["outcome"] == "succeeded"
    resource_by_id(export, edge["target"])
  end

  def reference_target(export, source, url) do
    {:ok, online} = Paths.online(url)

    edges =
      Enum.filter(export.manifest["references"], fn edge ->
        edge["from"] == source["id"] and edge["url"] == online
      end)

    assert edges != []
    assert Enum.all?(edges, &(&1["outcome"] == "succeeded"))
    assert [id] = edges |> Enum.map(& &1["target"]) |> Enum.uniq()
    resource_by_id(export, id)
  end

  def relative_reference(source, target, fragment \\ "") do
    assert {:ok, href} = Paths.relative(source["path"], target["path"])
    href <> fragment
  end

  def assert_opens(export, source, target, href, fragment \\ "") do
    uri = URI.parse(href)
    assert is_nil(uri.scheme) and is_nil(uri.host) and is_nil(uri.query)
    assert ((uri.fragment && "#" <> uri.fragment) || "") == fragment
    opened = Path.expand(URI.decode(uri.path), Path.dirname(artifact_path(export, source)))
    assert opened == artifact_path(export, target)
    assert File.read!(opened) == read_resource(export, target)
    target
  end

  def assert_points(body, from_url, target_url, export, fragment \\ "") do
    source = resource_for_url(export, from_url)
    target = reference_target(export, source, target_url)
    href = relative_reference(source, target, fragment)
    assert body =~ href
    assert_opens(export, source, target, href, fragment)
  end

  def assert_link_opens(export, source, target) when is_map(source) and is_map(target) do
    href = relative_reference(source, target)
    assert read_resource(export, source) =~ href
    assert_opens(export, source, target, href)
  end

  def stage_copy(options, context_transform \\ &Function.identity/1) do
    opts = options |> Map.new() |> Options.assign_defaults() |> Store.bind_run()
    assert is_map(opts)
    assert is_nil(opts.queue)

    result = Execution.run_job(opts, &produce_copy(&1, context_transform))

    case result do
      :ok -> {:ok, opts}
      error -> error
    end
  end

  defp produce_copy(owned, context_transform) do
    with {:ok, _} <- Recorder.admitted(owned),
         {:ok, response} <- Fetcher.control_request(owned) do
      opts =
        response
        |> Req.get_headers_list()
        |> HeaderPreparer.prepare(owned)
        |> Map.put(:source_revision, Req.Response.get_private(response, :crawler_source_revision))
        |> Map.put(:referrer_url, Req.Response.get_private(response, :crawler_url) || owned.url)

      assert not Crawler.MediaType.text?(opts.content_type)
      assert not Crawler.MediaType.javascript?(opts.content_type)
      assert Crawler.MediaType.document_mode(opts.content_type) != :xml
      assert {:ok, prepared} = Parser.prepare_for_parse(response.body, opts)

      credit = %{
        retained: [],
        backing: [Req.Response.get_private(response, :crawler_response_receipt)],
        unavailable: 0
      }

      with {:ok, _} <- Recorder.maybe_store_page(response.body, opts),
           :ok <-
             with_context(
               owned,
               &produce_copy_context(owned, prepared, credit, &1, context_transform)
             ) do
        Store.complete_page({owned.url, owned.scope}, owned.generation, owned.queue, nil, false)
        :ok
      end
    end
  end

  defp produce_copy_context(owned, prepared, credit, export, transform) do
    with {:ok, filesystem} <- Store.export_filesystem(owned, export.epoch) do
      context = transform.(Context.new(owned, export.epoch, export.job, filesystem))

      Runtime.with_io(context, fn runtime ->
        with :ok <- Stage.source(runtime, prepared, credit, export.assignment) do
          with_context(owned, &stage_copy_current(runtime, prepared, credit, &1))
        end
      end)
    end
  end

  defp stage_copy_current(runtime, prepared, credit, current) do
    assert Parser.emit_bound(prepared, fn _, _ -> flunk("opaque callback") end, fn _, _ ->
             flunk("opaque observation")
           end) == []

    case Stage.stage(runtime, prepared, credit, current.assignment, %{}) do
      {:ok, _version} -> :ok
      error -> error
    end
  end

  def finalize_copy(opts, before_commit \\ fn _ -> :ok end) do
    with {:ok, closed} <- Store.close_export(opts) do
      Execution.run_finalizer(Map.merge(opts, closed), fn owned ->
        with_context(owned, &finalize_copy_context(owned, closed, &1, before_commit))
      end)
    end
  end

  defp finalize_copy_context(owned, closed, export, before_commit) do
    with {:ok, filesystem} <- Store.export_filesystem(owned, export.epoch) do
      Runtime.with_io(Context.new(owned, export.epoch, export.job, filesystem), fn runtime ->
        seal_copies(owned, closed, runtime, filesystem, before_commit)
      end)
    end
  end

  defp seal_copies(owned, closed, runtime, filesystem, before_commit) do
    with :ok <- prepare_copies(owned, closed, filesystem.receipt, nil),
         {:ok, payload, receipt} <- Store.export_seal(owned, closed.epoch, closed.close_token) do
      try do
        commit_copies(owned, closed, runtime, filesystem, payload, before_commit)
      after
        Store.release_resource(receipt)
      end
    end
  end

  defp prepare_copies(owned, closed, recovery, cursor) do
    case Store.export_prepare_next(owned, closed.epoch, closed.close_token, cursor) do
      {:ok, {:batch, rows, next}, receipt} ->
        result =
          try do
            Enum.reduce_while(rows, :ok, fn row, :ok ->
              result = prepare_copy_row(owned, closed, recovery, row)
              continue_copy(result)
            end)
          after
            Store.release_resource(receipt)
          end

        with :ok <- result, do: prepare_copies(owned, closed, recovery, next)

      :done ->
        :ok

      error ->
        error
    end
  end

  defp continue_copy(:ok), do: {:cont, :ok}
  defp continue_copy(error), do: {:halt, error}

  defp prepare_copy_row(owned, closed, recovery, row) do
    assert row.descriptor.render_mode == :copy

    workspace(owned, row.plans.source.bytes + 1, fn funding ->
      with {:ok, _} <- StagedIO.read(row.plans.source, recovery, funding) do
        Store.export_prepared(
          owned,
          closed.epoch,
          closed.close_token,
          row.target,
          row.descriptor.source_operation,
          []
        )
      end
    end)
  end

  defp commit_copies(owned, closed, runtime, filesystem, payload, before_commit) do
    snapshot = payload.snapshot

    with :ok <- render_copies(owned, closed, runtime, payload),
         {:ok, manifest_operation} <-
           workspace(owned, owned.max_manifest_bytes, fn funding ->
             with {:ok, ack} <-
                    Runtime.public_manifest(runtime, snapshot, owned.max_manifest_bytes, funding),
                  do: {:ok, ack.operation}
           end),
         {:ok, prepared} <- Runtime.prepare(runtime) do
      before_commit.(%{
        runtime: runtime,
        owned: owned,
        filesystem: filesystem,
        snapshot: snapshot,
        closed: closed,
        prepared: prepared,
        manifest_operation: manifest_operation
      })

      Store.export_commit(
        owned,
        closed.epoch,
        closed.close_token,
        snapshot.seal_token,
        prepared,
        manifest_operation
      )
    end
  end

  defp render_copies(owned, closed, runtime, payload) do
    Enum.reduce_while(payload.snapshot.artifacts, :ok, fn {target, artifact}, :ok ->
      assert artifact.render_mode == :copy
      source = payload.staged[artifact.source_handle]

      result =
        workspace(owned, source.bytes + 1, fn funding ->
          with {:ok, ack, _} <-
                 Runtime.render(runtime, payload.snapshot, target, payload.staged, funding) do
            Store.export_rendered(
              owned,
              closed.epoch,
              payload.snapshot.seal_token,
              target,
              ack.operation
            )
          end
        end)

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp workspace(owned, bytes, consume) do
    with {:ok, receipt} <- Store.reserve_resource(owned, :snapshot, bytes) do
      try do
        credit = %{retained: [], backing: [], overlap: receipt, unavailable: 0}
        with {:ok, funding} <- Store.resource_funding(owned, credit), do: consume.(funding)
      after
        Store.release_resource(receipt)
      end
    end
  end

  defp with_context(opts, consume) do
    with {:ok, export} <- Store.export_context(opts) do
      try do
        consume.(export)
      after
        Store.release_resource(export.context_receipt)
      end
    end
  end
end
