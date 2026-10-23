defmodule Crawler.Analysis.CSS do
  @moduledoc false
  alias Crawler.Analysis.Budget
  alias Crawler.Parser.CssParser.DocumentStyles
  alias Crawler.Parser.CssParser.Variables

  def sheets(analysis, ids, bases) do
    {:ok, sheets, _budget} = sheets_result(analysis, ids, bases, Budget.unlimited())
    sheets
  end

  def sheets_result(analysis, ids, bases, budget, eligible \\ fn _ -> true end) do
    ids
    |> Enum.reduce_while({:ok, [], budget, 0}, fn id, {:ok, sheets, budget, order} ->
      region = analysis.regions[id]

      if region.kind == :css and eligible.(region) do
        with {:ok, sheet, budget} <-
               Variables.sheet_result(region.facts, id, Map.get(bases, id), order, budget),
             {:ok, budget} <-
               Budget.charge(
                 budget,
                 Budget.cost(:list_cell, length(region.facts.resources)) + Budget.cost(:map_entry)
               ) do
          imports = Enum.filter(region.facts.resources, &(Map.get(&1, :kind) == :import))
          {:cont, {:ok, [Map.put(sheet, :imports, imports) | sheets], budget, order + 1}}
        else
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, sheets, budget, order + 1}}
      end
    end)
    |> case do
      {:ok, sheets, budget, _order} -> {:ok, Enum.reverse(sheets), budget}
      error -> error
    end
  end

  def snapshot(analysis, sheets, opts) do
    with {:ok, snapshot, _budget} <- snapshot_result(analysis, sheets, opts, Budget.unlimited()),
         do: {:ok, snapshot}
  end

  def snapshot_result(_analysis, _sheets, %{managed_css_snapshot: true} = opts, budget),
    do:
      {:ok,
       %{
         tokens: Map.get(opts, :css_tokens, %{}),
         references: Map.get(opts, :css_references, %{}),
         revision: opts[:css_revision]
       }, budget}

  def snapshot_result(analysis, sheets, opts, budget) do
    revision =
      opts[:css_revision] ||
        {:local, analysis.revision, opts[:document_url], opts[:document_base]}

    limits = [
      graph_revision: revision,
      max_work: opts[:max_css_work] || analysis.limits.max_facts,
      max_pictures:
        min(
          opts[:max_css_pictures] || analysis.limits.max_occurrences,
          analysis.limits.max_occurrences
        ),
      max_depth: opts[:max_css_depth] || 256
    ]

    with true <-
           Enum.all?(Keyword.take(limits, [:max_work, :max_pictures, :max_depth]), fn {_key, n} ->
             is_integer(n) and n > 0
           end) || {:error, :invalid_limits},
         {:ok, context, budget} <- DocumentStyles.from_sheets_result(sheets, limits, budget) do
      case DocumentStyles.snapshot(context) do
        %{status: :ok, pictures: pictures} ->
          with {:ok, budget} <-
                 Budget.charge(
                   budget,
                   Budget.cost(:list_cell, length(pictures)) +
                     Budget.cost(:map_entry, length(sheets) * 3)
                 ) do
            grouped = Enum.group_by(pictures, & &1.token_sheet)

            sheets
            |> Enum.reduce_while({:ok, %{}, %{}, budget}, fn sheet,
                                                             {:ok, tokens, extras, budget} ->
              snapshot_sheet(sheet, grouped, tokens, extras, budget)
            end)
            |> case do
              {:ok, tokens, references, budget} ->
                {:ok, %{tokens: tokens, references: references, revision: revision}, budget}

              error ->
                error
            end
          end

        %{status: {:limited, limit}} ->
          {:error, {:limit, {:css_graph, limit}}}
      end
    end
  end

  defp snapshot_sheet(sheet, grouped, tokens, extras, budget) do
    own = Map.get(grouped, sheet.id, [])

    case Variables.picture_spans_result(own, sheet.id, budget) do
      {:ok, spans, budget} ->
        with {:ok, budget} <-
               Budget.charge(
                 budget,
                 Budget.cost(:map_entry, length(spans)) +
                   Budget.cost(:list_cell, length(own))
               ) do
          covered = MapSet.new(spans)
          extra = Enum.reject(own, &MapSet.member?(covered, &1.token))

          {:cont,
           {:ok, Map.put(tokens, sheet.id, spans), Map.put(extras, sheet.id, extra), budget}}
        else
          error -> {:halt, error}
        end

      error ->
        {:halt, error}
    end
  end
end
