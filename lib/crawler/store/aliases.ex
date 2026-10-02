defmodule Crawler.Store.Aliases do
  @moduledoc false

  alias Crawler.Store.Claims
  alias Crawler.Store.DB
  alias Crawler.Store.Page
  alias Crawler.Store.State

  def register(state, key, queue, worker) do
    if Claims.in_use?(state.claims, key, worker) do
      {{:ok, :skip}, state}
    else
      {result, state} = acquire(state, key, queue)

      case result do
        {:ok, status} when status in [:created, :reused] ->
          claims = Claims.add_alias(state.claims, worker, key, queue)
          {result, %{state | claims: claims}}

        _ ->
          {result, state}
      end
    end
  end

  def rollback(state, key, queue, worker, created?) do
    state = %{state | claims: Claims.delete_alias(state.claims, worker, key, queue)}

    if created? and State.owns_page?(state, key, queue) do
      case Registry.lookup(DB, key) do
        [{_, %Page{processed: true}}] ->
          state

        _ ->
          Registry.unregister(DB, key)
          State.forget_page(state, key)
      end
    else
      state
    end
  end

  defp acquire(state, {url, _scope} = key, queue) do
    case Registry.lookup(DB, key) do
      [] ->
        case Registry.register(DB, key, %Page{url: url}) do
          {:ok, _} -> {{:ok, :created}, State.track_page(state, key, queue)}
          error -> {error, state}
        end

      [{_, %Page{processed: true}}] ->
        {{:ok, :skip}, state}

      [{_, _page}] ->
        status =
          if is_pid(queue) and State.owns_page?(state, key, queue), do: :reused, else: :skip

        {{:ok, status}, state}
    end
  end
end
