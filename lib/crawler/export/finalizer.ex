defmodule Crawler.Export.Finalizer do
  @moduledoc """
  One-artifact funded finalization steps over the sealed Manifest eligible set.

  Execute outside Store. The owner schedules the existing canonical :finalize
  Job, records exact IO acknowledgements and prepares publication after complete
  coverage. This module cannot promote, cancel a prepared gate or mark ready.
  It creates no processes, scheduler or authority checks that replace Store.
  """

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Export.Manifest
  alias Crawler.Export.StagedIO
  alias Crawler.Export.StagedIO.Plan
  alias Crawler.MediaType

  def render(snapshot, target, staged, receipt, funding) do
    case snapshot.artifacts[target] do
      nil ->
        {:error, :ineligible_target}

      artifact ->
        case staged[artifact.source_handle] do
          %Plan{kind: :source, source_revision: revision} = source
          when revision == artifact.source_revision ->
            render_artifact(
              snapshot,
              target,
              source,
              staged[artifact.analysis_handle],
              receipt,
              funding
            )

          _ ->
            {:error, :source_revision_mismatch}
        end
    end
  end

  defp render_artifact(snapshot, target, source, metadata, receipt, funding) do
    case snapshot.artifacts[target] do
      %{render_mode: :copy} ->
        with {:ok, bytes} <- StagedIO.read(source, receipt, funding),
             do: {:ok, bytes, nil}

      %{render_mode: :rewrite, analysis_revision: revision} = artifact ->
        with %Plan{kind: :metadata, analysis_revision: ^revision} <- metadata,
             true <-
               source.source_revision == metadata.source_revision or
                 {:error, :source_revision_mismatch},
             true <- source.digest == metadata.source_digest or {:error, :source_digest_mismatch},
             :ok <-
               StagedIO.authorized(funding, metadata.bound_budget.limit - metadata.unavailable),
             {:ok, payload} <- StagedIO.replay(metadata, receipt, funding),
             true <-
               byte_size(payload.analysis.regions[payload.analysis.root].source) == source.bytes or
                 {:error, :source_size_mismatch},
             {:ok, bytes, stats} <-
               Analysis.render_with_stats(
                 payload.analysis,
                 payload.bound,
                 &Manifest.resolve(snapshot, target, &1)
               ),
             :ok <-
               StagedIO.authorized(funding, metadata.bound_budget.limit - metadata.unavailable) do
          output(bytes, artifact.content_type, stats)
        else
          %Plan{} -> {:error, :analysis_revision_mismatch}
          nil -> {:error, :unstaged_metadata}
          error -> error
        end

      nil ->
        {:error, :ineligible_target}
    end
  end

  def plan_output(snapshot, target, bytes) do
    with %{path: path} <- snapshot.artifacts[target] do
      StagedIO.plan_bytes(:archive, path, bytes)
    else
      nil -> {:error, :ineligible_target}
    end
  end

  @doc "The caller supplies the existing normalized manifest memory bound."
  def public_manifest(snapshot, max_bytes, funding)
      when is_integer(max_bytes) and max_bytes > 0 do
    with :ok <- StagedIO.authorized(funding, max_bytes),
         manifest = Manifest.public_manifest(snapshot),
         {:ok, metadata_bytes} <- StagedIO.measure(manifest, max_bytes),
         {:ok, output_bound} <- json_bound(manifest, max_bytes - metadata_bytes),
         :ok <- StagedIO.authorized(funding, metadata_bytes + output_bound),
         {:ok, bytes} <- Jason.encode(manifest),
         :ok <- StagedIO.authorized(funding, metadata_bytes + output_bound),
         true <- byte_size(bytes) <= output_bound or {:error, :manifest_size_mismatch},
         {:ok, plan} <- StagedIO.plan_bytes(:archive, "manifest.json", bytes) do
      {:ok, plan, bytes}
    end
  end

  defp output(bytes, type, stats) do
    if MediaType.html?(type) and not MediaType.xhtml?(type) and
         not String.starts_with?(bytes, <<0xEF, 0xBB, 0xBF>>) do
      budget = struct!(Budget, stats.budget)

      with {:ok, budget} <- Budget.reserve(budget, byte_size(bytes) + 3),
           {:ok, budget} <- Budget.settle(budget, byte_size(bytes) + 3, byte_size(bytes) + 3),
           do: {:ok, <<0xEF, 0xBB, 0xBF>> <> bytes, %{stats | budget: Budget.snapshot(budget)}}
    else
      {:ok, bytes, stats}
    end
  end

  defp json_bound(value, limit) when is_map(value) do
    Enum.reduce_while(value, {:ok, 2}, fn {key, entry}, {:ok, used} ->
      with {:ok, key_bytes} <- json_bound(Atom.to_string(key), limit - used),
           {:ok, value_bytes} <- json_bound(entry, limit - used - key_bytes - 2),
           {:ok, next} <- fit(used + key_bytes + value_bytes + 2, limit) do
        {:cont, {:ok, next}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp json_bound(value, limit) when is_list(value) do
    Enum.reduce_while(value, {:ok, 2}, fn entry, {:ok, used} ->
      case json_bound(entry, limit - used - 1) do
        {:ok, bytes} -> {:cont, fit(used + bytes + 1, limit)}
        error -> {:halt, error}
      end
    end)
  end

  defp json_bound(value, limit) when is_binary(value), do: fit(2 + 6 * byte_size(value), limit)

  defp json_bound(value, limit) when is_integer(value),
    do: fit(byte_size(Integer.to_string(value)), limit)

  defp json_bound(nil, limit), do: fit(4, limit)
  defp json_bound(value, limit) when is_atom(value), do: json_bound(Atom.to_string(value), limit)

  defp fit(bytes, limit) when bytes <= limit, do: {:ok, bytes}
  defp fit(_bytes, _limit), do: {:error, {:limit, :max_manifest_bytes}}
end
