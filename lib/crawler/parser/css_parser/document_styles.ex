defmodule Crawler.Parser.CssParser.DocumentStyles do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.HTMLReferences
  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Parser.CssParser.Variables

  def new(elements, base, limits \\ []) do
    sheets =
      elements
      |> Enum.filter(&stylesheet?/1)
      |> Enum.with_index()
      |> Enum.map(fn {element, order} ->
        analysis = Scanner.analyze(Enum.join(element.children))
        Variables.sheet(analysis, element.span, base, order)
      end)

    sheets |> from_sheets(limits) |> complete!()
  end

  def from_sheets(sheets, limits \\ []) do
    {:ok, context, _budget} = from_sheets_result(sheets, limits, Budget.unlimited())
    context
  end

  def from_sheets_result(sheets, limits, budget) do
    count = length(sheets)
    scratch = 512 + Budget.cost(:list_cell, 8 * count)

    with {:ok, budget} <- Budget.reserve(budget, scratch),
         {:ok, budget} <-
           Budget.charge(budget, Budget.cost(:context) + Budget.cost(:map_entry, count)) do
      sheets = Enum.sort_by(sheets, & &1.order)

      with {:ok, outcome, budget} <- Variables.analyze_result(sheets, true, limits, budget) do
        context = %{sheets: Map.new(sheets, &{&1.id, &1}), outcome: outcome, limits: limits}
        with {:ok, budget} <- Budget.release(budget, scratch), do: {:ok, context, budget}
      end
    end
  end

  def snapshot(context), do: context.outcome

  def tokens(context, sheet_id, analysis) do
    context = complete!(context)

    case Map.fetch(context.sheets, sheet_id) do
      {:ok, original} ->
        preview = Variables.sheet(analysis, sheet_id, original.base, original.order)

        pictures =
          if preview == original,
            do: context.outcome.pictures,
            else: pictures(Map.put(context.sheets, sheet_id, preview), context.limits)

        Variables.picture_spans(pictures, sheet_id)

      :error ->
        sheet = Variables.sheet(analysis, :local, :local, 0)
        Variables.picture_spans(pictures(%{local: sheet}, context.limits), :local)
    end
  end

  defp pictures(sheets, limits) do
    context = sheets |> Map.values() |> from_sheets(limits) |> complete!()
    context.outcome.pictures
  end

  defp complete!(context) do
    Variables.pictures!(context.outcome)
    context
  end

  defp stylesheet?(%{name: "style", namespace: namespace, attributes: attrs})
       when namespace in [:html, :svg],
       do: HTMLReferences.css_style_element?(attrs)

  defp stylesheet?(_element), do: false
end
