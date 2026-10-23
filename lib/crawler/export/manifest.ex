defmodule Crawler.Export.Manifest do
  @moduledoc """
  Pure, bounded export records. The caller owns run authority and scheduler sealing.

  Target handles are caller-supplied canonical outcomes, never URLs or interpretation
  IDs inferred here. Source, analysis, and occurrence payloads remain opaque handles.
  All limits and random public IDs come from the caller; this module has no defaults,
  processes, filesystem operations, hidden identity generation, or request identity.

  `seal/3` only checks this manifest's records. Its epoch and seal token must be
  supplied inside the same owner transition that excludes further admission and
  proves scheduler/CSS/control/producer quiescence. It does not infer that proof.

  The staging envelope accounts for every reserved file, including sources,
  analysis, archive outputs, and the public manifest. The filesystem owner separately
  enforces actual writes. Reservations stay charged for their entire export lifetime.
  """

  alias Crawler.Export.Paths
  alias Crawler.Job.Outcome

  @limit_keys [
    :max_targets,
    :max_representations,
    :max_artifacts,
    :max_edges,
    :max_manifest_bytes,
    :max_staged_bytes,
    :max_staged_metadata_bytes,
    :max_file_bytes,
    :max_files
  ]
  @derive {Inspect, only: [:id, :state, :bytes, :files, :metadata_bytes]}
  defstruct [
    :id,
    :epoch,
    :limits,
    :seal_token,
    :failure,
    state: :admitting,
    targets: %{},
    responses: %{},
    interpretations: %{},
    edges: %{},
    public_ids: MapSet.new(),
    representation_ids: MapSet.new(),
    writes: %{},
    written_paths: MapSet.new(),
    rendered: %{},
    bytes: 0,
    files: 0,
    metadata_bytes: 0,
    staged_metadata_bytes: 0,
    edge_count: 0
  ]

  defmodule Snapshot do
    @moduledoc false
    @derive {Inspect, only: [:id]}
    defstruct [:id, :seal_token, :artifacts, :targets, :edges]
  end

  def new(id, epoch, limits) do
    limits = Map.new(limits)

    cond do
      not Paths.public_id?(id) ->
        {:error, :invalid_public_id}

      not handle?(epoch) ->
        {:error, :invalid_epoch}

      not Enum.all?(@limit_keys, &(is_integer(limits[&1]) and limits[&1] > 0)) ->
        {:error, :invalid_limits}

      true ->
        {:ok, %__MODULE__{id: id, epoch: epoch, limits: Map.take(limits, @limit_keys)}}
    end
  end

  def admit(state, target, representation_id, interpretation_id) do
    with :ok <- admitting(state),
         true <-
           Enum.all?([target, representation_id, interpretation_id], &handle?/1) or
             {:error, :invalid_handle},
         false <- Map.has_key?(state.targets, target),
         representations = MapSet.put(state.representation_ids, representation_id),
         :ok <-
           bound(
             MapSet.size(representations),
             state.limits.max_representations,
             :max_representations
           ) do
      record = %{
        representation_id: representation_id,
        interpretation_id: interpretation_id,
        outcome: nil
      }

      if map_size(state.targets) < state.limits.max_targets do
        with {:ok, state} <- put_record(state, :targets, target, record),
             do: {:ok, %{state | representation_ids: representations}}
      else
        {:error, {:limit, :max_targets}}
      end
    else
      true -> {:error, :target_exists}
      error -> error
    end
  end

  def reserve(state, ticket, area, path, bytes) do
    with :ok <- writable(state, area),
         true <- handle?(ticket) or {:error, :invalid_handle},
         true <- Paths.relative_file?(path) or {:error, :invalid_staged_path},
         true <- (is_integer(bytes) and bytes >= 0) or {:error, :invalid_size},
         false <- Map.has_key?(state.writes, ticket),
         false <- MapSet.member?(state.written_paths, {area, path}),
         :ok <- bound(bytes, state.limits.max_file_bytes, :max_file_bytes),
         :ok <- bound(state.bytes + bytes, state.limits.max_staged_bytes, :max_staged_bytes),
         :ok <- bound(state.files + 1, state.limits.max_files, :max_files),
         metadata = if(area == :metadata, do: bytes, else: 0),
         :ok <-
           bound(
             state.staged_metadata_bytes + metadata,
             state.limits.max_staged_metadata_bytes,
             :max_staged_metadata_bytes
           ),
         {:ok, state} <-
           put_record(state, :writes, ticket, %{
             area: area,
             path: path,
             bytes: bytes,
             written?: false
           }) do
      {:ok,
       %{
         state
         | bytes: state.bytes + bytes,
           files: state.files + 1,
           staged_metadata_bytes: state.staged_metadata_bytes + metadata,
           written_paths: MapSet.put(state.written_paths, {area, path})
       }}
    else
      true -> {:error, :reservation_exists}
      error -> error
    end
  end

  def written(state, ticket) do
    with :ok <- active(state), %{written?: false} = record <- state.writes[ticket] do
      put_record(state, :writes, ticket, %{record | written?: true})
    else
      nil -> {:error, :unknown_reservation}
      %{written?: true} -> {:error, :already_written}
      error -> error
    end
  end

  def put_response(state, representation_id, attrs) do
    with :ok <- admitting(state),
         true <- handle?(representation_id) or {:error, :invalid_handle},
         true <-
           MapSet.member?(state.representation_ids, representation_id) or
             {:error, :unknown_representation},
         false <- Map.has_key?(state.responses, representation_id),
         true <-
           (handle?(attrs[:source_handle]) and handle?(attrs[:source_revision])) or
             {:error, :invalid_source},
         %{area: :source, written?: true} <- state.writes[attrs[:source_ticket]],
         {:ok, url} <- Paths.online(attrs[:final_url]),
         :ok <-
           bound(
             map_size(state.responses) + 1,
             state.limits.max_representations,
             :max_representations
           ) do
      record = %{
        source_handle: attrs.source_handle,
        source_revision: attrs.source_revision,
        source_ticket: attrs.source_ticket,
        content_type: Paths.content_type(attrs[:content_type]),
        url: url
      }

      put_record(state, :responses, representation_id, record)
    else
      true -> {:error, :response_exists}
      nil -> {:error, :unstaged_source}
      %{} -> {:error, :unstaged_source}
      error -> error
    end
  end

  def put_interpretation(state, target, attrs) do
    with :ok <- admitting(state),
         {:ok, admitted} <- target_record(state, target),
         %{source_revision: revision} <- state.responses[admitted.representation_id],
         true <- attrs[:source_revision] === revision or {:error, :source_revision_mismatch},
         {:ok, payload} <- payload(attrs),
         {:ok, path} <-
           Paths.artifact(
             attrs[:public_id],
             state.responses[admitted.representation_id].content_type
           ),
         false <- Map.has_key?(state.interpretations, target),
         false <- MapSet.member?(state.public_ids, attrs.public_id),
         :ok <-
           bound(map_size(state.interpretations) + 1, state.limits.max_artifacts, :max_artifacts),
         {:ok, state} <-
           put_record(
             state,
             :interpretations,
             target,
             Map.merge(payload, %{
               id: attrs.public_id,
               path: path,
               source_revision: revision
             })
           ) do
      {:ok, %{state | public_ids: MapSet.put(state.public_ids, attrs.public_id)}}
    else
      true -> {:error, :artifact_exists}
      nil -> {:error, :unstaged_source}
      error -> error
    end
  end

  def put_edges(state, source, occurrences) when is_list(occurrences) do
    with :ok <- admitting(state),
         %{analysis_revision: revision, render_mode: mode} <- state.interpretations[source],
         true <- mode != :copy or occurrences == [] or {:error, :copy_has_occurrences},
         false <- Map.has_key?(state.edges, source),
         :ok <- bound(state.edge_count + length(occurrences), state.limits.max_edges, :max_edges),
         {:ok, edges} <- edges(occurrences, revision),
         {:ok, state} <- put_record(state, :edges, source, edges) do
      {:ok, %{state | edge_count: state.edge_count + map_size(edges)}}
    else
      true -> {:error, :edges_exist}
      nil -> {:error, :unknown_artifact}
      error -> error
    end
  end

  def settle(state, target, %Outcome{} = outcome) do
    with :ok <- admitting(state),
         {:ok, record} <- target_record(state, target),
         true <- is_nil(record.outcome) or {:error, :outcome_exists},
         true <-
           outcome.status in [:succeeded, :rejected, :failed, :limited, :cancelled] or
             {:error, :invalid_outcome},
         true <-
           ((is_nil(outcome.representation_id) or
               outcome.representation_id === record.representation_id) and
              (is_nil(outcome.interpretation_id) or
                 outcome.interpretation_id === record.interpretation_id)) or
             {:error, :outcome_identity_mismatch} do
      put_record(state, :targets, target, %{record | outcome: outcome.status})
    end
  end

  def seal(state, epoch, token) do
    with :ok <- admitting(state),
         true <- epoch === state.epoch or {:error, :stale_epoch},
         true <- handle?(token) or {:error, :invalid_seal},
         true <-
           Enum.all?(state.writes, fn {_, write} -> write.written? end) or
             {:error, :pending_writes},
         true <-
           Enum.all?(state.targets, fn {_, target} -> not is_nil(target.outcome) end) or
             {:error, :pending_outcomes},
         :ok <- eligible(state) do
      artifacts =
        for {target, %{outcome: :succeeded} = record} <- state.targets, into: %{} do
          response = state.responses[record.representation_id]

          {target,
           Map.merge(
             state.interpretations[target],
             Map.take(response, [:source_handle, :content_type, :url])
           )}
        end

      snapshot = %Snapshot{
        id: state.id,
        seal_token: token,
        artifacts: artifacts,
        targets: state.targets,
        edges: Map.take(state.edges, Map.keys(artifacts))
      }

      {:ok, snapshot, %{state | state: :finalizing, seal_token: token}}
    end
  end

  def artifacts(%Snapshot{} = snapshot),
    do: Enum.sort_by(snapshot.artifacts, fn {_, artifact} -> artifact.path end)

  def resolve(%Snapshot{} = snapshot, source, occurrence) do
    with %{analysis_revision: revision, path: path} <- snapshot.artifacts[source],
         true <- occurrence.source_revision === revision,
         %{target: target, url: url} <- get_in(snapshot.edges, [source, occurrence.id]),
         true <- target === occurrence.target,
         {:ok, supplied_url} <- Paths.online(occurrence.url),
         true <- supplied_url === url do
      case snapshot.artifacts[target] do
        %{path: target_path} ->
          with {:ok, relative} <- Paths.relative(path, target_path), do: {:local, relative}

        nil ->
          {:online, url}
      end
    else
      _ -> {:error, :invalid_occurrence_binding}
    end
  end

  def rendered(state, token, target, ticket) do
    with :ok <- finalizing(state, token),
         %{path: path} <- state.interpretations[target],
         %{outcome: :succeeded} <- state.targets[target],
         %{area: :archive, path: ^path, written?: true} <- state.writes[ticket],
         false <- Map.has_key?(state.rendered, target) do
      put_record(state, :rendered, target, ticket)
    else
      true -> {:error, :already_rendered}
      nil -> {:error, :unrendered_artifact}
      %{} -> {:error, :unrendered_artifact}
      error -> error
    end
  end

  def validate_commit(state, token, manifest_ticket) do
    with :ok <- finalizing(state, token),
         true <-
           Enum.all?(state.targets, fn {target, record} ->
             record.outcome != :succeeded or Map.has_key?(state.rendered, target)
           end) or {:error, :unrendered_artifact},
         true <-
           Enum.all?(state.writes, fn {_, write} -> write.written? end) or
             {:error, :pending_writes},
         %{area: :archive, path: "manifest.json", written?: true} <- state.writes[manifest_ticket] do
      :ok
    else
      nil -> {:error, :missing_public_manifest}
      %{} -> {:error, :missing_public_manifest}
      error -> error
    end
  end

  @doc "Records readiness only after owner-local filesystem promotion succeeds in this same owner transition."
  def ready(state, token, manifest_ticket) do
    with :ok <- validate_commit(state, token, manifest_ticket),
         do: {:ok, %{state | state: :ready}}
  end

  def fail(state, reason) when is_atom(reason) do
    with :ok <- active(state), do: {:ok, %{state | state: :failed, failure: reason}}
  end

  def cancel(state) do
    with :ok <- active(state), do: {:ok, %{state | state: :cancelled}}
  end

  def public_manifest(%Snapshot{} = snapshot) do
    resources =
      for {_, artifact} <- artifacts(snapshot),
          do: Map.take(artifact, [:id, :path, :content_type, :url])

    references =
      for {source, artifact} <- artifacts(snapshot),
          {_occurrence_id, edge} <-
            Enum.sort_by(Map.get(snapshot.edges, source, %{}), fn {_, edge} -> edge.index end) do
        target = snapshot.artifacts[edge.target]

        outcome =
          case snapshot.targets[edge.target] do
            nil -> :absent
            record -> record.outcome
          end

        %{
          from: artifact.id,
          edge: edge.index,
          target: if(target, do: target.id),
          outcome: outcome,
          url: edge.url
        }
      end

    %{format: 1, id: snapshot.id, resources: resources, references: references}
  end

  def status(state),
    do: %{
      id: state.id,
      state: state.state,
      reason: state.failure,
      targets: map_size(state.targets),
      artifacts: map_size(state.interpretations),
      edges: state.edge_count,
      staged_bytes: state.bytes,
      staged_files: state.files
    }

  defp edges(occurrences, revision) do
    occurrences
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {occurrence, index}, {:ok, edges} ->
      with true <-
             (not is_nil(occurrence.id) and
                (is_nil(occurrence.target) or handle?(occurrence.target))) or
               {:error, :invalid_handle},
           true <- occurrence.source_revision === revision or {:error, :source_revision_mismatch},
           false <- Map.has_key?(edges, occurrence.id),
           {:ok, url} <- Paths.online(occurrence.url) do
        {:cont,
         {:ok,
          Map.put(edges, occurrence.id, %{target: occurrence.target, url: url, index: index})}}
      else
        true -> {:halt, {:error, :duplicate_occurrence}}
        error -> {:halt, error}
      end
    end)
  end

  defp eligible(state) do
    Enum.reduce_while(state.targets, :ok, fn
      {target, %{outcome: :succeeded, representation_id: representation}}, :ok ->
        if Map.has_key?(state.responses, representation) and
             Map.has_key?(state.interpretations, target) and Map.has_key?(state.edges, target),
           do: {:cont, :ok},
           else: {:halt, {:error, :unstaged_success}}

      _, :ok ->
        {:cont, :ok}
    end)
  end

  defp payload(%{render_mode: :rewrite} = attrs) do
    if Enum.all?(
         [attrs[:analysis_revision], attrs[:analysis_handle], attrs[:occurrences_handle]],
         &handle?/1
       ) do
      {:ok,
       Map.take(attrs, [:render_mode, :analysis_revision, :analysis_handle, :occurrences_handle])}
    else
      {:error, :invalid_payload_handle}
    end
  end

  defp payload(%{render_mode: :copy}) do
    {:ok,
     %{render_mode: :copy, analysis_revision: nil, analysis_handle: nil, occurrences_handle: nil}}
  end

  defp payload(_), do: {:error, :invalid_render_mode}

  defp put_record(state, field, key, record) do
    entries = Map.fetch!(state, field)

    old =
      case Map.fetch(entries, key) do
        {:ok, value} -> charge(key, value)
        :error -> 0
      end

    bytes = state.metadata_bytes - old + charge(key, record)

    with :ok <- bound(bytes, state.limits.max_manifest_bytes, :max_manifest_bytes) do
      {:ok,
       state |> Map.put(field, Map.put(entries, key, record)) |> Map.put(:metadata_bytes, bytes)}
    end
  end

  defp charge(key, value), do: 512 + 8 * :erlang.external_size({key, value})
  defp handle?(value), do: not is_nil(value) and :erlang.external_size(value) <= 256
  defp bound(value, limit, key), do: if(value <= limit, do: :ok, else: {:error, {:limit, key}})

  defp target_record(state, target) do
    case state.targets[target] do
      nil -> {:error, :unknown_target}
      record -> {:ok, record}
    end
  end

  defp admitting(%{state: :admitting}), do: :ok
  defp admitting(_), do: {:error, :closed_export}
  defp active(%{state: state}) when state in [:admitting, :finalizing], do: :ok
  defp active(_), do: {:error, :closed_export}
  defp writable(%{state: :admitting}, area) when area in [:source, :metadata], do: :ok
  defp writable(%{state: :finalizing}, :archive), do: :ok
  defp writable(_, _), do: {:error, :closed_export}
  defp finalizing(%{state: :finalizing, seal_token: token}, token), do: :ok
  defp finalizing(_, _), do: {:error, :closed_export}
end
