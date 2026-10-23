defmodule Crawler.Store.CookieProof do
  @moduledoc false

  alias Crawler.Cookies
  alias Crawler.Cookies.Jar

  @derive {Inspect, only: []}
  @enforce_keys [:generation, :cookie_revision]
  defstruct [:generation, :cookie_revision]

  @opaque t :: %__MODULE__{generation: term(), cookie_revision: reference()}

  defmodule Observation do
    @moduledoc false

    @derive {Inspect, only: []}
    @enforce_keys [:proof, :verdict, :effect]
    defstruct [:proof, :verdict, :effect]
  end

  alias __MODULE__.Observation

  def outcome(state, scope) do
    case Map.get(state.cookie_outcomes, scope) do
      nil ->
        nil

      outcome ->
        Map.take(outcome, [
          :status,
          :processed,
          :expired,
          :evicted,
          :rejected,
          :unprocessed?,
          :limits
        ])
    end
  end

  # Store checks queue and execution authority before it runs these transitions.
  # Missing scopes remain unbound; observing them must never create run state.
  def snapshot(state, scope, url, generation, context, expected) do
    case bound(state, scope, generation) do
      {:ok, run} ->
        {header, state} = snapshot_jar(state, scope, url, context)
        {{:ok, header, observe(state, scope, run, expected, :unchanged)}, state}

      :unbound ->
        {{:ok, nil, unbound()}, state}

      :stale ->
        {{:error, :stale}, state}
    end
  end

  def save(state, scope, url, headers, generation, context, expected) do
    case bound(state, scope, generation) do
      {:ok, run} when is_nil(scope) ->
        {{:ok, observe(state, scope, run, expected, :unchanged)}, state}

      {:ok, run} ->
        save_bound(state, scope, url, headers, context, expected, run)

      :unbound ->
        {{:ok, unbound()}, state}

      :stale ->
        {{:error, :stale}, state}
    end
  end

  def validate(state, scope, generation, _context, expected) do
    case bound(state, scope, generation) do
      {:ok, run} ->
        state = prune(state, scope)
        {{:ok, observe(state, scope, run, expected, :unchanged)}, state}

      :unbound ->
        {{:ok, unbound()}, state}

      :stale ->
        {{:error, :stale}, state}
    end
  end

  defp bound(state, scope, generation) do
    case Map.fetch(state.scopes, scope) do
      {:ok, record} ->
        run = {state.incarnation, scope, record.revision}
        if is_nil(generation) or generation === run, do: {:ok, run}, else: :stale

      :error ->
        if is_nil(generation), do: :unbound, else: :stale
    end
  end

  defp snapshot_jar(state, nil, _url, _context), do: {nil, state}

  defp snapshot_jar(state, scope, url, context) do
    case Map.fetch(state.cookies, scope) do
      {:ok, jar} ->
        {header, pruned, work} = Cookies.header_result(jar, url, context)
        state = if work.expired > 0, do: replace(state, scope, pruned, true), else: state
        {header, state}

      :error ->
        {nil, state}
    end
  end

  defp prune(state, nil), do: state

  defp prune(state, scope) do
    case Map.fetch(state.cookies, scope) do
      {:ok, jar} ->
        {pruned, expired} = Jar.prune(jar, DateTime.utc_now())
        if expired > 0, do: replace(state, scope, pruned, true), else: state

      :error ->
        state
    end
  end

  defp save_bound(state, scope, url, headers, context, expected, run) do
    previous = Map.get(state.cookies, scope)
    {stored, outcome} = Cookies.store_result(previous, url, headers, context)

    # Compare both sides at one time, including expiry during cookie parsing.
    # Expiry belongs to the verdict; only the remaining delta is an own write.
    now = DateTime.utc_now()
    {baseline, expired} = prune_jar(previous, now)
    {stored, late_expired} = Jar.prune(stored, now)
    state = if expired > 0, do: replace(state, scope, baseline, true), else: state
    observation = observe(state, scope, run, expected, :unchanged)
    changed? = not equivalent?(baseline, stored)
    state = replace(state, scope, stored, changed?)
    outcome = %{outcome | expired: outcome.expired + late_expired}
    state = %{state | cookie_outcomes: Map.put(state.cookie_outcomes, scope, outcome)}

    observation = %{
      observation
      | proof: proof(state, scope, run),
        effect: if(changed?, do: :changed, else: :unchanged)
    }

    {{:ok, observation}, state}
  end

  defp prune_jar(nil, _now), do: {nil, 0}
  defp prune_jar(jar, now), do: Jar.prune(jar, now)

  defp equivalent?(nil, jar), do: jar.entries == %{} and jar.limits === Jar.defaults()

  defp equivalent?(left, right) do
    left.entries === right.entries and left.limits === right.limits
  end

  defp replace(state, scope, jar, changed?) do
    previous = Map.get(state.cookies, scope)

    state = %{
      state
      | cookies: Map.put(state.cookies, scope, jar),
        cookie_bytes: state.cookie_bytes + Jar.retained_cost(jar) - Jar.retained_cost(previous)
    }

    if changed? do
      record = %{Map.fetch!(state.scopes, scope) | cookie_revision: make_ref()}
      %{state | scopes: Map.put(state.scopes, scope, record)}
    else
      state
    end
  end

  defp observe(state, scope, run, expected, effect) do
    current = proof(state, scope, run)
    %Observation{proof: current, verdict: verdict(expected, current), effect: effect}
  end

  defp proof(state, scope, run) do
    %__MODULE__{
      generation: run,
      cookie_revision: Map.fetch!(state.scopes, scope).cookie_revision
    }
  end

  defp verdict(%__MODULE__{generation: run, cookie_revision: revision}, current)
       when is_reference(revision) do
    cond do
      run !== current.generation -> :unproven
      revision === current.cookie_revision -> :current
      true -> :changed
    end
  end

  defp verdict(_expected, _current), do: :unproven

  defp unbound, do: %Observation{proof: :unbound, verdict: :unproven, effect: :unchanged}
end
