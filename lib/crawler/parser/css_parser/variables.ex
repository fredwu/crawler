defmodule Crawler.Parser.CssParser.Variables do
  @moduledoc false

  alias Crawler.Parser.CssParser.VariableGraph
  alias Crawler.URL

  defmodule LimitError do
    @moduledoc false

    defexception [:limit]

    @impl true
    def message(%{limit: limit}), do: "CSS graph exceeded #{limit} limit"
  end

  def sheet(analysis, id, base, order) do
    %{
      id: id,
      base: base,
      order: order,
      bindings: tag(analysis.bindings, id, base),
      registrations: tag(analysis.registrations, id, base),
      uses: tag(analysis.uses, id, base)
    }
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
    pictures
    |> Enum.filter(&span_on?(&1, sheet_id))
    |> Enum.map(& &1.token)
    |> Enum.uniq_by(fn token -> {token.start, token.length} end)
  end

  def analyze(sheets, fallbacks? \\ true, opts \\ []) do
    VariableGraph.run(sheets, fallbacks?, opts)
  end

  def all_pictures(sheets, fallbacks? \\ true) do
    sheets |> analyze(fallbacks?) |> pictures!()
  end

  def pictures!(%{status: :ok, pictures: pictures}), do: pictures
  def pictures!(%{status: {:limited, limit}}), do: raise(LimitError, limit: limit)

  defp span_on?(picture, sheet_id) do
    picture.token_sheet == sheet_id and same_fetch?(picture)
  end

  defp same_fetch?(%{token_base: base, base_url: base}) when not is_nil(base), do: true

  defp same_fetch?(%{token: %{value: value}, token_base: token_base, base_url: base_url})
       when is_binary(value) and is_binary(token_base) and is_binary(base_url) do
    same_url?(resolved_url(value, token_base), resolved_url(value, base_url))
  end

  defp same_fetch?(_picture), do: false

  defp same_url?(url, url) when is_binary(url), do: true
  defp same_url?(_left, _right), do: false

  defp resolved_url(value, base) do
    case URL.resolve(value, base) do
      {:ok, url} -> url
      :skip -> nil
    end
  end

  defp tag(items, id, base) do
    Enum.map(items, &Map.merge(&1, %{sheet_id: id, base: base}))
  end
end
