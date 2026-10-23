defmodule Crawler.Frontier do
  @moduledoc false

  alias Crawler.Frontier.Index
  alias Crawler.Frontier.Ring
  alias Crawler.Job
  alias Crawler.Job.Identity
  alias Crawler.Job.Outcome
  alias Crawler.Limits

  defstruct limits: nil,
            runs: %{},
            queues: %{},
            queue_runs: %{},
            queue_jobs: %{},
            retired_queue_jobs: %{},
            wakeups: Ring.new(),
            jobs: %{},
            identities: %{},
            representations: %{},
            representation_counts: %{},
            representation_count: 0,
            claims: %{},
            pending: 0,
            metadata_bytes: 0,
            active_metadata_bytes: 0,
            payload_bytes: 0,
            limited: %{},
            stats: %{selected: 0, settled: 0, group_updates: 0, retired: 0}

  def new(opts \\ %{}), do: %__MODULE__{limits: Limits.validate!(opts)}

  def admit(
        state,
        %Job{} = job,
        %Identity{} = identity,
        %{metadata: metadata, payload: payload} = charge
      )
      when is_integer(metadata) and metadata >= 0 and is_integer(payload) and payload >= 0 do
    charge = %{charge | metadata: metadata + bookkeeping_charge(state, job, identity)}
    metadata = charge.metadata
    key = run_key(job)
    identity_key = {key, identity.representation, identity.interpretation, job.kind}
    existing = state.identities[identity_key]
    representation_key = {key, identity.representation}
    run = Map.get(state.runs, key, new_run())

    cond do
      run.retired? ->
        {:error, :stale, state}

      reusable?(state.jobs[existing]) ->
        {:existing, state.jobs[existing].job.id, state}

      Map.has_key?(state.jobs, job.id) ->
        {:error, :job_id_reused, state}

      reason =
          admission_limit(
            state,
            run,
            job,
            representation_key,
            identity.representation_class,
            charge
          ) ->
        {:limited, reason, %{state | limited: Map.update(state.limited, reason, 1, &(&1 + 1))}}

      true ->
        representation_id = state.representations[representation_key] || make_ref()

        growth =
          if identity.representation_class == :prepared and
               not Map.has_key?(state.representations, representation_key),
             do: 1,
             else: 0

        job = %{job | representation_id: representation_id, interpretation_id: make_ref()}

        record = %{
          job: job,
          status: :pending,
          charge: charge,
          outcome: nil,
          identity_key: identity_key,
          representation_key: representation_key,
          representation_class: identity.representation_class
        }

        run = %{
          run
          | pending: run.pending + 1,
            representation_count: run.representation_count + growth,
            metadata_bytes: run.metadata_bytes + metadata,
            active_metadata_bytes: run.active_metadata_bytes + metadata,
            payload_bytes: run.payload_bytes + payload,
            queue_pending: Map.update(run.queue_pending, queue(job), 1, &(&1 + 1)),
            jobs: MapSet.put(run.jobs, job.id),
            pending_order: Ring.put(run.pending_order, job.id)
        }

        run = if control?(job), do: %{run | controls: run.controls + 1}, else: run
        run = add_pending(run, job)

        state = %{
          state
          | jobs: Map.put(state.jobs, job.id, record),
            queue_jobs:
              Map.update(
                state.queue_jobs,
                queue(job),
                Ring.put(Ring.new(), job.id),
                &Ring.put(&1, job.id)
              ),
            identities: Map.put(state.identities, identity_key, job.id),
            representations:
              Map.put(state.representations, representation_key, representation_id),
            representation_counts:
              Map.update(state.representation_counts, representation_key, 1, &(&1 + 1)),
            representation_count: state.representation_count + growth,
            runs: Map.put(state.runs, key, run),
            pending: state.pending + 1,
            metadata_bytes: state.metadata_bytes + metadata,
            active_metadata_bytes: state.active_metadata_bytes + metadata,
            payload_bytes: state.payload_bytes + payload
        }

        {:accepted, job, refresh_run(state, key, queue(job))}
    end
  end

  def admit(state, %Job{}, _identity, _charge), do: {:error, :unprepared_request, state}

  def rebind(state, id, %Identity{} = identity, opts, payload \\ nil) do
    case state.jobs[id] do
      %{status: {:waiting, _}} = record ->
        job = %{record.job | opts: opts}
        key = run_key(job)
        representation_key = {key, identity.representation}

        old_identity = %Identity{
          representation: elem(record.identity_key, 1),
          interpretation: elem(record.identity_key, 2),
          representation_class: record.representation_class
        }

        delta =
          max(
            bookkeeping_charge(state, job, identity) -
              bookkeeping_charge(state, job, old_identity),
            0
          )

        payload = payload || record.charge.payload
        payload_delta = payload - record.charge.payload
        destination = state.representations[representation_key]
        old_count = state.representation_counts[record.representation_key] - 1

        growth =
          if is_nil(destination) and identity.representation_class == :prepared, do: 1, else: 0

        released =
          if old_count == 0 and record.representation_key != representation_key and
               record.representation_class == :prepared,
             do: 1,
             else: 0

        cond do
          state.representation_count + growth - released > state.limits.max_representations or
              (growth > released and
                 state.runs[key].representation_count + growth - released >
                   Map.get(opts, :max_representations, state.limits.max_representations)) ->
            {:limited, :max_representations, state}

          retained(state) + delta + payload_delta > state.limits.max_retained_bytes or
            state.active_metadata_bytes + state.payload_bytes + delta + payload_delta >
              state.limits.max_frontier_bytes or
              state.runs[key].active_metadata_bytes + state.runs[key].payload_bytes + delta +
                payload_delta >
                Map.get(opts, :max_frontier_bytes, state.limits.max_frontier_bytes) ->
            {:limited, :max_retained_bytes, state}

          true ->
            {representations, counts} =
              if old_count == 0 do
                {Map.delete(state.representations, record.representation_key),
                 Map.delete(state.representation_counts, record.representation_key)}
              else
                {state.representations,
                 Map.put(state.representation_counts, record.representation_key, old_count)}
              end

            representation = destination || make_ref()
            job = %{job | representation_id: representation}
            identity_key = {key, identity.representation, identity.interpretation, job.kind}

            identities =
              if state.identities[record.identity_key] == id,
                do: Map.delete(state.identities, record.identity_key),
                else: state.identities

            identities = Map.put_new(identities, identity_key, id)
            run = state.runs[key]

            run = %{
              run
              | representation_count: run.representation_count + growth - released,
                metadata_bytes: run.metadata_bytes + delta,
                active_metadata_bytes: run.active_metadata_bytes + delta,
                payload_bytes: run.payload_bytes + payload_delta
            }

            record = %{
              record
              | job: job,
                identity_key: identity_key,
                representation_key: representation_key,
                representation_class: identity.representation_class,
                charge: %{
                  record.charge
                  | metadata: record.charge.metadata + delta,
                    payload: payload
                }
            }

            state = %{
              state
              | jobs: Map.put(state.jobs, id, record),
                runs: Map.put(state.runs, key, run),
                identities: identities,
                representations: Map.put(representations, representation_key, representation),
                representation_counts: Map.update(counts, representation_key, 1, &(&1 + 1)),
                representation_count: state.representation_count + growth - released,
                metadata_bytes: state.metadata_bytes + delta,
                active_metadata_bytes: state.active_metadata_bytes + delta,
                payload_bytes: state.payload_bytes + payload_delta
            }

            {:ok, job, state}
        end

      _ ->
        {:error, :stale, state}
    end
  end

  def seed(state, key, completed, logical, succeeded?) do
    run = Map.get(state.runs, key, new_run())
    previous = run.groups[logical]
    run = %{run | completed: max(completed, run.completed)}
    run = if succeeded?, do: seed_succeeded(run, logical), else: run
    state = %{state | runs: Map.put(state.runs, key, run)}

    if succeeded? and match?(%{succeeded?: false}, previous),
      do: refresh_run(state, key),
      else: state
  end

  defp seed_succeeded(run, logical) do
    case run.groups[logical] do
      nil ->
        group = %{new_group() | succeeded?: true, target: :counted}
        %{run | groups: Map.put(run.groups, logical, group)}

      %{succeeded?: true} ->
        run

      group ->
        cursor = if Ring.size(group.queues) > 0, do: group.queues
        group = %{group | succeeded?: true, cursor: cursor}

        %{
          run
          | groups: Map.put(run.groups, logical, group),
            reserved: run.reserved - bool(MapSet.size(group.active) > 0),
            full_groups: Index.delete(run.full_groups, logical),
            group_tasks:
              if(cursor,
                do: Ring.put(run.group_tasks, logical),
                else: Ring.delete(run.group_tasks, logical)
              )
        }
    end
  end

  def reset_completed(state, key) do
    case state.runs[key] do
      %{retired?: false} = run ->
        refresh_run(%{state | runs: Map.put(state.runs, key, %{run | completed: 0})}, key)

      _ ->
        state
    end
  end

  def checkout(state, queue, budget \\ 64) when is_integer(budget) and budget > 0,
    do: checkout_queue(state, queue, budget, false)

  def claim_target(state, id) do
    case state.jobs[id] do
      nil ->
        {:error, :stale, state}

      record ->
        run = state.runs[run_key(record.job)]

        cond do
          is_nil(run) or run.retired? ->
            {:error, :stale, state}

          match?(%Outcome{}, record.outcome) ->
            {:terminal, record.outcome, state}

          record.status == :pending ->
            claim_pending_target(state, record, run)

          true ->
            {:waiting, state}
        end
    end
  end

  defp claim_pending_target(state, record, run) do
    job = record.job
    key = run_key(job)
    queue = queue(job)
    dir = run.dirs[queue]

    if page?(job) do
      group = run.groups[job.logical_key]
      used = logical_used(run, group)
      {ceiling, _sequence} = Map.fetch!(dir.groups[job.logical_key].entries, job.id)

      cond do
        not Map.has_key?(Map.fetch!(dir, group_target(group)).entries, job.logical_key) ->
          run = sync_group(run, job.logical_key, queue)

          {:maintenance,
           refresh_queue(%{state | runs: Map.put(state.runs, key, run)}, key, queue)}

        ceiling == :infinity or ceiling > used ->
          claim_job(state, key, queue, record, %{delete_ready(dir, job) | turn: :control})

        ceiling <= run.completed ->
          {:maintenance, state}

        true ->
          {:waiting, state}
      end
    else
      claim_job(state, key, queue, record, %{delete_ready(dir, job) | turn: :fetch})
    end
  end

  defp checkout_queue(state, _queue, 0, _changed), do: {:maintenance, state}

  defp checkout_queue(state, queue, budget, changed) do
    ring = Map.get(state.queues, queue, Ring.new())

    case Ring.take(ring) do
      :empty ->
        if changed, do: {:maintenance, state}, else: :empty

      {:ok, key, ring} ->
        run = state.runs[key]

        cond do
          is_nil(run) or run.retired? or not directory_ready?(run, run.dirs[queue]) ->
            state = %{state | queues: Map.put(state.queues, queue, ring)}
            checkout_queue(state, queue, budget - 1, true)

          true ->
            case select(run, run.dirs[queue]) do
              {:repair, group} ->
                run = sync_group(run, group, queue)

                state =
                  refresh_queue(%{state | runs: Map.put(state.runs, key, run)}, key, queue)

                checkout_queue(state, queue, budget - 1, true)

              {id, dir} ->
                state = %{state | queues: Map.put(state.queues, queue, ring)}
                claim_job(state, key, queue, state.jobs[id], dir)
            end
        end
    end
  end

  defp claim_job(state, key, queue, record, dir) do
    job = record.job
    claim = make_ref()
    run = state.runs[key]

    run = %{
      run
      | dirs: Map.put(run.dirs, queue, dir),
        pending_order: Ring.delete(run.pending_order, job.id),
        claims: Ring.put(run.claims, claim)
    }

    run = if page?(job), do: reserve_logical(run, job.logical_key, claim), else: run
    run = if page?(job), do: sync_group(run, job.logical_key, queue), else: run

    state = %{
      state
      | runs: Map.put(state.runs, key, run),
        jobs: Map.put(state.jobs, job.id, %{record | status: {:running, claim}}),
        claims:
          Map.put(state.claims, claim, %{
            id: job.id,
            run: key,
            status: :running
          }),
        stats: Map.update!(state.stats, :selected, &(&1 + 1))
    }

    {:ok, claim, job, refresh_run(state, key, queue)}
  end

  def complete(state, claim, %Outcome{} = outcome) do
    case state.claims[claim] do
      %{status: :running} = lease ->
        complete_claim(state, claim, outcome, lease)

      _ ->
        {:stale, state}
    end
  end

  defp complete_claim(state, claim, outcome, lease) do
    if state.runs[lease.run].retired? and outcome != state.runs[lease.run].retired_outcome do
      {:stale, state}
    else
      record = state.jobs[lease.id]
      run = state.runs[lease.run]
      job = record.job

      run = %{
        run
        | pending: run.pending - 1,
          queue_pending: Map.update!(run.queue_pending, queue(job), &(&1 - 1))
      }

      run = if page?(job), do: finish_logical(run, job.logical_key, claim, outcome), else: run
      run = if page?(job), do: sync_group(run, job.logical_key, queue(job)), else: run

      state = %{
        state
        | runs: Map.put(state.runs, lease.run, run),
          claims: Map.put(state.claims, claim, %{lease | status: :settled}),
          jobs: Map.put(state.jobs, lease.id, %{record | status: :settled, outcome: outcome}),
          pending: state.pending - 1
      }

      {:ok, refresh_run(state, lease.run, queue(job))}
    end
  end

  def release(state, claim) do
    case state.claims[claim] do
      %{status: :running, run: key} ->
        run = state.runs[key]

        outcome =
          if run.retired?, do: run.retired_outcome, else: Outcome.new(:cancelled, :executor_down)

        {:ok, state} = complete(state, claim, outcome)
        release(state, claim)

      %{status: :settled, id: id} ->
        record = state.jobs[id]
        record = release_payload(record)
        key = state.claims[claim].run
        run = state.runs[key]

        run = %{
          run
          | claims: Ring.delete(run.claims, claim),
            released: Ring.put(run.released, id),
            payload_bytes: run.payload_bytes - state.jobs[id].charge.payload,
            active_metadata_bytes: run.active_metadata_bytes - state.jobs[id].charge.metadata
        }

        {:ok,
         %{
           state
           | claims: Map.delete(state.claims, claim),
             jobs: Map.put(state.jobs, id, record),
             runs: Map.put(state.runs, key, run),
             payload_bytes: state.payload_bytes - state.jobs[id].charge.payload,
             active_metadata_bytes: state.active_metadata_bytes - state.jobs[id].charge.metadata
         }}

      nil ->
        {:stale, state}
    end
  end

  def wait(state, id, dependency) do
    case state.jobs[id] do
      %{status: :pending} = record ->
        key = run_key(record.job)
        run = remove_ready(state.runs[key], record.job)
        record = %{record | status: {:waiting, dependency}}

        state = %{
          state
          | jobs: Map.put(state.jobs, id, record),
            runs: Map.put(state.runs, key, run)
        }

        {:ok, refresh_run(state, key, queue(record.job))}

      _ ->
        {:error, :not_pending, state}
    end
  end

  def resume(state, id, kind \\ nil) do
    case state.jobs[id] do
      %{status: {:waiting, _}} = record ->
        key = run_key(record.job)
        job = if kind, do: %{record.job | kind: kind}, else: record.job
        run = add_pending(state.runs[key], job)

        state = %{
          state
          | jobs: Map.put(state.jobs, id, %{record | status: :pending, job: job}),
            runs: Map.put(state.runs, key, run)
        }

        {:ok, refresh_run(state, key, queue(job))}

      _ ->
        {:error, :not_waiting, state}
    end
  end

  def settle_job(state, id, %Outcome{} = outcome) do
    case state.jobs[id] do
      %{status: status} = record
      when status == :pending or (is_tuple(status) and elem(status, 0) == :waiting) ->
        key = run_key(record.job)
        state = drop_pending(state, key, id, outcome)
        {:ok, refresh_run(state, key, queue(record.job))}

      _ ->
        {:stale, state}
    end
  end

  def park_claim(state, claim, dependency) do
    case state.claims[claim] do
      %{status: :running} = lease ->
        park_active_claim(state, claim, dependency, lease)

      _ ->
        {:stale, state}
    end
  end

  defp park_active_claim(state, claim, dependency, lease) do
    record = state.jobs[lease.id]
    job = record.job
    run = state.runs[lease.run]

    run =
      if page?(job),
        do: finish_logical(run, job.logical_key, claim, Outcome.new(:cancelled)),
        else: run

    run = if page?(job), do: sync_group(run, job.logical_key, queue(job)), else: run

    run = %{
      run
      | claims: Ring.delete(run.claims, claim),
        pending_order: Ring.put(run.pending_order, job.id)
    }

    state = %{
      state
      | claims: Map.delete(state.claims, claim),
        runs: Map.put(state.runs, lease.run, run),
        jobs: Map.put(state.jobs, job.id, %{record | status: {:waiting, dependency}})
    }

    {:ok, refresh_run(state, lease.run, queue(job))}
  end

  def take_wakeups(state, batch \\ 64) when is_integer(batch) and batch > 0,
    do: take_wakeups(state, batch, [])

  def ready?(state, queue), do: Ring.size(Map.get(state.queues, queue, Ring.new())) > 0

  defp take_wakeups(state, 0, queues),
    do: {Enum.reverse(queues), Ring.size(state.wakeups) > 0, state}

  defp take_wakeups(state, remaining, queues) do
    case Ring.take(state.wakeups) do
      :empty ->
        {Enum.reverse(queues), false, state}

      {:ok, queue, ring} ->
        take_wakeups(%{state | wakeups: ring}, remaining - 1, [queue | queues])
    end
  end

  def settle_batch(state, key, batch \\ 64) when is_integer(batch) and batch > 0,
    do: settle(state, key, batch, [])

  def await_notification(state, id) do
    case state.jobs[id] do
      %{outcome: %Outcome{}} = record ->
        if Map.has_key?(record, :notification) do
          {false, state}
        else
          {true,
           %{state | jobs: Map.put(state.jobs, id, Map.put(record, :notification, :pending))}}
        end

      _ ->
        {false, state}
    end
  end

  def acknowledge_notification(state, id) do
    case state.jobs[id] do
      %{notification: :pending} = record ->
        %{state | jobs: Map.put(state.jobs, id, %{record | notification: :acknowledged})}

      _ ->
        state
    end
  end

  def retry_unsuccessful(state, target) do
    with %{status: status, outcome: %Outcome{status: ending}} = record
         when status in [:settled, :released] and ending in [:failed, :rejected] <-
           state.jobs[target],
         %{retired?: false} = run <- state.runs[run_key(record.job)],
         0 <- Map.get(run.queue_pending, queue(record.job), 0),
         ^target <- state.identities[record.identity_key] do
      %{state | identities: Map.delete(state.identities, record.identity_key)}
    else
      _ -> state
    end
  end

  def counts(state, key) do
    run = Map.get(state.runs, key, new_run())
    %{completed: run.completed, reserved: run.reserved, controls: run.controls}
  end

  def pending(state), do: state.pending

  def pending(state, key) do
    case state.runs[key] do
      nil -> 0
      run -> run.pending
    end
  end

  def queue_pending(state, key, queue) do
    case state.runs[key] do
      nil -> 0
      run -> Map.get(run.queue_pending, queue, 0)
    end
  end

  def inflight(state, key) do
    case state.runs[key] do
      nil -> 0
      run -> Ring.size(run.claims)
    end
  end

  def bytes(state),
    do: %{
      metadata: state.metadata_bytes,
      payload: state.payload_bytes
    }

  def bytes(state, key) do
    run = Map.get(state.runs, key, new_run())
    Map.take(run, [:metadata_bytes, :payload_bytes])
  end

  def outcome(state, id) do
    case state.jobs[id] do
      nil -> nil
      record -> record.outcome
    end
  end

  def run_key(%{authority: {scope, generation, _queue}}), do: {scope, generation}

  def reset_count(state, key) do
    case state.runs[key] do
      nil -> state
      run -> refresh_run(%{state | runs: Map.put(state.runs, key, %{run | completed: 0})}, key)
    end
  end

  def retire_run(state, key, outcome \\ Outcome.new(:cancelled, :run_retired), dispose? \\ true) do
    case state.runs[key] do
      nil ->
        {:retired, state}

      run ->
        run = %{
          run
          | retired?: true,
            retired_outcome: outcome,
            dispose?: dispose?,
            queue_cursor: run.queue_order
        }

        {:retired,
         %{
           state
           | runs: Map.put(state.runs, key, run),
             stats: Map.update!(state.stats, :retired, &(&1 + 1))
         }}
    end
  end

  def retire_queue(state, queue) do
    case Map.pop(state.queue_jobs, queue) do
      {nil, _} ->
        {nil, state}

      {ring, queues} ->
        token = make_ref()

        {token,
         %{
           state
           | queue_jobs: queues,
             retired_queue_jobs: Map.put(state.retired_queue_jobs, token, ring)
         }}
    end
  end

  def retire_queue_batch(state, token, batch \\ 32),
    do: retire_queue_jobs(state, token, batch, [], [])

  defp retire_queue_jobs(state, token, 0, claims, ids) do
    status =
      if Ring.size(Map.get(state.retired_queue_jobs, token, Ring.new())) == 0,
        do: :done,
        else: :more

    state =
      if status == :done,
        do: %{state | retired_queue_jobs: Map.delete(state.retired_queue_jobs, token)},
        else: state

    {status, Enum.reverse(claims), Enum.reverse(ids), state}
  end

  defp retire_queue_jobs(state, token, remaining, claims, ids) do
    case Ring.take(Map.get(state.retired_queue_jobs, token, Ring.new())) do
      :empty ->
        {:done, Enum.reverse(claims), Enum.reverse(ids),
         %{state | retired_queue_jobs: Map.delete(state.retired_queue_jobs, token)}}

      {:ok, id, ring} ->
        state = %{state | retired_queue_jobs: Map.put(state.retired_queue_jobs, token, ring)}
        outcome = Outcome.new(:cancelled, :queue_retired)

        {state, claims} = retire_queue_job(state, id, outcome, claims)

        retire_queue_jobs(state, token, remaining - 1, claims, [id | ids])
    end
  end

  defp retire_queue_job(state, id, outcome, claims) do
    case state.jobs[id] do
      %{status: {:running, claim}} ->
        case complete(state, claim, outcome) do
          {:ok, state} -> {state, [claim | claims]}
          _ -> {state, claims}
        end

      %{status: status}
      when status == :pending or (is_tuple(status) and elem(status, 0) == :waiting) ->
        {:ok, state} = settle_job(state, id, outcome)
        {state, claims}

      _ ->
        {state, claims}
    end
  end

  def retire_claims_batch(state, key, batch \\ 64) when is_integer(batch) and batch > 0 do
    case state.runs[key] do
      %{retired?: true} -> retire_claims(state, key, batch, [])
      nil -> {:done, [], state}
      _ -> {:error, :active_run, state}
    end
  end

  def maintain_batch(state, key, batch \\ 64) when is_integer(batch) and batch > 0,
    do: maintain(state, key, batch, 0)

  def dispose_batch(state, key, batch \\ 64) when is_integer(batch) and batch > 0 do
    case state.runs[key] do
      nil -> {:done, 0, state}
      %{retired?: false} -> {:error, :active_run, state}
      _run -> dispose(state, key, batch, 0)
    end
  end

  defp admission_limit(state, run, job, representation_key, representation_class, charge) do
    total = retained(state) + charge.metadata + charge.payload
    group = Map.get(run.groups, job.logical_key, new_group())

    cond do
      state.pending >= state.limits.max_pending or
          run.pending >= Map.get(job.opts, :max_pending, state.limits.max_pending) ->
        :max_pending

      state.active_metadata_bytes + state.payload_bytes + charge.metadata + charge.payload >
        state.limits.max_frontier_bytes or
          run.active_metadata_bytes + run.payload_bytes + charge.metadata + charge.payload >
            Map.get(job.opts, :max_frontier_bytes, state.limits.max_frontier_bytes) ->
        :max_frontier_bytes

      total > state.limits.max_retained_bytes ->
        :max_retained_bytes

      map_size(state.jobs) >= state.limits.max_interpretations or
          MapSet.size(run.jobs) >=
            Map.get(job.opts, :max_interpretations, state.limits.max_interpretations) ->
        :max_interpretations

      representation_class == :prepared and
        not Map.has_key?(state.representations, representation_key) and
          (state.representation_count >= state.limits.max_representations or
             run.representation_count >=
               Map.get(job.opts, :max_representations, state.limits.max_representations)) ->
        :max_representations

      not Map.has_key?(state.queues, queue(job)) and
          map_size(state.queues) >= state.limits.max_tracked_queues ->
        :max_tracked_queues

      control?(job) and
          run.controls >=
            min(
              state.limits.max_control_documents,
              Map.get(job.opts, :max_control_documents, state.limits.max_control_documents)
            ) ->
        :max_control_documents

      control?(job) and
          job.control_depth >
            min(
              state.limits.max_control_depth,
              Map.get(job.opts, :max_control_depth, state.limits.max_control_depth)
            ) ->
        :max_control_depth

      page?(job) and not group.succeeded? and is_integer(job.opts[:max_pages]) and
          job.opts[:max_pages] <= run.completed ->
        :max_pages

      true ->
        nil
    end
  end

  defp reusable?(%{status: status}) when status in [:pending, :settled], do: true
  defp reusable?(%{status: {:running, _claim}}), do: true
  defp reusable?(%{status: {:waiting, _dependency}}), do: true
  defp reusable?(%{outcome: %Outcome{}}), do: true
  defp reusable?(_record), do: false

  defp add_pending(run, job) do
    queue = queue(job)
    dir = Map.get(run.dirs, queue, new_dir())

    if page?(job) do
      group = Map.get(run.groups, job.logical_key, new_group())
      group = %{group | queues: Ring.put(group.queues, queue)}
      index = Map.get(dir.groups, job.logical_key, Index.new())
      index = Index.put(index, job.id, job.opts[:max_pages] || :infinity)
      dir = %{dir | groups: Map.put(dir.groups, job.logical_key, index)}

      run = %{
        run
        | groups: Map.put(run.groups, job.logical_key, group),
          dirs: Map.put(run.dirs, queue, dir),
          queue_order: Ring.put(run.queue_order, queue)
      }

      sync_group(run, job.logical_key, queue)
    else
      dir = %{dir | controls: Index.put(dir.controls, job.id, :infinity)}
      %{run | dirs: Map.put(run.dirs, queue, dir), queue_order: Ring.put(run.queue_order, queue)}
    end
  end

  defp select(run, dir) do
    fetch? = fetch_ready?(run, dir)
    controls? = not Index.empty?(dir.controls)

    if controls? and (dir.turn == :control or not fetch?) do
      {:ok, id, index} = Index.take(dir.controls, -1)
      {id, %{dir | controls: index, turn: :fetch}}
    else
      used = run.completed + run.reserved

      {group_key, group_used} =
        cond do
          Index.eligible?(dir.counted, -1) ->
            {elem(Index.take(dir.counted, -1), 1), -1}

          Index.eligible?(dir.reserved, used - 1) ->
            {elem(Index.take(dir.reserved, used - 1), 1), used - 1}

          true ->
            {elem(Index.take(dir.fresh, used), 1), used}
        end

      group = run.groups[group_key]

      actual_used = logical_used(run, group)

      if actual_used != group_used or not Index.eligible?(dir.groups[group_key], actual_used) do
        {:repair, group_key}
      else
        {:ok, id, index} = Index.take(dir.groups[group_key], actual_used)
        {id, %{dir | groups: Map.put(dir.groups, group_key, index), turn: :control}}
      end
    end
  end

  defp logical_used(run, group) do
    case group_target(group) do
      :counted -> -1
      :reserved -> run.completed + run.reserved - 1
      :fresh -> run.completed + run.reserved
    end
  end

  defp group_target(group) do
    cond do
      group.succeeded? -> :counted
      MapSet.size(group.active) > 0 -> :reserved
      true -> :fresh
    end
  end

  defp reserve_logical(run, key, claim) do
    group = run.groups[key]
    extra = if not group.succeeded? and MapSet.size(group.active) == 0, do: 1, else: 0
    group = %{group | active: MapSet.put(group.active, claim)}
    %{run | groups: Map.put(run.groups, key, group), reserved: run.reserved + extra}
  end

  defp finish_logical(run, key, claim, outcome) do
    group = run.groups[key]
    previously_reserved? = not group.succeeded? and MapSet.size(group.active) > 0

    succeeded? =
      group.succeeded? or
        (outcome.status == :succeeded and outcome.reason != :control_document)

    extra = if not group.succeeded? and succeeded?, do: 1, else: 0
    group = %{group | active: MapSet.delete(group.active, claim), succeeded?: succeeded?}
    reserved? = not group.succeeded? and MapSet.size(group.active) > 0
    difference = bool(reserved?) - bool(previously_reserved?)

    %{
      run
      | groups: Map.put(run.groups, key, group),
        completed: run.completed + extra,
        reserved: run.reserved + difference
    }
  end

  defp sync_group(run, key, queue) do
    group = run.groups[key]

    target = group_target(group)

    dir = run.dirs[queue]
    index = dir.groups[key]
    queues = if Index.empty?(index), do: Ring.delete(group.queues, queue), else: group.queues
    group = %{group | queues: queues}
    changed? = group.target != target
    cursor = if changed?, do: group.queues, else: group.cursor
    cursor = if cursor, do: Ring.delete(cursor, queue), else: nil
    cursor = if cursor && Ring.size(cursor) == 0, do: nil, else: cursor

    dir =
      Enum.reduce(
        [:fresh, :reserved, :counted],
        dir,
        &Map.update!(&2, &1, fn idx -> Index.delete(idx, key) end)
      )

    largest = Index.maximum(index)

    dir =
      if is_nil(largest), do: dir, else: Map.update!(dir, target, &Index.put(&1, key, largest))

    minima = Index.delete(group.minima, queue)
    minimum = Index.minimum(index)
    minima = if is_nil(minimum), do: minima, else: Index.put(minima, queue, minimum)
    group = %{group | target: target, cursor: cursor, minima: minima}
    full_groups = Index.delete(run.full_groups, key)
    minimum = Index.minimum(minima)

    full_groups =
      if not group.succeeded? and not is_nil(minimum),
        do: Index.put(full_groups, key, minimum),
        else: full_groups

    tasks = if cursor, do: Ring.put(run.group_tasks, key), else: Ring.delete(run.group_tasks, key)

    %{
      run
      | groups: Map.put(run.groups, key, group),
        dirs: Map.put(run.dirs, queue, dir),
        full_groups: full_groups,
        group_tasks: tasks
    }
  end

  defp refresh_run(state, key, queue \\ nil) do
    run = state.runs[key]
    again = run.queue_again? or not is_nil(run.queue_cursor)
    cursor = run.queue_cursor || run.queue_order

    queue =
      queue ||
        case Ring.take(run.queue_order) do
          :empty -> nil
          {:ok, first, _} -> first
        end

    cursor = if queue, do: Ring.delete(cursor, queue), else: cursor

    {cursor, again} =
      cond do
        Ring.size(cursor) > 0 ->
          {cursor, again}

        again ->
          rest = if queue, do: Ring.delete(run.queue_order, queue), else: run.queue_order
          {if(Ring.size(rest) == 0, do: nil, else: rest), false}

        true ->
          {nil, false}
      end

    state = %{
      state
      | runs: Map.put(state.runs, key, %{run | queue_cursor: cursor, queue_again?: again})
    }

    if queue, do: refresh_queue(state, key, queue), else: state
  end

  defp refresh_queue(state, key, queue) do
    run = state.runs[key]
    ring = Map.get(state.queues, queue, Ring.new())

    ring =
      if not run.retired? and directory_ready?(run, run.dirs[queue]),
        do: Ring.put(ring, key),
        else: Ring.delete(ring, key)

    owners = Map.update(state.queue_runs, queue, MapSet.new([key]), &MapSet.put(&1, key))

    %{
      state
      | queues: Map.put(state.queues, queue, ring),
        wakeups: Ring.put(state.wakeups, queue),
        queue_runs: owners,
        stats: Map.update!(state.stats, :group_updates, &(&1 + 1))
    }
  end

  defp maintain(state, key, remaining, count) do
    case state.runs[key] do
      nil ->
        {:done, count, state}

      run ->
        maintain_run(state, key, run, remaining, count)
    end
  end

  defp maintain_run(state, key, run, remaining, count) do
    cond do
      Ring.size(run.group_tasks) == 0 and is_nil(run.queue_cursor) ->
        {:done, count, state}

      remaining == 0 ->
        {:more, count, state}

      Ring.size(run.group_tasks) > 0 ->
        {:ok, group_key, _} = Ring.take(run.group_tasks)
        {:ok, queue, _} = Ring.take(run.groups[group_key].cursor)
        run = sync_group(run, group_key, queue)
        tasks = Ring.delete(run.group_tasks, group_key)
        tasks = if run.groups[group_key].cursor, do: Ring.put(tasks, group_key), else: tasks
        run = %{run | group_tasks: tasks}
        state = refresh_queue(%{state | runs: Map.put(state.runs, key, run)}, key, queue)
        maintain(state, key, remaining - 1, count + 1)

      true ->
        {:ok, queue, cursor} = Ring.take(run.queue_cursor)

        {cursor, again} =
          cond do
            Ring.size(cursor) > 0 -> {cursor, run.queue_again?}
            run.queue_again? -> {run.queue_order, false}
            true -> {nil, false}
          end

        state =
          refresh_queue(
            %{
              state
              | runs: Map.put(state.runs, key, %{run | queue_cursor: cursor, queue_again?: again})
            },
            key,
            queue
          )

        maintain(state, key, remaining - 1, count + 1)
    end
  end

  defp directory_ready?(run, dir), do: not Index.empty?(dir.controls) or fetch_ready?(run, dir)

  defp fetch_ready?(run, dir) do
    used = run.completed + run.reserved

    Index.eligible?(dir.counted, -1) or Index.eligible?(dir.reserved, used - 1) or
      Index.eligible?(dir.fresh, used)
  end

  defp settle(state, key, remaining, ids) do
    run = state.runs[key]

    next =
      cond do
        is_nil(run) ->
          :none

        run.retired? ->
          case Ring.take(run.pending_order) do
            :empty -> :none
            {:ok, id, _ring} -> {:pending, id}
          end

        true ->
          Index.first_full(run.full_groups, run.completed)
      end

    cond do
      next == :none ->
        {:done, Enum.reverse(ids), state}

      remaining == 0 ->
        {:more, Enum.reverse(ids), state}

      true ->
        id =
          case next do
            {:pending, id} ->
              id

            {:ok, group_key} ->
              {:ok, queue} = Index.first_full(run.groups[group_key].minima, run.completed)
              {:ok, id} = Index.first_full(run.dirs[queue].groups[group_key], run.completed)
              id
          end

        outcome =
          if run.retired?,
            do: run.retired_outcome,
            else: Outcome.limited(:max_pages)

        state = drop_pending(state, key, id, outcome)
        settle(refresh_run(state, key, queue(state.jobs[id].job)), key, remaining - 1, [id | ids])
    end
  end

  defp release_payload(record) do
    job =
      struct!(
        Job,
        Map.take(record.job, [
          :id,
          :kind,
          :authority,
          :logical_id,
          :logical_key,
          :representation_id,
          :interpretation_id,
          :source_revision,
          :control_depth
        ])
      )

    %{record | job: job, status: :released, charge: %{record.charge | payload: 0}}
  end

  defp new_run do
    %{
      pending: 0,
      representation_count: 0,
      metadata_bytes: 0,
      active_metadata_bytes: 0,
      payload_bytes: 0,
      queue_pending: %{},
      jobs: MapSet.new(),
      pending_order: Ring.new(),
      released: Ring.new(),
      claims: Ring.new(),
      groups: %{},
      dirs: %{},
      queue_order: Ring.new(),
      queue_cursor: nil,
      queue_again?: false,
      group_tasks: Ring.new(),
      full_groups: Index.new(),
      completed: 0,
      reserved: 0,
      controls: 0,
      retired?: false,
      dispose?: true,
      retired_outcome: Outcome.new(:cancelled, :run_retired)
    }
  end

  defp new_group,
    do: %{
      active: MapSet.new(),
      succeeded?: false,
      queues: Ring.new(),
      cursor: nil,
      target: :fresh,
      minima: Index.new()
    }

  defp new_dir do
    %{
      groups: %{},
      fresh: Index.new(),
      reserved: Index.new(),
      counted: Index.new(),
      controls: Index.new(),
      turn: :fetch
    }
  end

  defp page?(job), do: job.kind == :fetch and job.opts[:count_page] != false
  defp control?(job), do: job.kind in [:robots, :sitemap]
  defp queue(%{authority: {_scope, _generation, queue}}), do: queue
  defp bool(true), do: 1
  defp bool(false), do: 0

  defp bookkeeping_charge(state, job, identity) do
    slots = max(state.limits.max_interpretations, state.limits.max_tracked_queues)
    levels = slots |> Integer.digits(2) |> length()
    8192 + 512 * levels + 8 * :erlang.external_size({job.logical_key, job.authority, identity})
  end

  defp retained(state),
    do: state.metadata_bytes + state.payload_bytes

  defp drop_pending(state, key, id, outcome) do
    record = state.jobs[id]
    run = state.runs[key]
    job = record.job
    run = if record.status == :pending, do: remove_ready(run, job), else: run

    run = %{
      run
      | pending: run.pending - 1,
        payload_bytes: run.payload_bytes - record.charge.payload,
        active_metadata_bytes: run.active_metadata_bytes - record.charge.metadata,
        queue_pending: Map.update!(run.queue_pending, queue(job), &(&1 - 1)),
        pending_order: Ring.delete(run.pending_order, id),
        released: Ring.put(run.released, id)
    }

    record = release_payload(%{record | status: :settled, outcome: outcome})

    %{
      state
      | runs: Map.put(state.runs, key, run),
        jobs: Map.put(state.jobs, id, record),
        pending: state.pending - 1,
        payload_bytes: state.payload_bytes - state.jobs[id].charge.payload,
        active_metadata_bytes: state.active_metadata_bytes - state.jobs[id].charge.metadata,
        stats: Map.update!(state.stats, :settled, &(&1 + 1))
    }
  end

  defp remove_ready(run, job) do
    queue = queue(job)
    dir = run.dirs[queue]

    run = %{run | dirs: Map.put(run.dirs, queue, delete_ready(dir, job))}
    if page?(job), do: sync_group(run, job.logical_key, queue), else: run
  end

  defp delete_ready(dir, job) do
    if page?(job),
      do: %{dir | groups: Map.update!(dir.groups, job.logical_key, &Index.delete(&1, job.id))},
      else: %{dir | controls: Index.delete(dir.controls, job.id)}
  end

  defp dispose(state, key, remaining, count) do
    run = state.runs[key]

    cond do
      MapSet.size(run.jobs) == 0 ->
        forget_run_batch(state, key, remaining, count)

      remaining == 0 ->
        {:more, count, state}

      true ->
        case Ring.take(run.released) do
          :empty ->
            {:waiting, count, state}

          {:ok, id, released} ->
            dispose_released(state, key, run, id, released, remaining, count)
        end
    end
  end

  defp dispose_released(state, key, run, id, released, remaining, count) do
    record = state.jobs[id]

    if Map.get(record, :notification) == :pending do
      run = %{run | released: Ring.put(released, id)}
      state = %{state | runs: Map.put(state.runs, key, run)}
      dispose(state, key, remaining - 1, count)
    else
      identities =
        if state.identities[record.identity_key] == id,
          do: Map.delete(state.identities, record.identity_key),
          else: state.identities

      references = state.representation_counts[record.representation_key] - 1

      {representations, reference_counts} =
        if references == 0,
          do:
            {Map.delete(state.representations, record.representation_key),
             Map.delete(state.representation_counts, record.representation_key)},
          else:
            {state.representations,
             Map.put(state.representation_counts, record.representation_key, references)}

      released_count =
        if references == 0 and record.representation_class == :prepared, do: 1, else: 0

      run = %{
        run
        | jobs: MapSet.delete(run.jobs, id),
          representation_count: run.representation_count - released_count,
          released: released,
          metadata_bytes: run.metadata_bytes - record.charge.metadata
      }

      state = %{
        state
        | runs: Map.put(state.runs, key, run),
          jobs: Map.delete(state.jobs, id),
          queue_jobs: delete_queue_job(state.queue_jobs, queue(record.job), id),
          identities: identities,
          representations: representations,
          representation_counts: reference_counts,
          representation_count: state.representation_count - released_count,
          metadata_bytes: state.metadata_bytes - record.charge.metadata
      }

      dispose(state, key, remaining - 1, count + 1)
    end
  end

  defp forget_run_batch(state, key, remaining, count) do
    run = state.runs[key]

    case Ring.take(run.queue_order) do
      :empty ->
        {:done, count, %{state | runs: Map.delete(state.runs, key)}}

      _ when remaining == 0 ->
        {:more, count, state}

      {:ok, queue, order} ->
        owners = MapSet.delete(Map.get(state.queue_runs, queue, MapSet.new()), key)
        ring = Map.get(state.queues, queue, Ring.new()) |> Ring.delete(key)

        {queues, owners} =
          if MapSet.size(owners) == 0,
            do: {Map.delete(state.queues, queue), Map.delete(state.queue_runs, queue)},
            else: {Map.put(state.queues, queue, ring), Map.put(state.queue_runs, queue, owners)}

        state = %{
          state
          | runs: Map.put(state.runs, key, %{run | queue_order: order}),
            queues: queues,
            queue_runs: owners
        }

        forget_run_batch(state, key, remaining - 1, count + 1)
    end
  end

  defp delete_queue_job(queues, queue, id) do
    ring = Ring.delete(Map.get(queues, queue, Ring.new()), id)
    if Ring.size(ring) == 0, do: Map.delete(queues, queue), else: Map.put(queues, queue, ring)
  end

  defp retire_claims(state, key, remaining, claims) do
    run = state.runs[key]

    case Ring.take(run.claims) do
      :empty ->
        {:done, Enum.reverse(claims), state}

      _ when remaining == 0 ->
        {:more, Enum.reverse(claims), state}

      {:ok, claim, ring} ->
        state = %{state | runs: Map.put(state.runs, key, %{run | claims: ring})}

        case complete(state, claim, run.retired_outcome) do
          {:ok, state} -> retire_claims(state, key, remaining - 1, [claim | claims])
          {:stale, state} -> retire_claims(state, key, remaining - 1, claims)
        end
    end
  end
end
