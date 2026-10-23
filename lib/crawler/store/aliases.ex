defmodule Crawler.Store.Aliases do
  @moduledoc false

  alias Crawler.Store.Claims
  alias Crawler.Store.DB
  alias Crawler.Store.Page
  alias Crawler.Store.ResourceManager
  alias Crawler.Store.State

  def register(state, key, queue, worker) do
    if in_use?(state, key, worker) do
      {{:ok, :skip}, state}
    else
      {result, state} = acquire(state, key, queue, worker)

      case result do
        {:ok, status} when status in [:created, :reused] ->
          claims =
            Claims.add_alias(
              state.claims,
              worker,
              key,
              queue,
              State.generation(state, elem(key, 1))
            )

          {result, %{state | claims: claims}}

        _ ->
          {result, state}
      end
    end
  end

  def rollback(state, key, queue, worker, created?) do
    state = %{
      state
      | claims:
          Claims.delete_alias(
            state.claims,
            worker,
            key,
            queue,
            State.generation(state, elem(key, 1))
          )
    }

    case Registry.lookup(DB, key) do
      [{_, %Page{} = page}] ->
        if completed?(state, key),
          do: state,
          else: rollback_page(state, key, queue, worker, created?, page)

      _ ->
        state
    end
  end

  defp rollback_page(state, key, queue, worker, _created?, %Page{alias_owner: owner})
       when is_reference(owner) do
    if owner === target(state, worker) and State.owns_page?(state, key, queue) do
      Registry.update_value(DB, key, &%{&1 | alias_owner: nil})
    end

    state
  end

  defp rollback_page(state, key, queue, worker, created?, %Page{target_handle: owner}) do
    if created? and State.owns_page?(state, key, queue) and
         (is_nil(owner) or owner === target(state, worker)),
       do: ResourceManager.remove_page(state, key),
       else: state
  end

  def completed?(state, {_, scope} = key) do
    with true <- Map.has_key?(state.scopes, scope),
         [{_, %Page{processed: true} = page}] <- Registry.lookup(DB, key) do
      run = {scope, State.generation(state, scope)}

      is_nil(page.target_handle) or target_succeeded?(state, page.target_handle, run) or
        alias_completed?(state, page.alias_owner, run)
    else
      _ -> false
    end
  end

  defp alias_completed?(state, {:completed, target}, run),
    do: target_succeeded?(state, target, run)

  defp alias_completed?(_state, _owner, _run), do: false

  defp target_succeeded?(state, target, {scope, generation}) do
    case state.scheduler.frontier.jobs[target] do
      %{job: %{authority: {^scope, ^generation, _}}, outcome: %{status: :succeeded}} -> true
      _ -> false
    end
  end

  def owner(state, {_, scope} = key) do
    case State.page_owner(state, key) do
      nil -> canonical_owner(state, key, scope)
      owner -> owner
    end
  end

  defp canonical_owner(state, key, scope) do
    with true <- Map.has_key?(state.scopes, scope),
         [{_, %Page{target_handle: target}}] <- Registry.lookup(DB, key),
         %{job: %{authority: {^scope, generation, queue}}} = record <-
           state.scheduler.frontier.jobs[target],
         true <- State.current?(state, scope, generation),
         true <- is_pid(queue) and State.queue_active?(state, scope, queue),
         true <-
           match?({:running, _}, record.status) or
             match?(%{status: status} when status != :succeeded, record.outcome) do
      {:owned, queue}
    else
      _ -> nil
    end
  end

  def in_use?(state, {url, scope} = key, worker) do
    run = {scope, State.generation(state, scope)}
    group = get_in(state.scheduler.frontier.runs, [run, :groups, url])

    canonical? =
      group && Enum.any?(group.active, &other_worker?(state, &1, worker))

    alias? = alias_in_use?(state, key, worker)

    claimed? =
      case state.scopes[scope] do
        %{work: active_queues} ->
          Claims.in_use?(state.claims, key, worker, elem(run, 1), active_queues)

        _ ->
          false
      end

    canonical? || alias? || claimed?
  end

  defp alias_in_use?(state, key, worker) do
    case Registry.lookup(DB, key) do
      [{_, %Page{target_handle: target, alias_owner: owner}}] ->
        target_in_use?(state, target, worker) or target_in_use?(state, owner, worker)

      _ ->
        false
    end
  end

  defp target_in_use?(state, target, worker) do
    case state.scheduler.frontier.jobs[target] do
      %{status: {:running, claim}} -> other_worker?(state, claim, worker)
      _ -> false
    end
  end

  defp other_worker?(state, claim, worker) do
    own_execution? =
      case state.executions[state.execution_workers[worker]] do
        %{worker: ^worker, opts: %{scheduler_claim: ^claim}} -> true
        _ -> false
      end

    not own_execution? and
      case state.scheduler_workers[claim] do
        %{worker: ^worker} -> false
        _ -> true
      end
  end

  defp target(state, worker) do
    with lease when not is_nil(lease) <- state.execution_workers[worker],
         %{opts: %{scheduler_claim: claim}} <- state.executions[lease],
         %{job: job} <- state.scheduler_workers[claim] do
      job.id
    else
      _ -> nil
    end
  end

  defp acquire(state, {url, _scope} = key, queue, worker) do
    case Registry.lookup(DB, key) do
      [] ->
        case Registry.register(DB, key, %Page{
               url: url,
               target_handle: target(state, worker),
               storage_revision: make_ref()
             }) do
          {:ok, _} -> {{:ok, :created}, State.track_page(state, key, queue)}
          error -> {error, state}
        end

      [{_, _page}] ->
        if completed?(state, key),
          do: {{:ok, :skip}, state},
          else: acquire_existing(state, key, queue, worker)
    end
  end

  defp acquire_existing(state, key, queue, worker) do
    owns? = is_pid(queue) and owner(state, key) === {:owned, queue}
    status = if owns?, do: :reused, else: :skip

    state =
      if owns? and is_nil(State.page_owner(state, key)),
        do: State.track_page(state, key, queue),
        else: state

    owner = target(state, worker)

    if status == :reused and is_reference(owner),
      do: Registry.update_value(DB, key, &%{&1 | alias_owner: owner})

    {{:ok, status}, state}
  end
end
