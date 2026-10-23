defmodule Crawler.Store.RunStatus do
  @moduledoc false

  alias Crawler.Frontier
  alias Crawler.Job.Outcome
  alias Crawler.Store.ExportRun
  alias Crawler.Store.State

  def read(state, opts, paused?) do
    scope = opts[:scope]
    generation = opts[:generation]

    with true <- not is_nil(generation) and Map.has_key?(state.scopes, scope),
         true <- State.generation(state, scope) === generation,
         %{job: job} = target <- state.scheduler.frontier.jobs[opts[:target_handle]],
         {^scope, ^generation, _queue} <- job.authority,
         true <- Map.has_key?(state.scopes[scope].work, opts[:queue]) do
      {:ok, project(state, {scope, generation}, target.outcome, paused?)}
    else
      _ -> {:error, :stale}
    end
  end

  def limit_reason({:limit, key} = reason) when is_atom(key), do: reason

  def limit_reason({:limit, {domain, key}} = reason) when is_atom(domain) and is_atom(key),
    do: reason

  def limit_reason({:deadline, kind} = reason) when kind in [:attempt, :run], do: reason
  def limit_reason(_reason), do: nil

  defp project(state, {scope, _generation} = key, outcome, paused?) do
    run = state.scopes[scope]
    automatic? = ExportRun.automatic_pending?(state, scope)

    quiescent? =
      ExportRun.quiescent?(state, key) and
        Frontier.inflight(state.scheduler.frontier, key) == 0 and not automatic?

    root = if match?(%Outcome{}, outcome), do: outcome.status
    reported = limit_reason(run.reported_limit)
    closed_limit = closed_limit(run.outcome)
    limit = closed_limit || reported || outcome_limit(outcome)
    terminal? = quiescent? and (not is_nil(root) or not is_nil(closed_limit))
    phase = phase(closed_limit, terminal?, paused?, limit, root)

    pending =
      State.count(state, :pending, scope) + Frontier.pending(state.scheduler.frontier, key)

    %{
      state: phase,
      root_status: root,
      reported_limit: reported,
      reason: limit || terminal_reason(root),
      running?: phase == :running and run.outcome == :open and not paused?,
      paused?: paused?,
      terminal?: terminal?,
      pending: if(pending == 0 and automatic?, do: 1, else: pending),
      inflight:
        State.count(state, :inflight, scope) + Frontier.inflight(state.scheduler.frontier, key)
    }
  end

  defp phase(limit, _terminal?, _paused?, _reported, _root) when not is_nil(limit),
    do: :limited

  defp phase(_closed, false, true, _limit, _root), do: :paused
  defp phase(_closed, false, false, _limit, _root), do: :running
  defp phase(_closed, true, _paused?, limit, _root) when not is_nil(limit), do: :limited
  defp phase(_closed, true, _paused?, _limit, root), do: root

  defp closed_limit({:limited, reason}), do: limit_reason(reason)
  defp closed_limit(_outcome), do: nil
  defp outcome_limit(%Outcome{status: :limited, reason: reason}), do: limit_reason(reason)
  defp outcome_limit(_outcome), do: nil

  defp terminal_reason(:failed), do: :root_failed
  defp terminal_reason(:rejected), do: :root_rejected
  defp terminal_reason(:cancelled), do: :root_cancelled
  defp terminal_reason(_status), do: nil
end
