defmodule Crawler.Store.Settlements do
  @moduledoc false

  alias Crawler.Fetcher.AliasSettlement
  alias Crawler.Store.Claims
  alias Crawler.Store.DB
  alias Crawler.Store.Page
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
      :generation,
      :body,
      :opts,
      source_done?: false,
      status: :waiting
    ]
  end

  defstruct candidates: %{}

  def retain(state, key, source_key, body, opts, worker) do
    source_ref = Claims.source_ref(state.claims, worker, source_key, opts[:queue])

    owner = State.page_owner(state, key)

    if is_pid(opts[:queue]) && Process.alive?(opts[:queue]) && source_ref &&
         Claims.in_use?(state.claims, key, worker) && not processed?(key) &&
         match?({:owned, queue} when is_pid(queue), owner) do
      retain_result(state, key, source_key, source_ref, body, opts, worker)
    else
      {{:ok, nil}, state}
    end
  end

  defp retain_result(state, key, source_key, source_ref, body, opts, worker) do
    existing =
      Enum.find(state.settlements.candidates, fn {_, candidate} ->
        candidate.key === key and (candidate.source_done? or candidate.source_ref == source_ref)
      end)

    case existing do
      {ref, %Candidate{source_done?: true}} ->
        {{:ok, ref}, state}

      {ref, candidate} ->
        {{:ok, ref}, put(state, ref, %{candidate | body: body, opts: opts})}

      nil ->
        candidate = %Candidate{
          key: key,
          source_key: source_key,
          source_ref: source_ref,
          worker: worker,
          queue: opts[:queue],
          target_queue: elem(State.page_owner(state, key), 1),
          generation: opts[:generation],
          body: body,
          opts: opts
        }

        ref = make_ref()
        state = put(state, ref, candidate)
        state = State.note_enqueued(state, opts[:scope], opts[:queue])
        {{:ok, ref}, state}
    end
  end

  def complete_source(state, key, worker) do
    Enum.reduce(state.settlements.candidates, state, fn
      {ref, %Candidate{source_key: ^key, worker: ^worker} = candidate}, state ->
        state = put(state, ref, %{candidate | source_done?: true})

        Enum.reduce(state.settlements.candidates, state, fn
          {other, %Candidate{key: landing}}, state
          when other != ref and landing === candidate.key ->
            drop(state, other)

          _, state ->
            state
        end)

      _, state ->
        state
    end)
  end

  def discard(state, ref, worker) do
    case state.settlements.candidates[ref] do
      %Candidate{worker: ^worker} -> drop(state, ref)
      _ -> state
    end
  end

  def claim_finished(state, token) do
    Enum.reduce(state.settlements.candidates, state, fn
      {ref, %Candidate{status: {:running, ^token}}}, state -> remove(state, ref)
      {ref, %Candidate{source_ref: ^token, source_done?: false}}, state -> drop(state, ref)
      _, state -> state
    end)
  end

  def prune(state, scope) do
    Enum.reduce(state.settlements.candidates, state, fn
      {ref, %Candidate{key: {_, ^scope}, status: status} = candidate}, state
      when status in [:waiting, :queued] ->
        if processed?(candidate.key) or State.page_owner(state, candidate.key) == {:owned, nil},
          do: drop(state, ref),
          else: state

      _, state ->
        state
    end)
  end

  def schedule(state, scope) do
    Enum.reduce(state.settlements.candidates, {[], state}, fn
      {ref, %Candidate{key: {_, ^scope}, status: :waiting, source_done?: true} = candidate},
      {jobs, state} ->
        if eligible?(state, candidate) do
          job = %AliasSettlement{ref: ref, queue: candidate.queue}
          {[job | jobs], put(state, ref, %{candidate | status: :queued})}
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
          processed?(candidate.key) or not current?(state, candidate) ->
            {:skip, elem(candidate.key, 1), drop(state, ref)}

          not eligible?(state, candidate) ->
            {:skip, put(state, ref, %{candidate | status: :waiting})}

          true ->
            reset_page(candidate.key)

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
          Registry.update_value(DB, key, &%{&1 | processed: true})
          state |> State.forget_page(key) |> remove(ref)
        else
          state
        end

      _ ->
        state
    end
  end

  def drop_scope(state, scope),
    do: reject(state, fn candidate -> elem(candidate.key, 1) === scope end)

  def drop_queue(state, queue), do: reject(state, &(&1.queue == queue))

  defp reject(state, match?) do
    settlements = %{
      state.settlements
      | candidates:
          Map.reject(
            state.settlements.candidates,
            fn {_, candidate} -> match?.(candidate) end
          )
    }

    %{state | settlements: settlements}
  end

  defp put(state, ref, candidate) do
    %{
      state
      | settlements: %{
          state.settlements
          | candidates: Map.put(state.settlements.candidates, ref, candidate)
        }
    }
  end

  defp remove(state, ref) do
    %{
      state
      | settlements: %{
          state.settlements
          | candidates: Map.delete(state.settlements.candidates, ref)
        }
    }
  end

  defp drop(state, ref) do
    candidate = state.settlements.candidates[ref]
    state |> remove(ref) |> State.finish_work(elem(candidate.key, 1), false, candidate.queue)
  end

  defp processed?(key), do: match?([{_, %Page{processed: true}}], Registry.lookup(DB, key))

  defp current?(state, candidate) do
    scope = elem(candidate.key, 1)

    State.current?(state, scope, candidate.generation) &&
      State.queue_active?(state, scope, candidate.queue) && Process.alive?(candidate.queue) &&
      not MapSet.member?(state.closing, candidate.queue)
  end

  defp eligible?(state, candidate) do
    not Claims.in_use?(state.claims, candidate.key, nil) &&
      State.page_owner(state, candidate.key) in [
        nil,
        {:owned, candidate.queue},
        {:owned, candidate.target_queue}
      ]
  end

  defp reset_page({url, _scope} = key) do
    case Registry.lookup(DB, key) do
      [] -> Registry.register(DB, key, %Page{url: url})
      _ -> Registry.update_value(DB, key, fn _ -> %Page{url: url} end)
    end
  end
end
