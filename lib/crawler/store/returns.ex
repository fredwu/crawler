defmodule Crawler.Store.Returns do
  @moduledoc false

  alias Crawler.Frontier.Ring
  alias Crawler.Store.ResourceManager
  alias Crawler.Store.Resources

  def prepare(state, opts, caller, credit, worker) do
    lease = opts[:execution_lease]
    execution = state.executions[lease]

    with %{arena: arena, worker: ^worker} <- execution,
         true <- is_pid(caller) and Process.alive?(caller),
         {:ok, refs} <- references(credit),
         true <- Enum.all?(refs, &Resources.current?(state.resources, &1, lease, worker)),
         {:ok, metadata, resources, effects} <-
           reserve_return(state.resources, arena, lease, caller, credit, refs) do
      token = make_ref()

      record = %{
        producer: worker,
        caller: caller,
        refs: refs,
        metadata: metadata,
        copy: credit.copy_receipt,
        state: :pending
      }

      owned =
        Enum.reduce(refs, state.return_owned, fn ref, owned ->
          if Resources.receipt(state.resources, ref).holders[caller],
            do: owned,
            else: MapSet.put(owned, {caller, ref})
        end)

      counts =
        Enum.reduce(refs, state.return_uses, &Map.update(&2, {caller, &1}, 1, fn n -> n + 1 end))

      state = %{
        state
        | execution_returns: Map.put(state.execution_returns, token, record),
          return_producers: index_put(state.return_producers, worker, token),
          return_callers: index_put(state.return_callers, caller, token),
          return_uses: counts,
          return_owned: owned
      }

      {_, state} = ResourceManager.transition(state, {:ok, resources, effects})
      {{:ok, token}, state}
    else
      {:error, {:limit, key}} when key in [:arena_capacity, :receipt_capacity] ->
        {{:error, {:limit, :max_retained_bytes}}, state}

      {:error, _} = error ->
        {error, state}

      _ ->
        {{:error, :stale}, state}
    end
  end

  def accept(state, token, caller) do
    case state.execution_returns[token] do
      %{caller: ^caller} = record ->
        state = Enum.reduce(record.refs, state, &adopt_return(&2, &1, caller))

        state = %{
          state
          | execution_returns:
              Map.put(state.execution_returns, token, %{record | state: :accepted}),
            return_producers: index_delete(state.return_producers, record.producer, token)
        }

        {:ok, state}

      _ ->
        {{:error, :stale_return}, state}
    end
  end

  defp adopt_return(state, ref, caller) do
    case Resources.receipt(state.resources, ref) do
      %{holders: holders} ->
        if holders[caller] && holders[caller].status not in [:owned, :retained],
          do:
            elem(
              ResourceManager.transition(
                state,
                Resources.adopt(state.resources, ref, caller)
              ),
              1
            ),
          else: state

      _ ->
        state
    end
  end

  def discard(state, producer, caller) do
    case Ring.take(Map.get(state.return_producers, producer, Ring.new())) do
      {:ok, token, _} -> discard_pending(state, token, caller)
      :empty -> state
    end
  end

  defp discard_pending(state, token, caller) do
    case state.execution_returns[token] do
      %{caller: ^caller, state: :pending} -> elem(release(state, token, caller), 1)
      _ -> state
    end
  end

  def pending_references(state, producer, caller) do
    case Ring.take(Map.get(state.return_producers, producer, Ring.new())) do
      {:ok, token, _} -> references_for(state, token, caller)
      :empty -> []
    end
  end

  def references_for(state, token, caller) do
    case state.execution_returns[token] do
      %{caller: ^caller, refs: refs} -> refs
      _ -> []
    end
  end

  def release(state, token, caller) do
    case state.execution_returns[token] do
      %{caller: ^caller} = record ->
        state = Enum.reduce(record.refs, state, &release_reference(&2, caller, &1))

        {_, state} =
          ResourceManager.transition(
            state,
            Resources.release(state.resources, record.metadata, self())
          )

        {_, state} =
          ResourceManager.transition(
            state,
            Resources.release(state.resources, record.copy, self())
          )

        {:ok,
         %{
           state
           | execution_returns: Map.delete(state.execution_returns, token),
             return_producers: index_delete(state.return_producers, record.producer, token),
             return_callers: index_delete(state.return_callers, caller, token)
         }}

      _ ->
        {{:error, :stale_return}, state}
    end
  end

  defp release_reference(state, caller, ref) do
    key = {caller, ref}

    case Map.fetch!(state.return_uses, key) do
      1 ->
        state =
          if MapSet.member?(state.return_owned, key),
            do:
              elem(
                ResourceManager.transition(
                  state,
                  Resources.release(state.resources, ref, caller)
                ),
                1
              ),
            else: state

        %{
          state
          | return_uses: Map.delete(state.return_uses, key),
            return_owned: MapSet.delete(state.return_owned, key)
        }

      n ->
        %{state | return_uses: Map.put(state.return_uses, key, n - 1)}
    end
  end

  def caller_down(state, caller, batch \\ 16)

  def caller_down(state, caller, 0) do
    if Map.has_key?(state.return_callers, caller),
      do: send(self(), {:release_execution_returns, caller})

    state
  end

  def caller_down(state, caller, batch) do
    case Ring.take(Map.get(state.return_callers, caller, Ring.new())) do
      :empty ->
        state

      {:ok, token, _} ->
        {_, state} = release(state, token, caller)
        caller_down(state, caller, batch - 1)
    end
  end

  defp references(%{retained: retained, backing: backing, reservation: reservation})
       when is_list(retained) and is_list(backing) and is_reference(reservation) do
    with {:ok, refs} <- bounded_references(retained, [], 4),
         {:ok, [_ | _] = refs} <- bounded_references(backing, refs, 4) do
      {:ok, refs}
    else
      _ -> {:error, :invalid_return_credit}
    end
  end

  defp references(_), do: {:error, :invalid_return_credit}

  defp bounded_references([], refs, _left), do: {:ok, refs}

  defp bounded_references([ref | tail], refs, left) when is_reference(ref) and left > 0 do
    if ref in refs, do: :error, else: bounded_references(tail, [ref | refs], left - 1)
  end

  defp bounded_references(_, _, _), do: :error

  defp reserve_return(resources, arena, lease, caller, credit, refs) do
    with %{lease: ^lease, arena: ^arena, kind: :return_copy, actual: actual}
         when is_integer(actual) <- Resources.receipt(resources, credit[:copy_receipt]),
         {:ok, resources, copy_effects} <-
           Resources.adopt(resources, credit.copy_receipt, self()),
         %{lease: ^lease, arena: ^arena, actual: nil} <-
           Resources.receipt(resources, credit.reservation),
         {:ok, resources, release_effects} <-
           Resources.release(resources, credit.reservation, resources.arenas[arena].executor),
         {{:ok, metadata}, resources, reserve_effects} <-
           Resources.reserve(resources, arena, lease, :source, 4_096, self()),
         {:ok, resources, commit_effects} <- Resources.commit(resources, metadata, lease, 4_096),
         {:ok, resources, adopt_effects} <- Resources.adopt(resources, metadata, self()),
         {:ok, resources, retain_effects} <-
           retain_all(resources, arena, lease, caller, refs, credit.backing) do
      {:ok, metadata, resources,
       copy_effects ++
         release_effects ++ reserve_effects ++ commit_effects ++ adopt_effects ++ retain_effects}
    else
      {{:error, reason}, _, _} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :stale}
    end
  end

  defp retain_all(resources, arena, lease, caller, refs, backing) do
    executor = resources.arenas[arena].executor

    Enum.reduce_while(refs, {:ok, resources, []}, fn ref, {:ok, resources, effects} ->
      role = if ref in backing, do: :backing, else: :copy

      if Resources.receipt(resources, ref).holders[caller] do
        {:cont, {:ok, resources, effects}}
      else
        retain_reference(resources, ref, arena, lease, executor, caller, role, effects)
      end
    end)
  end

  defp retain_reference(resources, ref, arena, lease, executor, caller, role, effects) do
    case Resources.retain_from(resources, ref, arena, lease, executor, caller, role) do
      {:ok, resources, next} -> {:cont, {:ok, resources, effects ++ next}}
      {error, _, _} -> {:halt, error}
    end
  end

  defp index_put(index, key, token),
    do: Map.update(index, key, Ring.put(Ring.new(), token), &Ring.put(&1, token))

  defp index_delete(index, key, token) do
    ring = Ring.delete(Map.get(index, key, Ring.new()), token)
    if Ring.size(ring) == 0, do: Map.delete(index, key), else: Map.put(index, key, ring)
  end
end
