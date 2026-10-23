defmodule Crawler.Store.Authority do
  @moduledoc false

  alias Crawler.Store.State

  @table __MODULE__
  @executions Crawler.Store.Execution
  @resources Crawler.Store.Resources
  @export_writers Crawler.Store.Export.Writers

  def init do
    :ets.new(@export_writers, [:named_table, :protected, read_concurrency: true])
    :ets.new(@resources, [:named_table, :protected, read_concurrency: true])
    :ets.new(@executions, [:named_table, :protected, read_concurrency: true])
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
  end

  def put(state, scope) do
    case Map.fetch(state.scopes, scope) do
      {:ok, %{outcome: :open} = run} ->
        generation = State.generation(state, scope)
        remove_superseded_writer(scope, generation)
        :ets.insert(@table, {scope, generation, Map.keys(run.work)})

      _ ->
        delete(scope)
    end
  end

  defp remove_superseded_writer(scope, generation) do
    case :ets.lookup(@export_writers, scope) do
      [{^scope, writer_generation, _epoch, _status}] when writer_generation !== generation ->
        :ets.delete(@export_writers, scope)

      _ ->
        :ok
    end
  end

  def delete(scope) do
    :ets.delete(@export_writers, scope)
    :ets.delete(@table, scope)
  end

  def put_export_writer(scope, generation, epoch, status) when status in [:open, :closed],
    do: :ets.insert(@export_writers, {scope, generation, epoch, status})

  def export_writable?(scope, generation, queue, lease \\ nil) do
    current?(scope, generation, queue, lease) and export_writer_open?(scope, generation)
  end

  def export_managed?(scope, generation) do
    match?([{^scope, ^generation, _, _}], :ets.lookup(@export_writers, scope))
  rescue
    ArgumentError -> false
  end

  defp export_writer_open?(scope, generation) do
    case :ets.lookup(@export_writers, scope) do
      [] -> true
      [{^scope, ^generation, _epoch, :open}] -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  def current?(_scope, nil, _queue), do: false

  def current?(scope, generation, queue) do
    case :ets.whereis(@table) do
      :undefined -> false
      table -> lookup(table, scope, generation, queue)
    end
  end

  def current?(scope, generation, queue, nil), do: current?(scope, generation, queue)

  def current?(scope, generation, queue, lease) when is_reference(lease) do
    case :ets.lookup(@executions, lease) do
      [{^lease, _owner, _deadline, ^scope, ^generation, ^queue}] -> execution_current?(lease)
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  def current?(_scope, _generation, _queue, _lease), do: false

  def execution_current?(lease, worker \\ nil) do
    case :ets.lookup(@executions, lease) do
      [{^lease, owner, deadline, scope, generation, queue}] ->
        (is_nil(worker) or owner == worker) and Process.alive?(owner) and
          current?(scope, generation, queue) and Crawler.Deadline.check(deadline) == :ok

      _ ->
        false
    end
  rescue
    ArgumentError -> false
  end

  def put_execution(lease, worker, deadline, opts),
    do:
      :ets.insert(
        @executions,
        {lease, worker, deadline, opts[:scope], opts[:generation], opts[:queue]}
      )

  def revoke_execution(lease), do: :ets.delete(@executions, lease)

  def put_arena(arena, lease, executor, run) do
    :ets.insert(@resources, {{:arena, arena}, lease, executor, run, :open})
  end

  def put_resource(receipt, lease, holder, run, arena),
    do: :ets.insert(@resources, {{:grant, receipt, holder}, lease, run, arena})

  def delete_resource(receipt, holder), do: :ets.delete(@resources, {:grant, receipt, holder})
  def revoke_arena(arena), do: :ets.update_element(@resources, {:arena, arena}, {5, :closed})
  def delete_arena(arena), do: :ets.delete(@resources, {:arena, arena})
  def revoke_resource_run(run), do: :ets.insert(@resources, {{:run, run}, :revoked})
  def delete_resource_run(run), do: :ets.delete(@resources, {:run, run})

  def resource_current?(receipt, lease, holder) do
    with [{{:grant, ^receipt, ^holder}, ^lease, run, arena}] <-
           :ets.lookup(@resources, {:grant, receipt, holder}),
         [{{:arena, ^arena}, ^lease, _executor, ^run, :open}] <-
           :ets.lookup(@resources, {:arena, arena}) do
      :ets.lookup(@resources, {:run, run}) == [] and execution_current?(lease) and
        Process.alive?(holder)
    else
      _ -> false
    end
  rescue
    ArgumentError -> false
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
