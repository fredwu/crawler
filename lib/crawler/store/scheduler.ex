defmodule Crawler.Store.Scheduler do
  @moduledoc false

  alias Crawler.Frontier
  alias Crawler.Frontier.Index
  alias Crawler.Frontier.Ring
  alias Crawler.Job
  alias Crawler.Job.Identity
  alias Crawler.Store.Retained
  alias Crawler.URL

  defstruct frontier: nil,
            representations: %{},
            run_representations: %{},
            initial_sources: %{},
            forks: Ring.new(),
            runs: %{},
            maintenance: Ring.new(),
            capacity: Index.new(),
            claims: %{},
            outcomes: Ring.new(),
            notifications: Ring.new(),
            notification_runs: %{}

  def new, do: %__MODULE__{frontier: Frontier.new()}

  def mark_processed(scheduler, key, logical, completed) do
    case scheduler.frontier.runs[key] do
      %{retired?: false, groups: groups} when is_map_key(groups, logical) ->
        frontier = Frontier.seed(scheduler.frontier, key, completed, logical, true)
        schedule(%{scheduler | frontier: frontier}, key)

      _ ->
        scheduler
    end
  end

  def reset_completed(scheduler) do
    Enum.reduce(scheduler.runs, scheduler, fn {key, _queues}, scheduler ->
      frontier = Frontier.reset_completed(scheduler.frontier, key)
      schedule(%{scheduler | frontier: frontier}, key)
    end)
  end

  def admit(scheduler, opts, prepared, kind \\ :fetch, ingress \\ :reference) do
    key = {opts[:scope], opts[:generation]}

    representation =
      if prepared,
        do: request_identity(scheduler, opts, prepared),
        else: {:intent, kind, make_ref()}

    identity = %Identity{
      representation: representation,
      representation_class: if(prepared, do: :prepared, else: :provisional),
      interpretation: {URL.canonical(opts.url), interpretation(opts)}
    }

    with {:ok, payload} <- Retained.bytes({opts, prepared}, opts.max_frontier_bytes) do
      scheduler = retry_root(scheduler, key, identity, kind, ingress)

      job =
        Job.new(kind, {opts[:scope], opts[:generation], opts[:queue]}, %{
          logical_key: URL.canonical(opts.url),
          prepared_request: prepared,
          deadline: opts[:run_deadline],
          control_depth: opts[:control_depth] || 0,
          opts: opts
        })

      case Frontier.admit(scheduler.frontier, job, identity, %{metadata: 0, payload: payload}) do
        {:accepted, job, frontier} ->
          accept(scheduler, job, frontier, key, identity, prepared, opts)

        {:existing, handle, frontier} ->
          {:existing, handle, %{scheduler | frontier: frontier}}

        {:limited, reason, frontier} ->
          {:limited, reason, %{scheduler | frontier: frontier}}

        {:error, reason, frontier} ->
          {:error, reason, %{scheduler | frontier: frontier}}
      end
    else
      {:error, {:limit, _}} -> {:limited, :max_frontier_bytes, scheduler}
    end
  end

  defp accept(scheduler, job, frontier, key, identity, prepared, opts) do
    representations = scheduler.representations
    representation = Map.get(representations, job.representation_id)

    scheduler = %{
      scheduler
      | frontier: frontier,
        runs:
          Map.update(
            scheduler.runs,
            key,
            MapSet.new([elem(job.authority, 2)]),
            &MapSet.put(&1, opts[:queue])
          )
    }

    scheduler =
      case representation do
        nil ->
          value = %{
            owner: job.id,
            status: :pending,
            waiting: Ring.new(),
            source: nil,
            terminal_reuse: nil,
            terminal_outcome: nil,
            attempted?: false,
            identity: identity.representation,
            initial: if(prepared, do: prepared.equivalence)
          }

          index =
            Map.update(
              scheduler.run_representations,
              key,
              Ring.put(Ring.new(), job.representation_id),
              &Ring.put(&1, job.representation_id)
            )

          %{
            scheduler
            | representations: Map.put(representations, job.representation_id, value),
              run_representations: index
          }

        %{status: :ready} ->
          {:ok, frontier} =
            Frontier.wait(frontier, job.id, {:representation, job.representation_id})

          {:ok, frontier} = Frontier.resume(frontier, job.id)
          %{scheduler | frontier: frontier}

        %{status: {:terminal, _}} ->
          {:ok, frontier} =
            Frontier.wait(frontier, job.id, {:representation, job.representation_id})

          {:ok, frontier} = Frontier.resume(frontier, job.id)
          %{scheduler | frontier: frontier}

        value ->
          {:ok, frontier} =
            Frontier.wait(frontier, job.id, {:representation, job.representation_id})

          value = %{value | waiting: Ring.put(value.waiting, job.id)}

          %{
            scheduler
            | frontier: frontier,
              representations: Map.put(representations, job.representation_id, value),
              outcomes: wake_waiters(scheduler.outcomes, job.representation_id, value)
          }
      end

    {:accepted, job.id, schedule(scheduler, key)}
  end

  def take_fork(scheduler) do
    case Ring.take(scheduler.forks) do
      :empty -> :empty
      {:ok, id, ring} -> {:ok, id, %{scheduler | forks: ring}}
    end
  end

  defp retry_root(scheduler, key, identity, kind, :root) do
    with %{retired?: false} <- scheduler.frontier.runs[key],
         0 <- Frontier.pending(scheduler.frontier, key),
         0 <- Frontier.inflight(scheduler.frontier, key),
         0 <- Map.get(scheduler.notification_runs, key, 0) do
      retry_root_identity(scheduler, key, identity, kind)
    else
      _ -> scheduler
    end
  end

  defp retry_root(scheduler, _key, _identity, _kind, _ingress), do: scheduler

  defp retry_root_identity(scheduler, key, identity, kind) do
    case scheduler.frontier.identities[
           {key, identity.representation, identity.interpretation, kind}
         ] do
      nil ->
        retry_root_representation(scheduler, key, identity, kind)

      target ->
        frontier = Frontier.retry_unsuccessful(scheduler.frontier, target)

        if frontier == scheduler.frontier,
          do: scheduler,
          else:
            retry_representation(
              %{scheduler | frontier: frontier},
              scheduler.frontier.jobs[target].job.representation_id
            )
    end
  end

  defp retry_root_representation(scheduler, key, identity, kind) do
    logical = elem(identity.interpretation, 0)

    with representation when is_reference(representation) <-
           scheduler.frontier.representations[{key, identity.representation}],
         %{owner: owner} <- scheduler.representations[representation],
         %{job: %{kind: ^kind, logical_key: ^logical}, outcome: %{status: ending}}
         when ending in [:failed, :rejected] <- scheduler.frontier.jobs[owner] do
      retry_representation(scheduler, representation)
    else
      _ -> scheduler
    end
  end

  defp retry_representation(scheduler, representation) do
    case scheduler.representations[representation] do
      %{status: :ready} -> scheduler
      _ -> invalidate(scheduler, representation)
    end
  end

  def prepare_control(scheduler, claim, prepared, opts, payload) do
    with %{job: id} <- scheduler.claims[claim],
         %{job: %{kind: :sitemap, prepared_request: nil}} <- scheduler.frontier.jobs[id],
         {:ok, frontier} <- Frontier.park_claim(scheduler.frontier, claim, :request_preparation) do
      scheduler = %{scheduler | frontier: frontier, claims: Map.delete(scheduler.claims, claim)}
      representation = request_identity(scheduler, opts, prepared)
      rebind_prepared(scheduler, id, prepared, opts, representation, payload)
    else
      _ -> scheduler
    end
  end

  def reattempt(scheduler, id, proof) do
    case scheduler.frontier.jobs[id] do
      %{
        job: %{prepared_request: %Crawler.Fetcher.Requester.PreparedRequest{}} = job,
        status: {:waiting, _}
      } ->
        prepared = Crawler.Fetcher.Requester.bind_cookie_proof(job.prepared_request, proof)
        opts = Map.put(job.opts, :cookie_proof, proof)
        representation = {prepared.equivalence, proof}

        representation =
          if scheduler.representations[job.representation_id].identity == representation,
            do: {representation, make_ref()},
            else: representation

        rebind_prepared(scheduler, id, prepared, opts, representation, nil)

      _ ->
        scheduler
    end
  end

  defp rebind_prepared(scheduler, id, prepared, opts, representation, payload) do
    identity = %Identity{
      representation: representation,
      interpretation: {URL.canonical(opts.url), interpretation(opts)}
    }

    case Frontier.rebind(scheduler.frontier, id, identity, opts, payload) do
      {:ok, job, frontier} ->
        scheduler = drop_rebound_intent(scheduler, frontier, id)
        job = %{job | prepared_request: prepared}
        record = %{frontier.jobs[id] | job: job}
        frontier = %{frontier | jobs: Map.put(frontier.jobs, id, record)}
        key = Frontier.run_key(job)
        existing = scheduler.representations[job.representation_id]

        {value, frontier} =
          case existing do
            nil ->
              {:ok, frontier} = Frontier.resume(frontier, id)

              {%{
                 owner: id,
                 status: :pending,
                 waiting: Ring.new(),
                 source: nil,
                 terminal_reuse: nil,
                 terminal_outcome: nil,
                 attempted?: false,
                 identity: representation,
                 initial: prepared.equivalence
               }, frontier}

            %{status: :ready} = value ->
              {:ok, frontier} = Frontier.resume(frontier, id)
              {value, frontier}

            %{status: {:terminal, _}} = value ->
              {:ok, frontier} = Frontier.resume(frontier, id)
              {value, frontier}

            value ->
              {%{value | waiting: Ring.put(value.waiting, id)}, frontier}
          end

        index =
          Map.update(
            scheduler.run_representations,
            key,
            Ring.put(Ring.new(), job.representation_id),
            &Ring.put(&1, job.representation_id)
          )

        schedule(
          %{
            scheduler
            | frontier: frontier,
              representations: Map.put(scheduler.representations, job.representation_id, value),
              run_representations: index,
              outcomes: wake_waiters(scheduler.outcomes, job.representation_id, value)
          },
          key
        )

      {:limited, key, frontier} ->
        {:ok, frontier} = Frontier.settle_job(frontier, id, Crawler.Job.Outcome.limited(key))

        observe_terminal(%{scheduler | frontier: frontier}, id)

      _ ->
        scheduler
    end
  end

  defp request_identity(scheduler, opts, prepared) do
    key = {opts[:scope], opts[:generation]}

    case scheduler.representations[scheduler.initial_sources[{key, prepared.equivalence}]] do
      %{status: :ready, identity: identity} ->
        identity

      %{status: {:terminal, _}, terminal_reuse: %{dependency: :initial}, identity: identity} ->
        identity

      _ ->
        {prepared.equivalence, opts[:cookie_proof]}
    end
  end

  defp drop_rebound_intent(scheduler, frontier, target) do
    old = scheduler.frontier.jobs[target]
    id = old.job.representation_id
    value = scheduler.representations[id]

    if is_nil(value.source) and map_size(Map.get(value, :custom_storage, %{})) == 0 and
         not Map.has_key?(frontier.representations, old.representation_key) do
      key = Frontier.run_key(old.job)
      index = Ring.delete(scheduler.run_representations[key], id)
      initial = {key, value.initial}

      %{
        scheduler
        | representations: Map.delete(scheduler.representations, id),
          run_representations: Map.put(scheduler.run_representations, key, index),
          initial_sources:
            if(scheduler.initial_sources[initial] == id,
              do: Map.delete(scheduler.initial_sources, initial),
              else: scheduler.initial_sources
            ),
          outcomes: Ring.delete(scheduler.outcomes, id)
      }
    else
      scheduler
    end
  end

  def retire(
        scheduler,
        key,
        outcome \\ Crawler.Job.Outcome.new(:cancelled, :run_retired),
        dispose? \\ true
      ) do
    {:retired, frontier} = Frontier.retire_run(scheduler.frontier, key, outcome, dispose?)
    %{scheduler | frontier: frontier, maintenance: Ring.delete(scheduler.maintenance, key)}
  end

  def take_retired_source(scheduler, key) do
    ring = Map.get(scheduler.run_representations, key, Ring.new())

    case Ring.take(ring) do
      :empty ->
        {:empty,
         %{
           scheduler
           | run_representations: Map.delete(scheduler.run_representations, key),
             runs: Map.delete(scheduler.runs, key)
         }}

      {:ok, id, ring} ->
        record = scheduler.representations[id]
        markers = if record, do: Map.get(record, :custom_storage, %{}), else: %{}

        case :maps.next(:maps.iterator(markers)) do
          :none ->
            take_retired_representation(scheduler, key, id, ring, record)

          {marker_key, marker, _iterator} ->
            record = Map.put(record, :custom_storage, Map.delete(markers, marker_key))

            scheduler = %{
              scheduler
              | representations: Map.put(scheduler.representations, id, record),
                run_representations:
                  Map.put(scheduler.run_representations, key, Ring.put(ring, id))
            }

            {:marker, Map.merge(marker, %{representation: id, key: marker_key}), scheduler}
        end
    end
  end

  defp take_retired_representation(scheduler, key, id, ring, record) do
    source = if record, do: record.source

    initial =
      if record && record.initial && scheduler.initial_sources[{key, record.initial}] == id,
        do: Map.delete(scheduler.initial_sources, {key, record.initial}),
        else: scheduler.initial_sources

    scheduler = %{
      scheduler
      | representations: Map.delete(scheduler.representations, id),
        initial_sources: initial,
        run_representations: Map.put(scheduler.run_representations, key, ring),
        outcomes: Ring.delete(scheduler.outcomes, id)
    }

    {:ok, source, scheduler}
  end

  def checkout(scheduler, queue) do
    case Frontier.checkout(scheduler.frontier, queue) do
      {:ok, claim, job, frontier} -> claimed(scheduler, claim, job, frontier)
      {:maintenance, frontier} -> {:maintenance, %{scheduler | frontier: frontier}}
      :empty -> :empty
    end
  end

  def claim_target(scheduler, target) do
    case Frontier.claim_target(scheduler.frontier, target) do
      {:ok, claim, job, frontier} -> claimed(scheduler, claim, job, frontier)
      {:waiting, frontier} -> {:waiting, %{scheduler | frontier: frontier}}
      {:terminal, outcome, frontier} -> {:terminal, outcome, %{scheduler | frontier: frontier}}
      {:maintenance, frontier} -> {:maintenance, %{scheduler | frontier: frontier}}
      {:error, reason, frontier} -> {:error, reason, %{scheduler | frontier: frontier}}
    end
  end

  def take_notification(scheduler) do
    case Ring.take(scheduler.notifications) do
      :empty ->
        :empty

      {:ok, target, ring} ->
        key = Frontier.run_key(scheduler.frontier.jobs[target].job)
        count = Map.fetch!(scheduler.notification_runs, key) - 1

        runs =
          if count == 0,
            do: Map.delete(scheduler.notification_runs, key),
            else: Map.put(scheduler.notification_runs, key, count)

        frontier = Frontier.acknowledge_notification(scheduler.frontier, target)

        {:ok, target,
         %{scheduler | notifications: ring, frontier: frontier, notification_runs: runs}}
    end
  end

  def requeue_notification(scheduler, target) do
    if Map.has_key?(scheduler.notifications.members, target) do
      scheduler
    else
      key = Frontier.run_key(scheduler.frontier.jobs[target].job)

      %{
        scheduler
        | notifications: Ring.put(scheduler.notifications, target),
          notification_runs: Map.update(scheduler.notification_runs, key, 1, &(&1 + 1))
      }
    end
  end

  defp claimed(scheduler, claim, job, frontier) do
    mode =
      case scheduler.representations[job.representation_id] do
        %{status: :ready} -> :interpret
        %{status: {:terminal, _}} -> :terminal
        _ -> :fetch
      end

    value = %{job: job.id, representation: job.representation_id, run: Frontier.run_key(job)}

    scheduler = %{
      scheduler
      | frontier: frontier,
        claims: Map.put(scheduler.claims, claim, value)
    }

    {:ok, claim, mode, job, schedule(scheduler, value.run)}
  end

  def publish(scheduler, claim, source) do
    case scheduler.claims[claim] do
      %{representation: representation, job: owner} ->
        case scheduler.representations[representation] do
          %{owner: ^owner} = value ->
            publish_source(scheduler, claim, source, representation, value)

          _ ->
            {:error, :not_response_owner, scheduler}
        end

      _ ->
        {:error, :stale, scheduler}
    end
  end

  defp publish_source(scheduler, claim, source, representation, value) do
    private? = source.reuse.disposition == :private

    value = %{
      value
      | status: if(private?, do: :private, else: :ready),
        source: if(private?, do: nil, else: source)
    }

    initial =
      if not private? and source.reuse.dependency == :initial,
        do:
          Map.put(
            scheduler.initial_sources,
            {scheduler.claims[claim].run, value.initial},
            representation
          ),
        else: scheduler.initial_sources

    {:ok,
     %{
       scheduler
       | representations: Map.put(scheduler.representations, representation, value),
         outcomes: Ring.put(scheduler.outcomes, representation),
         initial_sources: initial
     }}
  end

  def invalidate(scheduler, representation) do
    case scheduler.representations[representation] do
      nil ->
        scheduler

      value ->
        %{
          scheduler
          | representations:
              Map.put(scheduler.representations, representation, %{value | status: :private}),
            outcomes: Ring.put(scheduler.outcomes, representation)
        }
    end
  end

  def park(scheduler, claim, dependency \\ :cookie_proof) do
    case Frontier.park_claim(scheduler.frontier, claim, dependency) do
      {:ok, frontier} ->
        value = scheduler.claims[claim]

        %{
          scheduler
          | frontier: frontier,
            claims: Map.delete(scheduler.claims, claim),
            forks:
              if(dependency == :direct_retry,
                do: scheduler.forks,
                else: Ring.put(scheduler.forks, value.job)
              )
        }

      _ ->
        scheduler
    end
  end

  def response(scheduler, representation) do
    case scheduler.representations[representation] do
      %{status: :ready, source: source} -> {:ok, source}
      _ -> {:error, :response_unavailable}
    end
  end

  def note_response(scheduler, claim, reuse) do
    with %{representation: id, job: owner} <- scheduler.claims[claim],
         %{owner: ^owner, status: :pending} = value <- scheduler.representations[id] do
      %{
        scheduler
        | representations:
            Map.put(scheduler.representations, id, %{
              value
              | terminal_reuse: reuse,
                terminal_outcome: nil,
                attempted?: true
            })
      }
    else
      _ -> scheduler
    end
  end

  def note_request_result(scheduler, claim, outcome) do
    with %{representation: id, job: owner} <- scheduler.claims[claim],
         %{owner: ^owner, status: :pending} = value <- scheduler.representations[id] do
      terminal = if match?(%{disposition: :candidate}, value.terminal_reuse), do: outcome

      %{
        scheduler
        | representations:
            Map.put(scheduler.representations, id, %{value | terminal_outcome: terminal})
      }
    else
      _ -> scheduler
    end
  end

  def terminal(scheduler, representation) do
    case scheduler.representations[representation] do
      %{status: {:terminal, outcome}, terminal_reuse: reuse} -> {:ok, outcome, reuse}
      _ -> {:error, :response_unavailable}
    end
  end

  def complete(scheduler, claim, outcome, origin \\ :completion) do
    case scheduler.claims[claim] do
      nil ->
        {:stale, scheduler}

      value ->
        case Frontier.complete(scheduler.frontier, claim, outcome) do
          {:ok, frontier} ->
            scheduler =
              observe_terminal(%{scheduler | frontier: frontier}, value.job, origin)

            {:ok, schedule(scheduler, value.run)}

          {:stale, frontier} ->
            {:stale, %{scheduler | frontier: frontier}}
        end
    end
  end

  def observe_terminal(scheduler, id, origin \\ :external) do
    case scheduler.frontier.jobs[id] do
      %{job: job, outcome: %Crawler.Job.Outcome{} = outcome} ->
        {notify?, frontier} = Frontier.await_notification(scheduler.frontier, id)

        scheduler = %{
          scheduler
          | frontier: frontier,
            notifications: scheduler.notifications
        }

        scheduler = if notify?, do: requeue_notification(scheduler, id), else: scheduler

        case scheduler.representations[job.representation_id] do
          %{owner: ^id, status: :pending} = representation ->
            status =
              cond do
                origin == :completion and outcome == representation.terminal_outcome and
                    match?(%{disposition: :candidate}, representation.terminal_reuse) ->
                  {:terminal, outcome}

                not representation.attempted? and
                    not match?(%{disposition: :private}, representation.terminal_reuse) ->
                  :vacant

                true ->
                  :private
              end

            representation = %{
              representation
              | status: status,
                attempted?: if(status == :vacant, do: false, else: representation.attempted?),
                terminal_reuse:
                  if(status == :vacant, do: nil, else: representation.terminal_reuse),
                terminal_outcome:
                  if(status == :vacant, do: nil, else: representation.terminal_outcome)
            }

            key = Frontier.run_key(job)

            schedule(
              %{
                scheduler
                | representations:
                    Map.put(scheduler.representations, job.representation_id, representation),
                  outcomes: Ring.put(scheduler.outcomes, job.representation_id),
                  initial_sources:
                    if(
                      match?({:terminal, _}, status) and
                        match?(%{dependency: :initial}, representation.terminal_reuse),
                      do:
                        Map.put(
                          scheduler.initial_sources,
                          {key, representation.initial},
                          job.representation_id
                        ),
                      else: scheduler.initial_sources
                    )
              },
              key
            )

          _ ->
            scheduler
        end

      _ ->
        scheduler
    end
  end

  def release(scheduler, claim) do
    case scheduler.claims[claim] do
      nil ->
        scheduler

      value ->
        case Frontier.release(scheduler.frontier, claim) do
          {:ok, frontier} ->
            release_claim(scheduler, claim, value, frontier)

          {:stale, frontier} ->
            %{scheduler | frontier: frontier, claims: Map.delete(scheduler.claims, claim)}
        end
    end
  end

  defp release_claim(scheduler, claim, value, frontier) do
    scheduler = %{
      scheduler
      | frontier: frontier,
        claims: Map.delete(scheduler.claims, claim)
    }

    scheduler =
      case scheduler.representations[value.representation] do
        %{owner: owner, status: :pending} = representation when owner == value.job ->
          %{
            scheduler
            | representations:
                Map.put(scheduler.representations, value.representation, %{
                  representation
                  | attempted?: true
                })
          }

        _ ->
          scheduler
      end

    scheduler
    |> observe_terminal(value.job, :local)
    |> schedule(value.run)
  end

  def maintenance(scheduler, batch \\ 64), do: maintain(scheduler, batch, 0)
  defp maintain(scheduler, 0, count), do: {:more, count, scheduler}

  defp maintain(scheduler, remaining, count) do
    case Ring.take(scheduler.outcomes) do
      {:ok, representation, ring} ->
        maintain_outcome(scheduler, representation, ring, remaining, count)

      :empty ->
        maintain_run(scheduler, remaining, count)
    end
  end

  defp maintain_run(scheduler, remaining, count) do
    case Ring.take(scheduler.maintenance) do
      :empty ->
        {:done, count, scheduler}

      {:ok, key, ring} ->
        scheduler = %{scheduler | maintenance: ring}
        {status, _, frontier} = Frontier.maintain_batch(scheduler.frontier, key, 1)
        {settled, ids, frontier} = Frontier.settle_batch(frontier, key, 1)

        scheduler =
          Enum.reduce(ids, %{scheduler | frontier: frontier}, &observe_terminal(&2, &1))

        scheduler =
          if status == :more or settled == :more,
            do: schedule(scheduler, key),
            else: scheduler

        maintain(scheduler, remaining - 1, count + 1)
    end
  end

  defp maintain_outcome(scheduler, representation, ring, remaining, count) do
    scheduler = %{scheduler | outcomes: ring}
    value = scheduler.representations[representation]

    case if(value, do: Ring.take(value.waiting), else: :empty) do
      :empty ->
        maintain(scheduler, remaining - 1, count + 1)

      {:ok, id, waiting} ->
        result =
          case value.status do
            :private -> {:ok, scheduler.frontier}
            _ -> Frontier.resume(scheduler.frontier, id)
          end

        frontier = elem(result, tuple_size(result) - 1)

        live? =
          match?({:ok, _}, result) and
            match?(%{outcome: nil}, frontier.jobs[id]) and
            not frontier.runs[Frontier.run_key(frontier.jobs[id].job)].retired?

        transferred? = value.status == :vacant and live?

        value =
          if transferred?,
            do: %{value | owner: id, status: :pending, waiting: waiting},
            else: %{value | waiting: waiting}

        scheduler = %{
          scheduler
          | frontier: frontier,
            representations: Map.put(scheduler.representations, representation, value),
            outcomes: if(transferred?, do: ring, else: Ring.put(ring, representation)),
            forks:
              if(value.status == :private and live?,
                do: Ring.put(scheduler.forks, id),
                else: scheduler.forks
              )
        }

        maintain(scheduler, remaining - 1, count + 1)
    end
  end

  defp wake_waiters(outcomes, representation, %{status: status})
       when status in [:private, :vacant],
       do: Ring.put(outcomes, representation)

  defp wake_waiters(outcomes, _representation, _value), do: outcomes

  defp schedule(scheduler, key),
    do: %{scheduler | maintenance: Ring.put(scheduler.maintenance, key)}

  defp interpretation(opts) do
    Map.drop(opts, [
      :target_handle,
      :source_revision,
      :body_resource,
      :page_resource,
      :css_obligation_receipt,
      :cookie_proof,
      :scheduler_claim,
      :url,
      :scope,
      :generation,
      :queue,
      :queue_owner,
      :queue_name,
      :force,
      :execution_lease,
      :crawler_deadline,
      :run_deadline,
      :deadline,
      :modifier,
      :req_options,
      :user_agent,
      :site,
      :credentials,
      :cookie_site,
      :cookie_navigation,
      :retrier,
      :workers,
      :interval,
      :timeout,
      :attempt_timeout,
      :run_timeout
    ])
  end
end
