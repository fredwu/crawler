defmodule Crawler.Store.ExportSource do
  @moduledoc false

  alias Crawler.Deadline
  alias Crawler.Frontier.Ring
  alias Crawler.Store.Authority
  alias Crawler.Store.Export
  alias Crawler.Store.ExportRun
  alias Crawler.Store.Resources

  @metadata 4_096
  @batch 16

  def info(state, opts, job, receipt, epoch, from) do
    key = {opts.scope, opts.generation}
    execution = state.executions[opts.execution_lease]
    record = state.exports[key]

    with %{epoch: ^epoch, failure: nil, retired?: false} <- record,
         %{source_revision: revision} when is_reference(revision) <- execution,
         true <- Authority.resource_current?(receipt, opts.execution_lease, execution.worker),
         %{kind: :snapshot, actual: nil} <- Resources.receipt(state.resources, receipt),
         :ok <- Deadline.check(execution.deadline) do
      acquire(state, opts, job, receipt, epoch, from)
    else
      _ -> immediate(state, opts, job, receipt, epoch)
    end
  end

  defp acquire(state, opts, job, receipt, epoch, from) do
    key = {opts.scope, opts.generation}
    record = state.exports[key]
    representation = job.representation_id
    owner = record.source_owners[representation]

    cond do
      Map.has_key?(record.helper.session.manifest.responses, representation) ->
        immediate(state, opts, job, receipt, epoch)

      is_nil(owner) ->
        claim(state, opts, job, receipt, epoch)

      owner.lease === opts.execution_lease ->
        immediate(state, opts, job, receipt, epoch)

      Ring.size(owner.waiters) >= @batch ->
        {:reply, {:error, {:limit, :max_pending}}, state}

      true ->
        wait(state, opts, job, receipt, epoch, from, owner)
    end
  end

  defp claim(state, opts, job, receipt, epoch) do
    key = {opts.scope, opts.generation}

    case charge(state.exports[key]) do
      {:ok, record} ->
        owner = %{lease: opts.execution_lease, waiters: Ring.new()}

        record = %{
          record
          | source_owners: Map.put(record.source_owners, job.representation_id, owner)
        }

        state = put(state, key, record)
        state = associate(state, opts.execution_lease, key, job, epoch, :owner)
        immediate(state, opts, job, receipt, epoch)

      error ->
        {:reply, error, state}
    end
  end

  defp wait(state, opts, job, receipt, epoch, from, owner) do
    key = {opts.scope, opts.generation}
    lease = opts.execution_lease

    case charge(state.exports[key]) do
      {:ok, record} ->
        owner = %{owner | waiters: Ring.put(owner.waiters, lease)}

        record = %{
          record
          | source_owners: Map.put(record.source_owners, job.representation_id, owner),
            source_waiters: Ring.put(record.source_waiters, lease)
        }

        state =
          associate(put(state, key, record), lease, key, job, epoch, {:waiter, from, receipt})

        {:noreply, state}

      error ->
        {:reply, error, state}
    end
  end

  defp associate(state, lease, key, job, epoch, role) do
    source = %{
      run: key,
      target: job.id,
      representation: job.representation_id,
      revision: state.executions[lease].source_revision,
      epoch: epoch,
      role: role
    }

    %{
      state
      | executions: Map.update!(state.executions, lease, &Map.put(&1, :export_source, source))
    }
  end

  defp charge(record) do
    session = record.helper.session
    session = %{session | descriptor_bytes: session.descriptor_bytes + @metadata}

    case Export.put_session(record.helper, session) do
      {status, helper} when status in [:ok, :existing] -> {:ok, %{record | helper: helper}}
      error -> error
    end
  end

  def registered(state, opts, representation) do
    key = {opts.scope, opts.generation}
    record = state.exports[key]

    case record.source_owners[representation] do
      %{lease: lease, waiters: waiters} when lease === opts.execution_lease ->
        ready =
          Enum.reduce(waiters.members, record.source_ready, fn {lease, _}, ready ->
            Ring.put(ready, lease)
          end)

        record = %{
          record
          | source_owners: Map.delete(record.source_owners, representation),
            source_ready: ready
        }

        state = clear(put(state, key, record), lease)
        schedule(state, key)

      _ ->
        state
    end
  end

  def wake_all(state, key) do
    case state.exports[key] do
      nil -> state
      record -> schedule(put(state, key, %{record | source_ready: record.source_waiters}), key)
    end
  end

  defp schedule(state, key) do
    record = state.exports[key]

    if not record.source_scheduled? and Ring.size(record.source_ready) > 0 do
      send(self(), {:export_source_ready, key})
      put(state, key, %{record | source_scheduled?: true})
    else
      state
    end
  end

  def drain(state, key) do
    case state.exports[key] do
      nil ->
        state

      record ->
        state = put(state, key, %{record | source_scheduled?: false})
        state = drain(state, key, @batch)
        state |> schedule(key) |> ExportRun.source_drained(key)
    end
  end

  defp drain(state, _key, 0), do: state

  defp drain(state, key, remaining) do
    case Ring.take(state.exports[key].source_ready) do
      :empty ->
        state

      {:ok, lease, ready} ->
        record = state.exports[key]

        record = %{
          record
          | source_ready: ready,
            source_waiters: Ring.delete(record.source_waiters, lease)
        }

        state = reply(put(state, key, record), lease)
        drain(state, key, remaining - 1)
    end
  end

  defp reply(state, lease) do
    case state.executions[lease] do
      %{export_source: %{role: {:waiter, from, receipt}} = source} = execution ->
        {reply, state} = waiter_reply(state, lease, execution, source, receipt)
        GenServer.reply(from, reply)
        clear(state, lease)

      _ ->
        state
    end
  end

  defp waiter_reply(state, lease, execution, source, receipt) do
    {scope, generation} = source.run
    opts = Map.put(execution.opts, :execution_lease, lease)
    record = state.exports[source.run]

    with true <- record.epoch === source.epoch and not record.retired?,
         true <- execution.source_revision === source.revision,
         true <- Authority.current?(scope, generation, execution.opts.queue, lease),
         true <- Authority.execution_current?(lease, execution.worker),
         :ok <- Deadline.check(execution.deadline),
         %{job: job} <- state.scheduler.frontier.jobs[source.target] do
      ExportRun.target_reply(state, opts, job, receipt, {:source_info, source.epoch})
    else
      {:error, {:deadline, _}} = error -> {error, state}
      _ -> {{:error, :stale}, state}
    end
  end

  def execution_ended(state, lease) do
    case state.executions[lease] do
      %{export_source: source} -> ended(state, lease, source)
      _ -> state
    end
  end

  defp ended(state, lease, %{run: key, role: :owner} = source) do
    state = clear(state, lease)

    case state.exports[key] do
      %{source_owners: owners} ->
        case owners[source.representation] do
          %{lease: ^lease} ->
            record = state.exports[key]
            record = %{record | source_owners: Map.delete(owners, source.representation)}
            state |> put(key, record) |> ExportRun.fail(key, :source_staging_failed)

          _ ->
            state
        end

      _ ->
        state
    end
  end

  defp ended(state, lease, %{run: key, representation: representation}) do
    case state.exports[key] do
      nil ->
        clear(state, lease)

      record ->
        owners =
          case record.source_owners[representation] do
            nil ->
              record.source_owners

            owner ->
              Map.put(record.source_owners, representation, %{
                owner
                | waiters: Ring.delete(owner.waiters, lease)
              })
          end

        record = %{
          record
          | source_owners: owners,
            source_waiters: Ring.delete(record.source_waiters, lease),
            source_ready: Ring.delete(record.source_ready, lease)
        }

        clear(put(state, key, record), lease)
    end
  end

  defp clear(state, lease) do
    case state.executions[lease] do
      nil ->
        state

      execution ->
        %{
          state
          | executions: Map.put(state.executions, lease, Map.delete(execution, :export_source))
        }
    end
  end

  defp immediate(state, opts, job, receipt, epoch) do
    {reply, state} = ExportRun.target_reply(state, opts, job, receipt, {:source_info, epoch})
    {:reply, reply, state}
  end

  defp put(state, key, record), do: %{state | exports: Map.put(state.exports, key, record)}
end
