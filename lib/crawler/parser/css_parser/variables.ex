defmodule Crawler.Parser.CssParser.Variables do
  @moduledoc false

  alias Crawler.Analysis.Budget
  alias Crawler.Parser.CssParser.VariableGraph
  alias Crawler.URL

  defmodule LimitError do
    @moduledoc false

    defexception [:limit]

    @impl true
    def message(%{limit: limit}), do: "CSS graph exceeded #{limit} limit"
  end

  def sheet(analysis, id, base, order) do
    {:ok, sheet, _budget} = sheet_result(analysis, id, base, order, Budget.unlimited())
    sheet
  end

  def sheet_result(analysis, id, base, order, budget) do
    budget = take!(Budget.charge(budget, Budget.cost(:context)))
    {bindings, budget} = tag(analysis.bindings, id, base, budget)
    {registrations, budget} = tag(analysis.registrations, id, base, budget)
    {uses, budget} = tag(analysis.uses, id, base, budget)

    {:ok,
     %{
       id: id,
       base: base,
       order: order,
       bindings: bindings,
       registrations: registrations,
       uses: uses
     }, budget}
  catch
    {:css_budget, reason} -> {:error, reason}
  end

  def span_tokens(analysis) do
    sheet = sheet(analysis, :local, :local, 0)
    variable_spans([sheet], :local, true)
  end

  def variable_spans(sheets, sheet_id, fallbacks? \\ true) do
    sheets
    |> all_pictures(fallbacks?)
    |> picture_spans(sheet_id)
  end

  def picture_spans(pictures, sheet_id) do
    {:ok, tokens, _budget} = picture_spans_result(pictures, sheet_id, Budget.unlimited())
    tokens
  end

  def picture_spans_result(pictures, sheet_id, budget) do
    budget = take!(Budget.reserve(budget, 512))

    {tokens, _seen, budget, held} =
      Enum.reduce(pictures, {[], MapSet.new(), budget, 512}, fn picture,
                                                                {tokens, seen, budget, held} ->
        {same?, budget} =
          if picture.token_sheet == sheet_id,
            do: same_fetch_result(picture, budget),
            else: {false, budget}

        if same? do
          token = picture.token
          identity = {token.start, token.length}

          if MapSet.member?(seen, identity) do
            {tokens, seen, budget, held}
          else
            bytes = Budget.cost(:map_entry) + Budget.cost(:list_cell) + 64
            budget = take!(Budget.reserve(budget, bytes))
            budget = take!(Budget.charge(budget, Budget.cost(:list_cell)))
            {[token | tokens], MapSet.put(seen, identity), budget, held + bytes}
          end
        else
          {tokens, seen, budget, held}
        end
      end)

    tokens = Enum.reverse(tokens)
    {:ok, tokens, take!(Budget.release(budget, held))}
  catch
    {:css_budget, reason} -> {:error, reason}
  end

  def analyze(sheets, fallbacks? \\ true, opts \\ []) do
    {:ok, outcome, _budget} = analyze_result(sheets, fallbacks?, opts, Budget.unlimited())
    outcome
  end

  def analyze_result(sheets, fallbacks?, opts, budget),
    do: VariableGraph.run_result(sheets, fallbacks?, opts, budget)

  def all_pictures(sheets, fallbacks? \\ true) do
    sheets |> analyze(fallbacks?) |> pictures!()
  end

  def pictures!(%{status: :ok, pictures: pictures}), do: pictures
  def pictures!(%{status: {:limited, limit}}), do: raise(LimitError, limit: limit)

  defp same_fetch_result(%{token_base: base, base_url: base}, budget) when not is_nil(base),
    do: {true, budget}

  defp same_fetch_result(
         %{token: %{value: value}, token_base: token_base, base_url: base_url},
         budget
       )
       when is_binary(value) and is_binary(token_base) and is_binary(base_url) do
    before = budget.retained
    {left, budget} = resolved_url_result(value, token_base, budget)
    {right, budget} = resolved_url_result(value, base_url, budget)
    same? = is_binary(left) and left == right
    {same?, take!(Budget.refund(budget, budget.retained - before))}
  end

  defp same_fetch_result(_picture, budget), do: {false, budget}

  defp resolved_url_result(value, base, budget) do
    case URL.resolve_result(value, base, budget) do
      {:ok, url, budget} -> {url, budget}
      {:skip, budget} -> {nil, budget}
      {:error, reason} -> throw({:css_budget, reason})
    end
  end

  defp tag(items, id, base, budget) do
    {tagged, budget, scratch} =
      Enum.reduce(items, {[], budget, 0}, fn item, {acc, budget, scratch} ->
        budget =
          take!(
            Budget.charge(
              budget,
              Budget.cost(:context) + Budget.cost(:map_entry, 2) + Budget.cost(:list_cell),
              facts: 1
            )
          )

        budget = take!(Budget.reserve(budget, Budget.cost(:list_cell)))

        {[Map.merge(item, %{sheet_id: id, base: base}) | acc], budget,
         scratch + Budget.cost(:list_cell)}
      end)

    tagged = Enum.reverse(tagged)
    {tagged, take!(Budget.release(budget, scratch))}
  end

  defp take!({:ok, budget}), do: budget
  defp take!({:error, reason}), do: throw({:css_budget, reason})
end
