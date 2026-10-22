defmodule Crawler.Parser.CssParser.Variables do
  @moduledoc false

  alias Crawler.URL

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
    |> Enum.filter(&span_on?(&1, sheet_id))
    |> Enum.map(& &1.token)
    |> Enum.uniq_by(fn token -> {token.start, token.length} end)
  end

  def all_pictures(sheets, fallbacks? \\ true) do
    Enum.flat_map(sheets, fn sheet ->
      Enum.flat_map(sheet.uses, &pictures(&1, sheets, fallbacks?))
    end)
  end

  def pictures(use, sheets, fallbacks? \\ true) do
    case resolve(use.name, use.sheet_id, use.rule_id, sheets, MapSet.new(), fallbacks?) do
      {:set, pictures} -> pictures
      :unset -> deferred_use(use, sheets, fallbacks?)
    end
  end

  defp deferred_use(_use, _sheets, false), do: []
  defp deferred_use(use, sheets, true), do: unset_pictures(use, sheets)

  defp unset_pictures(use, sheets) do
    ctx = fallback_ctx(use.sheet_id, use.base, use.sheet_id, use.base, use.sheet_id, use.rule_id)
    registered_or_fallback(use.name, use.fallback, ctx, sheets, MapSet.new(), true)
  end

  defp resolve(name, use_sheet, use_rule, sheets, seen, fallbacks?) do
    if MapSet.member?(seen, name) do
      {:set, []}
    else
      case winning(name, use_sheet, use_rule, sheets) do
        nil ->
          :unset

        binding ->
          seen = MapSet.put(seen, name)
          {:set, from_binding(binding, use_sheet, use_rule, sheets, seen, fallbacks?)}
      end
    end
  end

  defp from_binding(binding, use_sheet, use_rule, sheets, seen, fallbacks?) do
    base_id = base_sheet(binding, use_sheet, sheets)
    resolved_base = sheet_base(sheets, base_id, binding.base)

    direct =
      Enum.map(binding.urls, &picture(&1, binding.sheet_id, binding.base, base_id, resolved_base))

    aliases =
      alias_pictures(
        binding,
        use_sheet,
        use_rule,
        sheets,
        seen,
        base_id,
        resolved_base,
        fallbacks?
      )

    direct ++ aliases
  end

  defp alias_pictures(binding, use_sheet, use_rule, sheets, seen, base_id, base_url, fallbacks?) do
    ctx = fallback_ctx(binding.sheet_id, binding.base, base_id, base_url, use_sheet, use_rule)
    alias_values(binding.aliases, ctx, sheets, seen, fallbacks?)
  end

  defp registered_or_fallback(name, fallback, ctx, sheets, seen, fallbacks?) do
    case last_registration(name, sheets) do
      %{syntax_url?: true, initial: token, sheet_id: id} = registration
      when not is_nil(token) ->
        [picture(token, id, registration.base, id)]

      _other ->
        fallback_value(fallback, ctx, sheets, MapSet.put(seen, name), fallbacks?)
    end
  end

  defp fallback_value(nil, _ctx, _sheets, _seen, _fallbacks?), do: []

  defp fallback_value(fallback, ctx, sheets, seen, fallbacks?) do
    url_pictures(fallback.urls, ctx) ++
      alias_values(fallback.aliases, ctx, sheets, seen, fallbacks?)
  end

  defp url_pictures(urls, ctx), do: Enum.map(urls, &url_picture(&1, ctx))

  defp url_picture(token, ctx) do
    picture(token, ctx.token_sheet, ctx.token_base, ctx.base_id, ctx.base_url)
  end

  defp alias_values(aliases, ctx, sheets, seen, fallbacks?) do
    Enum.flat_map(aliases, &alias_value(&1, ctx, sheets, seen, fallbacks?))
  end

  defp alias_value(%{name: name, fallback: fallback}, ctx, sheets, seen, fallbacks?) do
    case resolve(name, ctx.use_sheet, ctx.use_rule, sheets, seen, fallbacks?) do
      {:set, pictures} -> pictures
      :unset -> deferred_unset(name, fallback, ctx, sheets, seen, fallbacks?)
    end
  end

  defp deferred_unset(_name, _fallback, _ctx, _sheets, _seen, false), do: []

  defp deferred_unset(name, fallback, ctx, sheets, seen, true) do
    registered_or_fallback(name, fallback, ctx, sheets, seen, true)
  end

  defp fallback_ctx(token_sheet, token_base, base_id, base_url, use_sheet, use_rule) do
    %{
      token_sheet: token_sheet,
      token_base: token_base,
      base_id: base_id,
      base_url: base_url,
      use_sheet: use_sheet,
      use_rule: use_rule
    }
  end

  defp picture(token, token_sheet, token_base, base_id) do
    picture(token, token_sheet, token_base, base_id, token_base)
  end

  defp picture(token, token_sheet, token_base, base_id, base_url) do
    %{
      token: Map.put(token, :kind, Map.get(token, :kind, :url)),
      token_sheet: token_sheet,
      token_base: token_base,
      base_sheet: base_id,
      base_url: base_url
    }
  end

  defp base_sheet(binding, use_sheet, sheets) do
    if registered?(binding.name, sheets), do: binding.sheet_id, else: use_sheet
  end

  defp sheet_base(sheets, base_id, fallback) do
    case Enum.find(sheets, &(&1.id == base_id)) do
      %{base: base} -> base
      nil -> fallback
    end
  end

  defp registered?(name, sheets) do
    case last_registration(name, sheets) do
      %{syntax_url?: true} -> true
      _other -> false
    end
  end

  defp last_registration(name, sheets) do
    sheets
    |> Enum.flat_map(&indexed(&1.registrations, &1.order))
    |> Enum.filter(fn {_order, _index, registration} -> registration.name == name end)
    |> last_entry()
  end

  defp winning(name, use_sheet, use_rule, sheets) do
    entries =
      Enum.flat_map(sheets, fn sheet ->
        indexed(sheet.bindings, sheet.order)
      end)

    named = Enum.filter(entries, fn {_order, _index, binding} -> binding.name == name end)
    local = Enum.filter(named, fn {_order, _index, binding} -> binding.sheet_id == use_sheet end)

    same_rule =
      Enum.filter(local, fn {_order, _index, binding} -> binding.rule_id == use_rule end)

    last_entry(chosen_bindings(same_rule, local, named))
  end

  defp chosen_bindings([_ | _] = same_rule, _local, _named), do: same_rule
  defp chosen_bindings(_same_rule, [_ | _] = local, _named), do: local
  defp chosen_bindings(_same_rule, _local, named), do: named

  defp indexed(items, order) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {item, index} -> {order, index, item} end)
  end

  defp last_entry([]), do: nil

  defp last_entry(entries) do
    {_order, _index, item} = Enum.max_by(entries, fn {order, index, _item} -> {order, index} end)
    item
  end

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
