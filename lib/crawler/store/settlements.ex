defmodule Crawler.Store.Settlements do
  @moduledoc false

  alias Crawler.Store.Aliases
  alias Crawler.Store.DB
  alias Crawler.Store.Page
  alias Crawler.Store.ResourceManager
  alias Crawler.Store.State

  defmodule Candidate do
    @moduledoc false
    defstruct [
      :key,
      :source_ref,
      :source_key,
      :worker,
      :queue,
      :target_queue,
      :target_handle,
      :generation,
      :body,
      :opts,
      resources: [],
      source_done?: false,
      status: :waiting
    ]
  end

  @bookkeeping_bytes 4_096

  defstruct candidates: %{}, ready: %{}, pending: %{}

  def bookkeeping_bytes, do: @bookkeeping_bytes

  def retain(state, key, source_key, body, opts, worker, receipt) do
    source_ref = source_ref(state, worker, source_key, opts)

    owner = Aliases.owner(state, key)

    if is_pid(opts[:queue]) && Process.alive?(opts[:queue]) && source_ref &&
         Aliases.in_use?(state, key, worker) && not Aliases.completed?(state, key) &&
         match?({:owned, queue} when is_pid(queue), owner) do
      retain_result(
        state,
        key,
        source_key,
        source_ref,
        body,
        opts,
        worker,
        receipt,
        elem(owner, 1)
      )
    else
      {{:ok, nil}, state}
    end
  end

  defp source_ref(state, worker, {url, scope}, opts) do
    claim = opts[:scheduler_claim]

    with %{worker: ^worker, opts: %{scheduler_claim: ^claim}} <-
           state.executions[state.execution_workers[worker]],
         %{job: %{logical_key: ^url, authority: {^scope, generation, queue}}} <-
           state.scheduler_workers[claim],
         true <- generation === opts.generation and queue === opts.queue do
      claim
    else
      _ -> nil
    end
  end

  defp retain_result(
         state,
         key,
         source_key,
         source_ref,
         body,
         opts,
         worker,
         receipt,
         target_queue
       ) do
    existing =
      Enum.find(state.settlements.candidates, fn {_, candidate} ->
        competes?(state, candidate, key, opts.generation) and
          (candidate.source_ref == source_ref or
             (candidate.source_done? and source_succeeded?(state, candidate)))
      end)

    case existing do
      {ref, %Candidate{source_done?: true}} ->
        {{:ok, ref}, state}

      {ref, candidate} ->
        state = retain_resources(state, [receipt], opts.scope)
        state = release_resources(state, candidate.resources)
        {{:ok, ref}, put(state, ref, %{candidate | body: body, opts: opts, resources: [receipt]})}

      nil ->
        candidate = %Candidate{
          key: key,
          source_key: source_key,
          source_ref: source_ref,
          worker: worker,
          queue: opts[:queue],
          target_queue: target_queue,
          target_handle: landing_target(key),
          generation: opts[:generation],
          body: body,
          opts: opts,
          resources: [receipt]
        }

        ref = make_ref()
        state = retain_resources(state, candidate.resources, opts.scope)
        state = put(state, ref, candidate)
        state = State.note_enqueued(state, opts[:scope], opts[:queue])
        {{:ok, ref}, state}
    end
  end

  def complete_source(state, key, worker) do
    Enum.reduce(state.settlements.candidates, state, fn
      {ref, %Candidate{source_key: ^key, worker: ^worker} = candidate}, state ->
        put(state, ref, %{candidate | source_done?: true})

      _, state ->
        state
    end)
  end

  def discard(state, ref, worker) do
    case state.settlements.candidates[ref] do
      %Candidate{worker: ^worker, status: status} when status in [:waiting, :queued] ->
        drop(state, ref)

      _ ->
        state
    end
  end

  def claim_finished(state, token) do
    Enum.reduce(state.settlements.candidates, state, fn {ref, _candidate}, state ->
      case state.settlements.candidates[ref] do
        %Candidate{status: {:running, ^token}} ->
          remove(state, ref)

        %Candidate{source_ref: ^token, status: status} = candidate
        when status in [:waiting, :queued] ->
          finish_source_claim(state, ref, candidate)

        _ ->
          state
      end
    end)
  end

  defp finish_source_claim(state, ref, candidate) do
    cond do
      not candidate.source_done? or source_unsuccessful?(state, candidate) ->
        drop(state, ref)

      source_succeeded?(state, candidate) ->
        select_source(state, ref, candidate)

      true ->
        state
    end
  end

  defp select_source(state, ref, candidate) do
    if current?(state, candidate), do: select_current_source(state, ref, candidate), else: state
  end

  defp select_current_source(state, ref, candidate) do
    issued? =
      Enum.any?(state.settlements.candidates, fn
        {other, %Candidate{status: {:running, _}} = contender} ->
          other != ref and competes?(state, contender, candidate.key, candidate.generation)

        _ ->
          false
      end)

    if issued? do
      drop(state, ref)
    else
      Enum.reduce(state.settlements.candidates, state, fn
        {other, %Candidate{status: status} = contender}, state
        when other != ref and status in [:waiting, :queued] ->
          drop_competing(state, other, contender, candidate)

        _, state ->
          state
      end)
    end
  end

  defp drop_competing(state, ref, contender, candidate) do
    if competes?(state, contender, candidate.key, candidate.generation),
      do: drop(state, ref),
      else: state
  end

  def prune(state, scope) do
    Enum.reduce(state.settlements.candidates, state, fn
      {ref, %Candidate{key: {_, ^scope}, status: status} = candidate}, state
      when status in [:waiting, :queued] ->
        if current?(state, candidate) and
             (Aliases.completed?(state, candidate.key) or
                State.page_owner(state, candidate.key) == {:owned, nil}),
           do: drop(state, ref),
           else: state

      _, state ->
        state
    end)
  end

  def schedule(state, scope) do
    Enum.reduce(state.settlements.candidates, {MapSet.new(), state}, fn
      {ref, %Candidate{key: {_, ^scope}, status: :waiting, source_done?: true} = candidate},
      {jobs, state} ->
        if eligible?(state, candidate) do
          {MapSet.put(jobs, candidate.queue), put(state, ref, %{candidate | status: :queued})}
        else
          {jobs, state}
        end

      _, result ->
        result
    end)
  end

  def start(state, ref) do
    case state.settlements.candidates[ref] do
      %Candidate{status: :queued} = candidate ->
        cond do
          Aliases.completed?(state, candidate.key) or not current?(state, candidate) ->
            {:skip, elem(candidate.key, 1), drop(state, ref)}

          not eligible?(state, candidate) ->
            {:skip, put(state, ref, %{candidate | status: :waiting})}

          true ->
            state = reset_page(state, candidate.key, candidate.target_handle)

            state =
              state
              |> State.forget_page(candidate.key)
              |> State.track_page(candidate.key, candidate.queue)

            {:ok, candidate, state}
        end

      _ ->
        {:skip, state}
    end
  end

  def started(state, ref, token) do
    candidate = state.settlements.candidates[ref]
    put(state, ref, %{candidate | status: {:running, token}})
  end

  def complete(state, ref, token) do
    case state.settlements.candidates[ref] do
      %Candidate{status: {:running, ^token}, key: key} = candidate ->
        if current?(state, candidate) && State.page_owner(state, key) == {:owned, candidate.queue} do
          complete_candidate(state, candidate)
        else
          state
        end

      _ ->
        state
    end
  end

  defp complete_candidate(state, candidate) do
    if source_succeeded?(state, candidate) do
      key = candidate.key

      Registry.update_value(
        DB,
        key,
        &%{&1 | processed: true, alias_owner: {:completed, candidate.opts[:target_handle]}}
      )

      {logical, scope} = key

      scheduler =
        Crawler.Store.Scheduler.mark_processed(
          state.scheduler,
          {scope, candidate.generation},
          logical,
          State.count(state, :ops, scope)
        )

      State.forget_page(%{state | scheduler: scheduler}, key)
    else
      state
    end
  end

  defp source_succeeded?(state, candidate) do
    with %{job: job, outcome: %{status: :succeeded}} <-
           state.scheduler.frontier.jobs[candidate.opts[:target_handle]],
         {scope, generation, queue} <- job.authority do
      candidate.source_key === {job.logical_key, scope} and
        candidate.generation === generation and candidate.queue === queue
    else
      _ -> false
    end
  end

  defp source_unsuccessful?(state, candidate) do
    case state.scheduler.frontier.jobs[candidate.opts[:target_handle]] do
      %{outcome: %{status: status}} -> status != :succeeded
      _ -> false
    end
  end

  def drop_scope(state, scope),
    do: reject(state, fn candidate -> elem(candidate.key, 1) === scope end)

  def drop_queue(state, queue), do: reject(state, &(&1.queue == queue))

  defp reject(state, match?) do
    Enum.reduce(state.settlements.candidates, state, fn {ref, candidate}, state ->
      if unstarted?(candidate) and match?.(candidate), do: remove(state, ref), else: state
    end)
  end

  def ready?(state, queue), do: map_size(Map.get(state.settlements.ready, queue, %{})) > 0

  def next(state, queue) do
    case :maps.next(:maps.iterator(Map.get(state.settlements.ready, queue, %{}))) do
      :none -> nil
      {ref, true, _iterator} -> ref
    end
  end

  defp put(state, ref, candidate) do
    previous = state.settlements.candidates[ref]
    ready = remove_ready(state.settlements.ready, previous, ref)
    pending = update_pending(state.settlements.pending, previous, candidate, ref)

    ready =
      if candidate.status == :queued,
        do: Map.update(ready, candidate.queue, %{ref => true}, &Map.put(&1, ref, true)),
        else: ready

    %{
      state
      | settlements: %{
          state.settlements
          | candidates: Map.put(state.settlements.candidates, ref, candidate),
            ready: ready,
            pending: pending
        }
    }
  end

  defp remove(state, ref) do
    candidate = state.settlements.candidates[ref]
    state = release_resources(state, candidate.resources)

    %{
      state
      | settlements: %{
          state.settlements
          | candidates: Map.delete(state.settlements.candidates, ref),
            ready: remove_ready(state.settlements.ready, candidate, ref),
            pending: remove_pending(state.settlements.pending, candidate, ref)
        }
    }
  end

  def retire_one(state, run) do
    refs = Map.get(state.settlements.pending, run, %{})

    case :maps.next(:maps.iterator(refs)) do
      :none ->
        {false, state}

      {ref, true, _iterator} ->
        state = drop(state, ref)
        {map_size(Map.get(state.settlements.pending, run, %{})) > 0, state}
    end
  end

  defp update_pending(pending, previous, candidate, ref) do
    if unstarted?(previous) and unstarted?(candidate) and
         pending_run(previous) === pending_run(candidate) do
      pending
    else
      pending |> remove_pending(previous, ref) |> add_pending(candidate, ref)
    end
  end

  defp unstarted?(%Candidate{status: status}), do: status in [:waiting, :queued]
  defp unstarted?(_candidate), do: false

  defp pending_run(candidate), do: {elem(candidate.key, 1), candidate.generation}

  defp add_pending(pending, %Candidate{status: status} = candidate, ref)
       when status in [:waiting, :queued],
       do: Map.update(pending, pending_run(candidate), %{ref => true}, &Map.put(&1, ref, true))

  defp add_pending(pending, _candidate, _ref), do: pending

  defp remove_pending(pending, %Candidate{status: status} = candidate, ref)
       when status in [:waiting, :queued] do
    run = pending_run(candidate)
    refs = Map.delete(Map.get(pending, run, %{}), ref)
    if map_size(refs) == 0, do: Map.delete(pending, run), else: Map.put(pending, run, refs)
  end

  defp remove_pending(pending, _candidate, _ref), do: pending

  defp remove_ready(ready, %Candidate{status: :queued, queue: queue}, ref) do
    refs = Map.delete(Map.get(ready, queue, %{}), ref)
    if map_size(refs) == 0, do: Map.delete(ready, queue), else: Map.put(ready, queue, refs)
  end

  defp remove_ready(ready, _candidate, _ref), do: ready

  defp retain_resources(state, refs, scope),
    do: Enum.reduce(refs, state, &ResourceManager.retain_persistent(&2, &1, scope, :issued))

  defp release_resources(state, refs),
    do: Enum.reduce(refs, state, &ResourceManager.release_persistent(&2, &1, :issued))

  defp drop(state, ref) do
    candidate = state.settlements.candidates[ref]
    scope = elem(candidate.key, 1)
    state = remove(state, ref)

    if Map.has_key?(state.scopes, scope) and
         State.generation(state, scope) === candidate.generation and
         State.queue_active?(state, scope, candidate.queue),
       do: State.finish_work(state, scope, false, candidate.queue),
       else: state
  end

  defp competes?(state, candidate, key, generation),
    do:
      candidate.key === key and candidate.generation === generation and current?(state, candidate)

  defp current?(state, candidate) do
    scope = elem(candidate.key, 1)

    State.current?(state, scope, candidate.generation) &&
      State.queue_active?(state, scope, candidate.queue) && Process.alive?(candidate.queue) &&
      not MapSet.member?(state.closing, candidate.queue)
  end

  defp eligible?(state, candidate) do
    current?(state, candidate) && source_succeeded?(state, candidate) &&
      not Aliases.in_use?(state, candidate.key, nil) &&
      State.page_owner(state, candidate.key) in [
        nil,
        {:owned, candidate.queue},
        {:owned, candidate.target_queue}
      ]
  end

  defp landing_target(key) do
    case Registry.lookup(DB, key) do
      [{_, %Page{target_handle: target}}] -> target
      _ -> nil
    end
  end

  defp reset_page(state, {url, _scope} = key, target) do
    state = ResourceManager.remove_page(state, key)
    Registry.register(DB, key, %Page{url: url, target_handle: target})
    state
  end
end
