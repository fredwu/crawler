defmodule Crawler.Store.PageCandidates do
  @moduledoc false

  alias Crawler.Store.Aliases
  alias Crawler.Store.DB
  alias Crawler.Store.Page
  alias Crawler.Store.ResourceManager
  alias Crawler.Store.State

  @slots [:source_page, :alias_page]

  def stage(state, key, body, opts, worker, lease) do
    with {:ok, claim, slot} <- recording_slot(state, key, opts, worker, lease),
         [{_, %Page{storage_revision: revision} = previous}] <- Registry.lookup(DB, key),
         true <- is_reference(revision) and Aliases.completed?(state, key) do
      page = %Page{
        url: previous.url,
        body: body,
        opts: opts,
        target_handle: opts.target_handle,
        processed: previous.processed,
        fetch_tag: previous.fetch_tag,
        picture_type: previous.picture_type,
        storage_revision: revision
      }

      candidate = %{key: key, expected: revision, page: page}
      state = retain(state, candidate, :issued)
      state = release_slot(state, claim, slot)
      record = Map.put(state.scheduler_workers[claim], slot, candidate)
      {:staged, %{state | scheduler_workers: Map.put(state.scheduler_workers, claim, record)}}
    else
      _ -> :immediate
    end
  end

  def complete(state, claim, job) do
    {scope, generation, queue} = job.authority

    accepted? =
      State.current?(state, scope, generation) and State.queue_active?(state, scope, queue) and
        match?(%{status: :succeeded}, Crawler.Frontier.outcome(state.scheduler.frontier, job.id))

    Enum.reduce(@slots, state, fn slot, state ->
      state = if accepted?, do: promote(state, claim, slot), else: state
      release_slot(state, claim, slot)
    end)
  end

  def release(state, claim), do: Enum.reduce(@slots, state, &release_slot(&2, claim, &1))

  defp recording_slot(state, {logical, scope}, opts, worker, lease) do
    with %{
           worker: ^worker,
           source_revision: revision,
           physical_final_url: final,
           opts: %{scheduler_claim: claim}
         } <- state.executions[lease],
         true <- not is_nil(revision) and revision === opts[:source_revision],
         %{worker: owner, job: job} <- state.scheduler_workers[claim],
         %{status: {:running, ^claim}} <- state.scheduler.frontier.jobs[job.id],
         true <- owner === worker or state.execution_claims[claim] === lease,
         true <- job.authority === {scope, opts[:generation], opts[:queue]},
         true <- opts[:target_handle] === job.id do
      cond do
        logical === job.logical_key ->
          {:ok, claim, :source_page}

        is_binary(final) and logical === Crawler.URL.canonical(final) ->
          {:ok, claim, :alias_page}

        true ->
          :immediate
      end
    else
      _ -> :immediate
    end
  end

  defp promote(state, claim, slot) do
    case state.scheduler_workers[claim][slot] do
      %{page: %Page{processed: true}} = candidate -> promote_candidate(state, candidate)
      _ -> state
    end
  end

  defp promote_candidate(state, %{key: key, expected: expected, page: page} = candidate) do
    case Registry.lookup(DB, key) do
      [{_, %Page{storage_revision: ^expected, opts: old_opts}}] ->
        state = retain(state, candidate, :ordinary)
        Registry.update_value(DB, key, fn _ -> %{page | storage_revision: make_ref()} end)

        Enum.reduce(
          ResourceManager.page_receipts(old_opts),
          state,
          &ResourceManager.release_persistent(&2, &1)
        )

      _ ->
        state
    end
  end

  defp retain(state, %{key: {_, scope}, page: page}, role) do
    Enum.reduce(
      ResourceManager.page_receipts(page.opts),
      state,
      &ResourceManager.retain_persistent(&2, &1, scope, role)
    )
  end

  defp release_slot(state, claim, slot) do
    case state.scheduler_workers[claim] do
      %{^slot => %{page: page}} = record ->
        state = %{
          state
          | scheduler_workers: Map.put(state.scheduler_workers, claim, Map.delete(record, slot))
        }

        Enum.reduce(
          ResourceManager.page_receipts(page.opts),
          state,
          &ResourceManager.release_persistent(&2, &1, :issued)
        )

      _ ->
        state
    end
  end
end
