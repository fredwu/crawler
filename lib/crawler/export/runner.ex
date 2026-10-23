defmodule Crawler.Export.Runner do
  @moduledoc """
  Finalizes one closed managed export through its admitted canonical Job.

  The caller supplies the original normalized options and `Store.close_export/1`
  result. Preparation reuses frozen staged operations; it does not discover new
  targets or change bindings. Store retains publication and readiness authority.
  """

  alias Crawler.Export.Runtime
  alias Crawler.Export.Runtime.Context
  alias Crawler.Export.StagedIO
  alias Crawler.Limits
  alias Crawler.Store
  alias Crawler.Store.Execution

  def finalize(original_opts, %{epoch: epoch, close_token: close, target_handle: target} = closed)
      when is_map(original_opts) and is_reference(epoch) and is_reference(close) and
             is_reference(target) do
    Execution.run_finalizer(Map.merge(original_opts, closed), fn owned ->
      case Store.export_context(owned) do
        {:ok, export} ->
          receipt = export.context_receipt

          try do
            consume_context(owned, closed, export)
          after
            Store.release_resource(receipt)
          end

        error ->
          error
      end
    end)
  end

  defp consume_context(owned, closed, export) do
    with true <- export.epoch === closed.epoch or {:error, :stale_export},
         true <- export.job.id === closed.target_handle or {:error, :stale_finalizer},
         {:ok, filesystem} <- Store.export_filesystem(owned, closed.epoch) do
      Runtime.with_io(Context.new(owned, closed.epoch, export.job, filesystem), fn runtime ->
        with :ok <- prepare_all(owned, closed, filesystem.receipt, nil) do
          seal_and_render(owned, closed, runtime)
        end
      end)
    end
  end

  defp prepare_all(owned, closed, recovery, cursor) do
    case Store.export_prepare_next(owned, closed.epoch, closed.close_token, cursor) do
      {:ok, {:batch, rows, next}, receipt} ->
        result =
          try do
            consume_batch(owned, closed, recovery, rows, next, cursor)
          after
            Store.release_resource(receipt)
          end

        with :ok <- result, do: prepare_all(owned, closed, recovery, next)

      :done ->
        :ok

      error ->
        error
    end
  end

  defp consume_batch(owned, closed, recovery, rows, next, cursor)
       when is_integer(next) and next >= 0 and (is_nil(cursor) or next > cursor) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case prepare_row(owned, closed, recovery, row) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp consume_batch(_owned, _closed, _recovery, _rows, _next, _cursor),
    do: {:error, :invalid_cursor}

  defp prepare_row(owned, closed, recovery, %{descriptor: %{render_mode: :copy}} = row) do
    with_workspace(owned, row.plans.source.bytes + 1, 0, fn funding ->
      with :ok <- verify_source(row.plans.source, recovery, funding) do
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

  defp prepare_row(owned, closed, recovery, %{descriptor: %{render_mode: :rewrite}} = row) do
    metadata = row.plans.bound

    capacity =
      max(row.plans.source.bytes + 1, metadata.read_capacity + 1 + metadata.decoded_bytes)

    with_workspace(owned, capacity, metadata.unavailable, fn funding ->
      with :ok <- verify_source(row.plans.source, recovery, funding),
           {:ok, payload} <- StagedIO.replay(metadata, recovery, funding),
           true <-
             payload.analysis.limits === Limits.analysis(owned) or {:error, :changed_limits},
           edges = StagedIO.compact_edges(payload.bound.occurrences),
           true <-
             StagedIO.edge_digest(edges) === row.bound.edges_digest or
               {:error, :changed_occurrence_collection} do
        Store.export_prepared(
          owned,
          closed.epoch,
          closed.close_token,
          row.target,
          row.bound.operation,
          edges
        )
      end
    end)
  end

  defp verify_source(source, recovery, funding) do
    case StagedIO.read(source, recovery, funding) do
      {:ok, _bytes} -> :ok
      error -> error
    end
  end

  defp seal_and_render(owned, closed, runtime) do
    case Store.export_seal(owned, closed.epoch, closed.close_token) do
      {:ok, payload, receipt} ->
        try do
          render_and_commit(owned, closed, runtime, payload)
        after
          Store.release_resource(receipt)
        end

      error ->
        error
    end
  end

  defp render_and_commit(
         owned,
         closed,
         runtime,
         %{snapshot: snapshot, manifest_capacity: capacity} = payload
       ) do
    with :ok <- render_all(owned, closed, runtime, payload),
         {:ok, manifest_operation} <- public_manifest(owned, runtime, snapshot, capacity),
         {:ok, prepared} <- Runtime.prepare(runtime) do
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

  defp render_all(owned, closed, runtime, %{snapshot: snapshot, staged: staged}) do
    Enum.reduce_while(snapshot.artifacts, :ok, fn {target, artifact}, :ok ->
      source = staged[artifact.source_handle]
      metadata = staged[artifact.analysis_handle]

      capacity =
        if artifact.render_mode == :copy,
          do: source.bytes + 1,
          else:
            max(metadata.bound_budget.limit - metadata.unavailable, metadata.read_capacity + 1)

      unavailable = if metadata, do: metadata.unavailable, else: 0

      result =
        with_workspace(owned, capacity, unavailable, fn funding ->
          with {:ok, ack, _stats} <- Runtime.render(runtime, snapshot, target, staged, funding) do
            Store.export_rendered(owned, closed.epoch, snapshot.seal_token, target, ack.operation)
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp public_manifest(owned, runtime, snapshot, capacity) do
    with_workspace(owned, capacity, 0, fn funding ->
      with {:ok, ack} <-
             Runtime.public_manifest(runtime, snapshot, capacity, funding),
           do: {:ok, ack.operation}
    end)
  end

  defp with_workspace(owned, bytes, unavailable, callback) do
    with {:ok, receipt} <- Store.reserve_resource(owned, :snapshot, bytes) do
      try do
        credit = %{retained: [], backing: [], overlap: receipt, unavailable: unavailable}
        with {:ok, funding} <- Store.resource_funding(owned, credit), do: callback.(funding)
      after
        Store.release_resource(receipt)
      end
    end
  end
end
