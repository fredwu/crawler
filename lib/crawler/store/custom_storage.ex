defmodule Crawler.Store.CustomStorage do
  @moduledoc false

  alias Crawler.Frontier.Ring
  alias Crawler.Store.Authority
  alias Crawler.Store.ResourceManager
  alias Crawler.Store.Resources
  alias Crawler.Store.Retained
  alias Crawler.URL

  @waiters 16
  @metadata 8192

  def claim(state, opts, receipt, {worker, _} = from) do
    lease = opts.execution_lease
    execution = state.executions[lease]

    with true <- current?(execution, opts, worker),
         true <- source?(state, execution, opts),
         true <- funded?(state, opts, receipt, worker),
         nil <- execution[:custom_storage] do
      key = {opts.source_revision, opts.store, URL.canonical(opts.url)}
      acquire(state, opts, key, receipt, from)
    else
      _ -> {:reply, {:error, :stale}, discard(state, receipt, opts, worker)}
    end
  end

  def finish(state, opts, success?, worker) do
    case state.executions[opts.execution_lease] do
      %{worker: ^worker, custom_storage: %{role: :owner} = owned} ->
        finish_owner(state, opts.execution_lease, owned, success?)

      _ ->
        state
    end
  end

  def execution_ended(state, lease) do
    case state.executions[lease] do
      %{custom_storage: %{role: :owner} = owned} -> finish_owner(state, lease, owned, false)
      %{custom_storage: %{role: {:waiter, _}} = owned} -> remove_waiter(state, lease, owned)
      _ -> state
    end
  end

  def retire_marker(state, marker) do
    case state.executions[marker.owner] do
      %{custom_storage: %{role: :owner} = owned}
      when owned.representation === marker.representation and owned.key === marker.key and
             owned.receipt === marker.receipt ->
        state

      _ ->
        role = if is_nil(marker.owner), do: :ordinary, else: :issued
        ResourceManager.release_persistent(state, marker.receipt, role)
    end
  end

  defp current?(%{worker: worker, opts: bound}, opts, worker) do
    Authority.execution_current?(opts.execution_lease, worker) and
      {bound[:scope], bound[:generation], bound[:queue]} ===
        {opts[:scope], opts[:generation], opts[:queue]}
  end

  defp current?(_, _, _), do: false

  defp source?(state, execution, opts) do
    logical = URL.canonical(opts.url)
    source = {opts.representation_id, opts.source_revision, opts.store, logical}

    Map.has_key?(state.scheduler.representations, opts.representation_id) and
      is_reference(opts.source_revision) and
      (execution[:custom_storage_source] === source or
         normal_source?(state, execution, opts, logical))
  end

  defp normal_source?(state, execution, opts, logical) do
    with %{representation: representation, job: target} <-
           state.scheduler.claims[execution.opts[:scheduler_claim]],
         %{job: job} <- state.scheduler.frontier.jobs[target] do
      representation === opts.representation_id and
        execution[:source_revision] === opts.source_revision and job.opts.store === opts.store and
        (job.logical_key === logical or final_source?(execution, opts, logical))
    else
      _ -> false
    end
  end

  defp final_source?(execution, opts, logical) do
    execution[:source_revision] === opts.source_revision and
      case execution[:physical_final_url] do
        nil -> false
        url -> URL.canonical(url) === logical
      end
  end

  defp funded?(state, opts, receipt, worker) do
    lease = opts.execution_lease

    case Resources.receipt(state.resources, receipt) do
      %{kind: :source, executor: ^worker, lease: ^lease, actual: bytes, holders: holders}
      when is_integer(bytes) and bytes >= @metadata ->
        match?(%{status: :pending, origin: ^worker, lease: ^lease}, holders[self()]) and
          Authority.resource_current?(receipt, lease, self()) and
          match?({:ok, _}, Retained.bytes(opts, bytes - @metadata))

      _ ->
        false
    end
  end

  defp acquire(state, opts, key, receipt, from) do
    representation = opts.representation_id
    marker = get_in(state.scheduler.representations, [representation, :custom_storage, key])

    case marker do
      %{owner: nil} ->
        {:reply, :skip, discard(state, receipt, opts, elem(from, 0))}

      %{owner: owner} when owner === opts.execution_lease ->
        {:reply, :skip, discard(state, receipt, opts, elem(from, 0))}

      nil ->
        state = retain(state, receipt, opts[:scope])
        marker = %{owner: opts.execution_lease, receipt: receipt, waiters: Ring.new()}
        state = put_marker(state, representation, key, marker)
        state = associate(state, opts.execution_lease, representation, key, receipt, :owner)
        {:reply, :store, state}

      %{waiters: waiters} = marker ->
        if Ring.size(waiters) >= min(@waiters, opts.max_pending) do
          {:reply, {:error, {:limit, :max_pending}}, discard(state, receipt, opts, elem(from, 0))}
        else
          wait(state, opts, key, receipt, from, marker)
        end
    end
  end

  defp wait(state, opts, key, receipt, from, marker) do
    state = retain(state, receipt, opts[:scope])
    marker = %{marker | waiters: Ring.put(marker.waiters, opts.execution_lease)}
    state = put_marker(state, opts.representation_id, key, marker)

    state =
      associate(
        state,
        opts.execution_lease,
        opts.representation_id,
        key,
        receipt,
        {:waiter, from}
      )

    {:noreply, state}
  end

  defp finish_owner(state, lease, owned, success?) do
    state = clear(state, lease)

    case get_marker(state, owned) do
      %{owner: ^lease} = marker ->
        if success? do
          scope = state.executions[lease].opts[:scope]
          state = ResourceManager.retain_persistent(state, owned.receipt, scope)
          state = release(state, owned.receipt)

          state =
            put_marker(state, owned.representation, owned.key, %{
              marker
              | owner: nil,
                waiters: Ring.new()
            })

          wake(state, marker.waiters, :skip)
        else
          state = release(state, owned.receipt)
          handoff(state, owned, marker.waiters)
        end

      _ ->
        release(state, owned.receipt)
    end
  end

  defp handoff(state, owned, waiters) do
    case Ring.take(waiters) do
      :empty ->
        put_marker(state, owned.representation, owned.key, nil)

      {:ok, lease, rest} ->
        case state.executions[lease] do
          %{worker: worker, custom_storage: %{role: {:waiter, from}} = next} ->
            handoff_execution(state, owned, lease, rest, worker, from, next)

          _ ->
            handoff(state, owned, rest)
        end
    end
  end

  defp handoff_execution(state, owned, lease, rest, worker, from, next) do
    case execution_status(state, lease, worker) do
      :ok ->
        marker = %{owner: lease, receipt: next.receipt, waiters: rest}
        state = put_marker(state, owned.representation, owned.key, marker)

        state =
          associate(state, lease, owned.representation, owned.key, next.receipt, :owner)

        GenServer.reply(from, :store)
        state

      error ->
        GenServer.reply(from, error)
        state = state |> clear(lease) |> release(next.receipt)
        handoff(state, owned, rest)
    end
  end

  defp wake(state, waiters, result) do
    Enum.reduce(waiters.members, state, fn {lease, _}, state ->
      wake_waiter(state, lease, result)
    end)
  end

  defp wake_waiter(state, lease, result) do
    case state.executions[lease] do
      %{worker: worker, custom_storage: %{role: {:waiter, from}} = owned} ->
        reply =
          case execution_status(state, lease, worker) do
            :ok -> result
            error -> error
          end

        GenServer.reply(from, reply)
        state |> clear(lease) |> release(owned.receipt)

      _ ->
        state
    end
  end

  defp execution_status(state, lease, worker) do
    with :ok <- Crawler.Deadline.check(state.executions[lease].deadline),
         true <- Authority.execution_current?(lease, worker) do
      :ok
    else
      false -> {:error, :stale}
      error -> error
    end
  end

  defp remove_waiter(state, lease, owned) do
    state = state |> clear(lease) |> release(owned.receipt)

    case get_marker(state, owned) do
      nil ->
        state

      marker ->
        put_marker(state, owned.representation, owned.key, %{
          marker
          | waiters: Ring.delete(marker.waiters, lease)
        })
    end
  end

  defp associate(state, lease, representation, key, receipt, role) do
    owned = %{representation: representation, key: key, receipt: receipt, role: role}

    %{
      state
      | executions: Map.update!(state.executions, lease, &Map.put(&1, :custom_storage, owned))
    }
  end

  defp clear(state, lease),
    do: %{
      state
      | executions: Map.update!(state.executions, lease, &Map.delete(&1, :custom_storage))
    }

  defp get_marker(state, owned),
    do:
      get_in(state.scheduler.representations, [owned.representation, :custom_storage, owned.key])

  defp put_marker(state, representation, key, marker) do
    case state.scheduler.representations[representation] do
      nil ->
        state

      value ->
        markers = Map.get(value, :custom_storage, %{})
        markers = if marker, do: Map.put(markers, key, marker), else: Map.delete(markers, key)
        value = Map.put(value, :custom_storage, markers)

        %{
          state
          | scheduler: %{
              state.scheduler
              | representations: Map.put(state.scheduler.representations, representation, value)
            }
        }
    end
  end

  defp retain(state, receipt, scope),
    do: ResourceManager.retain_persistent(state, receipt, scope, :issued)

  defp release(state, receipt), do: ResourceManager.release_persistent(state, receipt, :issued)

  defp discard(state, receipt, opts, worker) do
    lease = opts[:execution_lease]

    case Resources.receipt(state.resources, receipt) do
      %{kind: :source, lease: ^lease, executor: ^worker, holders: holders} ->
        if match?(%{status: :pending, origin: ^worker, lease: ^lease}, holders[self()]),
          do:
            elem(
              ResourceManager.transition(
                state,
                Resources.release(state.resources, receipt, self())
              ),
              1
            ),
          else: state

      _ ->
        state
    end
  end
end
