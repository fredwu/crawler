defmodule Crawler.Parser.CssSheets do
  @moduledoc false

  use GenServer

  alias Crawler.Parser.CssParser.Variables
  alias Crawler.Store.Authority
  alias Crawler.URL

  @cleanup_batch 64
  @cleanup_interval 100

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  def remember(opts, body, analysis) when is_binary(body) do
    opts = normalize(opts)

    cond do
      not stylesheet?(opts) -> :local
      not server?() -> :local
      is_nil(opts[:generation]) -> :local
      replace?(opts) -> call_sheet(opts, body, analysis, :preview)
      placeholder?(body) -> :local
      true -> call_sheet(opts, body, analysis, :remember)
    end
  end

  def remember(_opts, _body, _analysis), do: :local

  def take_urls(opts, body, span_tokens) when is_binary(body) do
    opts = normalize(opts)

    with true <- stylesheet?(opts),
         true <- server?(),
         false <- rewrite?(opts),
         {:ok, key} <- sheet_key(opts, body) do
      authorized_call(opts, {:take, key, span_tokens})
    else
      _other -> []
    end
  end

  def take_urls(_opts, _body, _span_tokens), do: []

  def replay?(opts, body) when is_binary(body) do
    opts = normalize(opts)

    with true <- stylesheet?(opts),
         true <- server?(),
         false <- placeholder?(body),
         {:ok, key} <- sheet_key(opts, body) do
      authorized_call(opts, {:replay, key})
    else
      _other -> false
    end
  end

  def replay?(_opts, _body), do: false

  @doc false
  def settle(opts) do
    opts = normalize(opts)
    urls = settle_urls(opts)

    if server?() and present_scope?(opts[:scope]) and urls != [] do
      authorized_call(opts, {:settle, scope_key(opts), urls})
    else
      []
    end
  end

  @impl GenServer
  def init(_opts) do
    schedule_cleanup()
    {:ok, %{scopes: %{}, cleanup: :queue.new()}}
  end

  @impl GenServer
  def handle_call({:authorized, scope, generation, queue, request}, _from, state) do
    if Authority.current?(scope, generation, queue) do
      {:reply, reply, next} = transition(request, state)

      if Authority.current?(scope, generation, queue) do
        {:reply, reply, next}
      else
        {:reply, rejected(request), state}
      end
    else
      {:reply, rejected(request), state}
    end
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    state = cleanup(state, min(@cleanup_batch, map_size(state.scopes)))
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval)

  defp transition(request, state) do
    handle_request(request, state)
  rescue
    error in Variables.LimitError -> {:reply, {:error, error}, state}
  end

  defp cleanup(state, 0), do: state

  defp cleanup(state, remaining) do
    {{:value, {scope, generation} = key}, queue} = :queue.out(state.cleanup)

    state =
      if Authority.current?(scope, generation, nil) do
        %{state | cleanup: :queue.in(key, queue)}
      else
        %{state | scopes: Map.delete(state.scopes, key), cleanup: queue}
      end

    cleanup(state, remaining - 1)
  end

  defp handle_request({:remember, key, analysis, request_url}, state) do
    state = put_analysis(state, key, analysis, request_url)
    {:reply, {:ok, sheet_tokens(state, key)}, state}
  end

  defp handle_request({:preview, key, analysis, request_url}, state) do
    preview = put_analysis(state, key, analysis, request_url)
    {:reply, {:ok, sheet_tokens(preview, key)}, state}
  end

  defp handle_request({:settle, scope, urls}, state) do
    {fresh, state} = settle_scope(state, scope, urls)
    {:reply, fresh, state}
  end

  defp handle_request({:replay, {scope, group_id, sheet_id, _base}}, state) do
    sheets = state |> group(scope, group_id) |> Map.fetch!(:sheets)
    {:reply, not Map.has_key?(sheets, sheet_id), state}
  end

  defp handle_request({:take, {scope, group_id, _sheet_id, base}, span_tokens}, state) do
    group = group(state, scope, group_id)
    sheets = ordered(group)
    {fresh, covered} = fresh_urls(sheets, span_tokens, base, group)

    state =
      put_emitted(
        state,
        scope,
        group_id,
        MapSet.union(group.emitted, MapSet.union(covered, MapSet.new(fresh)))
      )

    {:reply, fresh, state}
  end

  defp call_sheet(opts, body, analysis, action) do
    case sheet_key(opts, body) do
      {:ok, key} -> authorized_call(opts, {action, key, analysis, opts[:url]})
      :skip -> :local
    end
  end

  defp authorized_call(opts, request) do
    if is_nil(opts[:generation]) do
      rejected(request)
    else
      case GenServer.call(
             __MODULE__,
             {:authorized, opts[:scope], opts[:generation], opts[:queue], request}
           ) do
        {:error, %Variables.LimitError{} = error} -> raise error
        reply -> reply
      end
    end
  end

  defp rejected({action, _key, _analysis, _url}) when action in [:remember, :preview],
    do: {:ok, []}

  defp rejected({:replay, _key}), do: false
  defp rejected(_request), do: []

  defp put_analysis(state, {scope, group_id, sheet_id, base}, analysis, request_url) do
    state = insert(state, scope, group_id, sheet_id, base, analysis)
    note_pending(state, scope, group_id, base, analysis, request_url)
  end

  defp note_pending(state, scope, group_id, base, analysis, request_url) do
    failed = failed_urls(state, scope)

    update_in(state, [:scopes, scope, :groups, group_id], fn group ->
      remember_imports(group, base, analysis, request_url, failed)
    end)
  end

  defp remember_imports(group, base, analysis, request_url, failed) do
    joined = group.joined |> put_url(base) |> put_url(request_url)
    known = MapSet.union(known_bases(group), joined)

    pending =
      group.pending
      |> MapSet.union(import_urls(analysis, base, known))
      |> MapSet.difference(failed)
      |> MapSet.difference(joined)

    %{group | pending: pending, joined: joined}
  end

  defp failed_urls(state, scope) do
    state |> Map.fetch!(:scopes) |> Map.fetch!(scope) |> Map.fetch!(:failed)
  end

  defp known_bases(group) do
    group.sheets
    |> Map.keys()
    |> MapSet.new(&elem(&1, 0))
  end

  defp import_urls(analysis, base, known) do
    analysis.resources
    |> Enum.flat_map(&import_value/1)
    |> Enum.map(&resolve_one(&1, base))
    |> Enum.reject(&skip_import?(&1, known))
    |> MapSet.new()
  end

  defp skip_import?(nil, _known), do: true
  defp skip_import?(url, known), do: MapSet.member?(known, url)

  defp import_value(%{kind: :import, value: value}) when is_binary(value) and value != "",
    do: [value]

  defp import_value(_resource), do: []

  defp put_url(urls, url) when is_binary(url) and url != "", do: MapSet.put(urls, url)
  defp put_url(urls, _url), do: urls

  defp sheet_tokens(state, {scope, group_id, sheet_id, _base}) do
    group = group(state, scope, group_id)
    group |> ordered() |> Variables.variable_spans(sheet_id, allow_fallbacks?(group))
  end

  defp insert(state, scope, group_id, sheet_id, base, analysis) do
    scopes =
      Map.update(
        state.scopes,
        scope,
        new_scope(group_id, sheet_id, base, analysis),
        &update_scope(&1, group_id, sheet_id, base, analysis)
      )

    cleanup =
      if Map.has_key?(state.scopes, scope),
        do: state.cleanup,
        else: :queue.in(scope, state.cleanup)

    %{state | scopes: scopes, cleanup: cleanup}
  end

  defp new_scope(group_id, sheet_id, base, analysis) do
    %{
      groups: %{group_id => put_sheet(empty_group(), sheet_id, base, analysis)},
      failed: MapSet.new()
    }
  end

  defp update_scope(scope_state, group_id, sheet_id, base, analysis) do
    groups =
      Map.update(
        scope_state.groups,
        group_id,
        put_sheet(empty_group(), sheet_id, base, analysis),
        fn group ->
          put_sheet(group, sheet_id, base, analysis)
        end
      )

    %{scope_state | groups: groups}
  end

  defp put_sheet(group, sheet_id, base, analysis) do
    if Map.has_key?(group.sheets, sheet_id) do
      existing = Map.fetch!(group.sheets, sheet_id)
      sheet = Variables.sheet(analysis, sheet_id, base, existing.order)
      %{group | sheets: Map.put(group.sheets, sheet_id, sheet)}
    else
      sheet = Variables.sheet(analysis, sheet_id, base, group.next)

      %{
        group
        | sheets: Map.put(group.sheets, sheet_id, sheet),
          order: group.order ++ [sheet_id],
          next: group.next + 1
      }
    end
  end

  defp fresh_urls(sheets, span_tokens, base, group) do
    covered = covered_urls(span_tokens, base)

    fresh =
      sheets
      |> Variables.all_pictures(allow_fallbacks?(group))
      |> Enum.map(&resolve_picture/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reject(fn url ->
        MapSet.member?(covered, url) or MapSet.member?(group.emitted, url)
      end)

    {fresh, covered}
  end

  defp covered_urls(span_tokens, base) do
    span_tokens
    |> Enum.map(& &1.value)
    |> resolve_values(base)
    |> MapSet.new()
  end

  defp resolve_values(values, base) do
    values
    |> Enum.map(&resolve_one(&1, base))
    |> Enum.reject(&is_nil/1)
  end

  defp resolve_picture(%{token: %{value: value}, base_url: base}), do: resolve_one(value, base)
  defp resolve_picture(_picture), do: nil

  defp resolve_one(value, base) do
    cond do
      not is_binary(value) or value == "" -> nil
      not is_binary(base) or base == "" -> nil
      fragment?(value) -> nil
      data_url?(value) -> nil
      true -> resolve_url(value, base)
    end
  end

  defp resolve_url(value, base) do
    case URL.resolve(value, base) do
      {:ok, url} -> url
      :skip -> nil
    end
  end

  defp ordered(group), do: Enum.map(group.order, &Map.fetch!(group.sheets, &1))

  defp group(state, scope, group_id) do
    get_in(state, [:scopes, scope, :groups, group_id]) || empty_group()
  end

  defp put_emitted(state, scope, group_id, emitted) do
    if get_in(state, [:scopes, scope, :groups, group_id]) do
      update_in(state, [:scopes, scope, :groups, group_id], &%{&1 | emitted: emitted})
    else
      state
    end
  end

  defp empty_group do
    %{
      sheets: %{},
      order: [],
      next: 0,
      emitted: MapSet.new(),
      pending: MapSet.new(),
      joined: MapSet.new()
    }
  end

  defp settle_urls(opts) do
    [opts[:url], opts[:referrer_url]]
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
  end

  defp settle_scope(state, scope, urls) do
    case get_in(state, [:scopes, scope]) do
      nil ->
        {[], state}

      scope_state ->
        scope_state = mark_failed(scope_state, urls)
        {fresh, groups} = settle_groups(scope_state.groups, urls)

        {Enum.uniq(fresh), put_in(state, [:scopes, scope], %{scope_state | groups: groups})}
    end
  end

  defp mark_failed(scope_state, urls) do
    %{scope_state | failed: MapSet.union(scope_state.failed, MapSet.new(urls))}
  end

  defp settle_groups(groups, urls) do
    Enum.reduce(groups, {[], %{}}, fn {id, group}, {fresh, acc} ->
      {extra, group} = settle_group(group, urls)
      {fresh ++ extra, Map.put(acc, id, group)}
    end)
  end

  defp settle_group(group, urls) do
    pending = Enum.reduce(urls, group.pending, &MapSet.delete(&2, &1))
    cleared = %{group | pending: pending}

    if release_fallbacks?(group.pending, pending) do
      release_fallbacks(cleared)
    else
      {[], cleared}
    end
  end

  defp release_fallbacks?(pending, next) do
    MapSet.size(pending) > 0 and MapSet.size(next) == 0
  end

  defp release_fallbacks(group) do
    {fresh, _covered} = fresh_urls(ordered(group), [], nil, group)
    emitted = MapSet.union(group.emitted, MapSet.new(fresh))
    {fresh, %{group | emitted: emitted}}
  end

  defp allow_fallbacks?(%{pending: pending}), do: MapSet.size(pending) == 0

  defp sheet_key(opts, body) do
    scope = opts[:scope]
    group = group_id(opts)
    base = sheet_base(opts)

    if present_scope?(scope) and present?(group) and present?(base) do
      {:ok, {scope_key(opts), group, {base, :erlang.phash2(body), byte_size(body)}, base}}
    else
      :skip
    end
  end

  defp scope_key(opts), do: {opts[:scope], opts[:generation]}

  defp group_id(opts), do: first_of(opts[:style_group], opts[:document_url], opts[:url])
  defp sheet_base(opts), do: first_of(opts[:referrer_url], opts[:url])

  defp first_of(first, second, third) do
    cond do
      present?(first) -> first
      present?(second) -> second
      present?(third) -> third
      true -> nil
    end
  end

  defp first_of(first, second) do
    if present?(first), do: first, else: second
  end

  defp stylesheet?(opts), do: Map.get(opts, :mode, :stylesheet) == :stylesheet
  defp rewrite?(opts), do: opts[:css_sheet] == :rewrite
  defp replace?(opts), do: opts[:css_sheet] == :replace
  defp placeholder?(body), do: String.contains?(body, <<0>>)
  defp server?, do: Process.whereis(__MODULE__) != nil
  defp present?(value) when is_binary(value) and value != "", do: true
  defp present?(_value), do: false
  defp present_scope?(nil), do: false
  defp present_scope?(""), do: false
  defp present_scope?(_scope), do: true
  defp fragment?(value), do: value |> String.trim() |> String.starts_with?("#")
  defp data_url?(value), do: Regex.match?(~r/^\s*data:/i, value)

  defp normalize(opts) when is_list(opts), do: Map.new(opts)
  defp normalize(opts) when is_map(opts), do: opts
  defp normalize(_opts), do: %{}
end
