defmodule Crawler.Export.Session do
  @moduledoc """
  Pure descriptor adapter embedded in the authoritative Store state.

  The Store owner supplies canonical Jobs, admission epochs, seal tokens and the
  finalizer Job. This module creates no authority, identities, scheduler, claims
  or outcomes. All six commit checks and owner-local filesystem promotion belong
  in the actual Store callback. `seal/4` is called only after that callback proves
  quiescence and excludes admission. `promoted/3` records an already successful
  promotion in the same callback; it cannot perform or authorize promotion.

  Source and metadata payloads stay on disk. Compact descriptors and budgets
  share the caller's existing manifest metadata cap. Pending writes share the
  existing file and staged-byte caps, with no early refund.
  """

  alias Crawler.Export.Manifest
  alias Crawler.Export.StagedIO
  alias Crawler.Export.StagedIO.Ack
  alias Crawler.Export.StagedIO.Plan
  alias Crawler.Job
  alias Crawler.Job.Outcome

  @derive {Inspect, only: []}
  @enforce_keys [:manifest, :run, :epoch]
  defstruct [
    :manifest,
    :run,
    :epoch,
    :snapshot,
    :finalizer,
    pending: %{},
    staged: %{},
    descriptor_bytes: 0
  ]

  def new(id, run, epoch, limits) do
    with {:ok, manifest} <- Manifest.new(id, epoch, limits),
         do: {:ok, %__MODULE__{manifest: manifest, run: run, epoch: epoch}}
  end

  def admit(state, epoch, %Job{} = job) do
    with :ok <- open(state, epoch),
         :ok <- same_run(state, job) do
      case state.manifest.targets[job.id] do
        nil ->
          change(
            state,
            Manifest.admit(state.manifest, job.id, job.representation_id, job.interpretation_id)
          )

        %{representation_id: representation, interpretation_id: interpretation}
        when representation === job.representation_id and interpretation === job.interpretation_id ->
          {:existing, state}

        _ ->
          {:error, :target_identity_changed}
      end
    end
  end

  def reserve(state, epoch, operation, %Plan{} = plan) do
    with :ok <- matching_epoch(state, epoch),
         true <- is_reference(operation) or {:error, :invalid_operation},
         true <-
           (is_binary(plan.digest) and byte_size(plan.digest) == 32) or {:error, :unencoded_plan},
         true <- not Map.has_key?(state.staged, operation) or {:error, :operation_exists},
         true <- not Map.has_key?(state.pending, operation) or {:error, :operation_exists},
         {:ok, manifest} <-
           Manifest.reserve(state.manifest, operation, plan.area, plan.path, plan.bytes),
         {:ok, cost} <-
           StagedIO.measure({operation, plan}, state.manifest.limits.max_manifest_bytes),
         bytes = state.descriptor_bytes + cost,
         :ok <- metadata_bound(manifest, bytes) do
      {:ok,
       %{
         state
         | manifest: manifest,
           pending: Map.put(state.pending, operation, plan),
           descriptor_bytes: bytes
       }}
    end
  end

  def written(state, epoch, operation, %Ack{plan: plan}) do
    with :ok <- matching_epoch(state, epoch),
         true <- state.pending[operation] === plan or {:error, :stale_write},
         {:ok, manifest} <- Manifest.written(state.manifest, operation) do
      {:ok,
       %{
         state
         | manifest: manifest,
           pending: Map.delete(state.pending, operation),
           staged: Map.put(state.staged, operation, plan)
       }}
    end
  end

  def response(state, epoch, target, source_operation, content_type, final_url) do
    with :ok <- open(state, epoch),
         %{representation_id: representation} <- state.manifest.targets[target],
         %Plan{kind: :source} = source <- state.staged[source_operation] do
      change(
        state,
        Manifest.put_response(state.manifest, representation, %{
          source_handle: source_operation,
          source_ticket: source_operation,
          source_revision: source.source_revision,
          content_type: content_type,
          final_url: final_url
        })
      )
    else
      nil -> {:error, :unstaged_source}
      error -> error
    end
  end

  def interpretation(state, epoch, target, metadata_operation, public_id, compact_edges) do
    with :ok <- open(state, epoch),
         %Plan{kind: :metadata} = metadata <- state.staged[metadata_operation],
         true <-
           StagedIO.edge_digest(compact_edges) == metadata.edges_digest or
             {:error, :changed_occurrence_collection},
         {:ok, manifest} <-
           Manifest.put_interpretation(state.manifest, target, %{
             public_id: public_id,
             source_revision: metadata.source_revision,
             render_mode: :rewrite,
             analysis_revision: metadata.analysis_revision,
             analysis_handle: metadata_operation,
             occurrences_handle: metadata_operation
           }),
         {:ok, manifest} <- Manifest.put_edges(manifest, target, compact_edges),
         :ok <- metadata_bound(manifest, state.descriptor_bytes) do
      {:ok, %{state | manifest: manifest}}
    else
      nil -> {:error, :unstaged_metadata}
      error -> error
    end
  end

  def copy(state, epoch, target, public_id) do
    with :ok <- open(state, epoch),
         %{representation_id: representation} <- state.manifest.targets[target],
         %{source_revision: revision} <- state.manifest.responses[representation],
         {:ok, manifest} <-
           Manifest.put_interpretation(state.manifest, target, %{
             public_id: public_id,
             source_revision: revision,
             render_mode: :copy
           }),
         {:ok, manifest} <- Manifest.put_edges(manifest, target, []) do
      change(state, {:ok, manifest})
    else
      nil -> {:error, :unstaged_source}
      error -> error
    end
  end

  def settle(state, epoch, target, %Outcome{} = outcome) do
    with :ok <- open(state, epoch),
         do: change(state, Manifest.settle(state.manifest, target, outcome))
  end

  @doc "Call only inside the owner's atomic admission/quiescence transition."
  def seal(state, epoch, seal_token, %Job{kind: :finalize} = finalizer) do
    with :ok <- open(state, epoch),
         :ok <- same_run(state, finalizer),
         true <- map_size(state.pending) == 0 or {:error, :pending_io},
         true <- is_nil(state.finalizer) or {:error, :finalizer_exists},
         {:ok, snapshot, manifest} <- Manifest.seal(state.manifest, epoch, seal_token) do
      {:ok, snapshot,
       %{
         state
         | snapshot: snapshot,
           manifest: manifest,
           finalizer: %{id: finalizer.id, outcome: nil}
       }}
    end
  end

  def rendered(state, epoch, seal_token, target, operation) do
    with :ok <- matching_epoch(state, epoch),
         do: change(state, Manifest.rendered(state.manifest, seal_token, target, operation))
  end

  def validate_commit(state, epoch, seal_token, finalizer_id, manifest_operation) do
    with :ok <- matching_epoch(state, epoch),
         %{id: ^finalizer_id, outcome: nil} <- state.finalizer,
         true <- map_size(state.pending) == 0 or {:error, :pending_io} do
      Manifest.validate_commit(state.manifest, seal_token, manifest_operation)
    else
      nil -> {:error, :missing_finalizer}
      %{} -> {:error, :stale_finalizer}
      error -> error
    end
  end

  @doc "Record after owner-local promotion; the owner supplies the canonical Outcome."
  def promoted(state, manifest_operation, %Outcome{status: :succeeded} = outcome) do
    with %{outcome: nil} = finalizer <- state.finalizer,
         {:ok, manifest} <-
           Manifest.ready(state.manifest, state.manifest.seal_token, manifest_operation) do
      {:ok, %{state | manifest: manifest, finalizer: %{finalizer | outcome: outcome}}}
    else
      _ -> {:error, :closed_finalizer}
    end
  end

  @doc "Revoke only after the Store owner closes every prepared filesystem gate."
  def terminate(state, %Outcome{status: status} = outcome)
      when status in [:cancelled, :failed, :limited] do
    result =
      if status == :cancelled,
        do: Manifest.cancel(state.manifest),
        else: Manifest.fail(state.manifest, status)

    with {:ok, manifest} <- result do
      finalizer = if state.finalizer, do: %{state.finalizer | outcome: outcome}, else: nil
      {:ok, %{state | manifest: manifest, finalizer: finalizer}}
    end
  end

  def status(state), do: Manifest.status(state.manifest)

  @doc "Project the owner's run result without deriving a second run outcome."
  def status(state, %{outcome: outcome, reported_limit: limit, running?: running, paused?: paused})
      when outcome in [:open, :completed, :succeeded, :limited, :failed, :cancelled] and
             is_boolean(running) and is_boolean(paused) do
    if safe_limit?(limit) do
      {:ok,
       %{
         run: %{outcome: outcome, reported_limit: limit, running?: running, paused?: paused},
         export: status(state)
       }}
    else
      {:error, :invalid_public_run_status}
    end
  end

  def status(_state, _owner_status), do: {:error, :invalid_public_run_status}

  defp change(state, {:ok, manifest}) do
    with :ok <- metadata_bound(manifest, state.descriptor_bytes),
         do: {:ok, %{state | manifest: manifest}}
  end

  defp change(_state, error), do: error

  defp open(state, epoch) do
    with :ok <- matching_epoch(state, epoch),
         true <- state.manifest.state == :admitting or {:error, :closed_export},
         do: :ok
  end

  defp matching_epoch(state, epoch),
    do: if(state.epoch === epoch, do: :ok, else: {:error, :stale_epoch})

  defp same_run(state, %Job{authority: {scope, generation, _queue}}),
    do: if(state.run === {scope, generation}, do: :ok, else: {:error, :stale_run})

  defp metadata_bound(manifest, bytes),
    do:
      if(manifest.metadata_bytes + bytes <= manifest.limits.max_manifest_bytes,
        do: :ok,
        else: {:error, {:limit, :max_manifest_bytes}}
      )

  defp safe_limit?(nil), do: true
  defp safe_limit?({:limit, reason}) when is_atom(reason), do: true
  defp safe_limit?(_reason), do: false
end
