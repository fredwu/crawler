defmodule Crawler.Export.Producer do
  @moduledoc false

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Deadline
  alias Crawler.Dispatcher
  alias Crawler.Export.Runtime
  alias Crawler.Export.Runtime.Context
  alias Crawler.Export.Stage
  alias Crawler.Parser
  alias Crawler.Parser.CssSheets
  alias Crawler.Store
  alias Crawler.Store.Authority

  def managed?(opts), do: Authority.export_managed?(opts[:scope], opts[:generation])

  def direct(prepared, credit), do: produce(prepared, credit, :direct)

  def refresh(opts) do
    if managed?(opts) do
      with_runtime(opts, fn runtime, export -> refresh_all(runtime, export.epoch) end)
    else
      :ok
    end
  end

  def discover(prepared, credit, control?) do
    if managed?(prepared.opts) do
      produce(prepared, credit, if(control?, do: :control, else: :discover))
    else
      unless control?, do: Parser.emit(prepared, &dispatch_reference/2)
      :ok
    end
  end

  defp dispatch_reference(request, opts) do
    result = Dispatcher.dispatch(request, opts)

    case result do
      {:error, {kind, _} = reason} when kind in [:limit, :deadline] ->
        Store.report_run_limit(reason)

      _ ->
        :ok
    end

    result
  end

  defp produce(prepared, credit, mode) do
    opts = prepared.opts

    with_runtime(opts, fn runtime, export ->
      with :ok <- discovery_mode(export.assignment, mode),
           :ok <- Stage.source(runtime, prepared, credit, export.assignment),
           :ok <- stage_current(runtime, prepared, credit, mode),
           :ok <- refresh_all(runtime, export.epoch),
           do: Store.arm_export(opts, export.epoch)
    end)
  end

  defp with_runtime(opts, consume) do
    with_context(opts, fn export ->
      with {:ok, filesystem} <- Store.export_filesystem(opts, export.epoch) do
        Runtime.with_io(Context.new(opts, export.epoch, export.job, filesystem), fn runtime ->
          consume.(runtime, export)
        end)
      end
    end)
  end

  defp discovery_mode(%{discovery_mode: :fetch}, :direct), do: :ok
  defp discovery_mode(%{discovery_mode: :parse}, mode) when mode in [:discover, :control], do: :ok
  defp discovery_mode(_assignment, _mode), do: {:error, :discovery_context_mismatch}

  defp refresh_all(runtime, epoch) do
    with :ok <- Deadline.check(runtime.context.opts.crawler_deadline) do
      case Store.export_refresh_batch(runtime.context.opts, epoch) do
        {:ok, batch, receipt} ->
          {result, released} =
            try do
              result =
                Stage.refresh(runtime, batch, fn row, replay, credit, consume ->
                  refresh_row(runtime, row, replay, credit, consume)
                end)

              {result, Store.release_export_refresh(runtime.context.opts, epoch, receipt)}
            catch
              kind, reason ->
                Store.release_export_refresh(runtime.context.opts, epoch, receipt)
                :erlang.raise(kind, reason, __STACKTRACE__)
            after
              Store.release_resource(receipt)
            end

          case {result, released} do
            {{:ok, visited}, {:ok, _}} when visited > 0 -> refresh_all(runtime, epoch)
            {:superseded, {:ok, true}} -> refresh_all(runtime, epoch)
            {:superseded, {:ok, false}} -> :ok
            {_, {:error, _} = error} -> error
            {other, _} -> other
          end

        status when status in [:waiting, :done] ->
          :ok

        error ->
          error
      end
    end
  end

  defp refresh_row(runtime, row, replay, credit, consume) do
    mode =
      cond do
        row.assignment.discovery_mode == :fetch -> :direct
        Map.get(replay.bound, :control_document, false) === true -> :control
        true -> :discover
      end

    opts =
      row.assignment.dispatch_context
      |> Map.merge(replay.analysis.source_options)
      |> Map.merge(
        Map.take(runtime.context.opts, [
          :scope,
          :generation,
          :queue,
          :execution_lease,
          :scheduler_claim,
          :crawler_deadline,
          :scheduler_kind
        ])
      )
      |> Map.put(:source_revision, replay.source_revision)

    with_continuation(
      opts,
      credit,
      replay.bound.budget,
      fn budget ->
        with {:ok, groups} <-
               Analysis.css_groups_result(%{replay.analysis | budget: budget}, opts),
             do: {:ok, groups, groups.budget}
      end,
      fn groups, credit ->
        with {:ok, css} <- CssSheets.resolve_groups(opts, groups.groups) do
          prepare_refresh(opts, replay, groups, css, credit, mode, consume)
        end
      end
    )
  end

  defp prepare_refresh(opts, replay, groups, css, credit, mode, consume) do
    with_continuation(
      opts,
      credit,
      groups.budget,
      fn budget ->
        with {:ok, prepared} <-
               Parser.prepare_collection(replay.analysis, opts, css, %{groups | budget: budget}),
             do: {:ok, prepared, prepared.collection.budget}
      end,
      fn prepared, credit ->
        prepared = control_result(prepared, replay.bound)
        with_bindings(prepared, mode, replay.bound, &consume.(prepared, credit, &1))
      end
    )
  end

  defp control_result(prepared, %{control_document: result}) when is_boolean(result),
    do: %{prepared | collection: Map.put(prepared.collection, :control_document, result)}

  defp control_result(prepared, _previous), do: prepared

  defp with_continuation(opts, credit, budget, build, consume) do
    available = Budget.available(budget)

    with {:ok, receipt, capacity} <- Store.reserve_resource_up_to(opts, :analysis, available) do
      try do
        with {:ok, seed} <- Budget.charge(budget, available - capacity),
             {:ok, value, updated} <- build.(seed),
             :ok <- Store.commit_resource(receipt, updated.retained - seed.retained) do
          credit = %{
            credit
            | retained: credit.retained ++ [receipt],
              unavailable: credit.unavailable + available - capacity
          }

          consume.(value, credit)
        end
      after
        Store.release_resource(receipt)
      end
    end
  end

  defp stage_current(runtime, prepared, credit, mode) do
    with_context(prepared.opts, fn export ->
      prepared = %{
        prepared
        | opts: Map.merge(prepared.opts, export.assignment.dispatch_context)
      }

      with_bindings(prepared, mode, fn bindings ->
        staged(Stage.stage(runtime, prepared, credit, export.assignment, bindings))
      end)
    end)
  end

  defp staged({:ok, _version}), do: :ok
  defp staged(other), do: other

  defp with_context(opts, consume) do
    case Store.export_context(opts) do
      {:ok, %{context_receipt: receipt} = export} ->
        try do
          consume.(export)
        after
          Store.release_resource(receipt)
        end

      {:ok, nil} ->
        {:error, :missing_export}

      error ->
        error
    end
  end

  defp with_bindings(prepared, mode, consume), do: with_bindings(prepared, mode, nil, consume)

  defp with_bindings(_prepared, mode, _previous, consume) when mode in [:direct, :control],
    do: consume.(%{})

  defp with_bindings(prepared, :discover, previous, consume) do
    previous_count = if previous, do: length(previous.occurrences), else: 0
    bytes = 4_096 + 2_048 * length(prepared.occurrences) + 512 * previous_count

    with {:ok, receipt} <- Store.reserve_resource(prepared.opts, :analysis, bytes) do
      try do
        collect_bindings(prepared, previous, consume)
      after
        Store.release_resource(receipt)
      end
    end
  end

  defp collect_bindings(prepared, previous, consume) do
    key = {__MODULE__, make_ref()}
    reused = reusable_bindings(prepared, previous)
    Process.put(key, reused)

    try do
      prepared = pending_callbacks(prepared, reused)

      result =
        Parser.emit_bound(prepared, &Dispatcher.dispatch/2, fn occurrence, raw ->
          target = accepted_target(raw)
          Process.put(key, Map.put(Process.get(key), occurrence.id, target))
          :ok
        end)

      case result do
        {:error, _} = error -> error
        _results -> consume.(Process.get(key))
      end
    after
      Process.delete(key)
    end
  end

  defp reusable_bindings(_prepared, nil), do: %{}

  defp reusable_bindings(prepared, previous) do
    indexed = Map.new(previous.occurrences, &{&1.id, &1})

    Enum.reduce(prepared.occurrences, %{}, fn occurrence, found ->
      reuse_binding(occurrence, indexed[occurrence.id], found)
    end)
  end

  defp reuse_binding(_occurrence, nil, found), do: found

  defp reuse_binding(occurrence, old, found) do
    if %{old | target: nil} === occurrence,
      do: Map.put(found, occurrence.id, old.target),
      else: found
  end

  defp pending_callbacks(%{groups: []} = prepared, _reused), do: prepared

  defp pending_callbacks(prepared, reused) do
    members =
      Map.new(prepared.callback_members, fn {id, ids} ->
        {id, Enum.reject(ids, &Map.has_key?(reused, &1))}
      end)

    %{
      prepared
      | groups: pending_groups(prepared.groups, members, reused),
        callback_members: members
    }
  end

  defp pending_groups(groups, members, reused) do
    Enum.flat_map(groups, fn
      {:entry, id} = group ->
        if pending_member?(id, members, reused), do: [group], else: []

      {:element, ids, children} ->
        [
          {:element, Enum.filter(ids, &pending_member?(&1, members, reused)),
           pending_groups(children, members, reused)}
        ]
    end)
  end

  defp pending_member?(id, members, reused),
    do: Map.get(members, id, if(Map.has_key?(reused, id), do: [], else: [id])) != []

  defp accepted_target({:ok, %{target_handle: target}}) when is_reference(target), do: target
  defp accepted_target(_result), do: nil
end
