defmodule Crawler.Store.Authority do
  @moduledoc false

  alias Crawler.Store.State

  @table __MODULE__

  def init, do: :ets.new(@table, [:named_table, :protected, read_concurrency: true])

  def put(state, scope) do
    case Map.fetch(state.scopes, scope) do
      {:ok, run} ->
        :ets.insert(@table, {scope, State.generation(state, scope), Map.keys(run.work)})

      :error ->
        delete(scope)
    end
  end

  def delete(scope), do: :ets.delete(@table, scope)

  def current?(_scope, nil, _queue), do: false

  def current?(scope, generation, queue) do
    case :ets.whereis(@table) do
      :undefined -> false
      table -> lookup(table, scope, generation, queue)
    end
  end

  defp lookup(table, scope, generation, queue) do
    case :ets.lookup(table, scope) do
      [{^scope, ^generation, queues}] ->
        is_nil(queue) or (is_pid(queue) and queue in queues and Process.alive?(queue))

      _ ->
        false
    end
  rescue
    ArgumentError -> false
  end
end
