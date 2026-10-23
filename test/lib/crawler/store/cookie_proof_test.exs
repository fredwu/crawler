defmodule Crawler.Store.CookieProofTest do
  use ExUnit.Case, async: true

  alias Crawler.Cookies
  alias Crawler.Cookies.Jar
  alias Crawler.Store.CookieProof
  alias Crawler.Store.CookieProof.Observation

  @scope "scope"
  @url "https://example.com/start"

  test "unbound operations do not create any run, jar or outcome metadata" do
    state = state([])

    assert {{:ok, nil, %Observation{proof: :unbound, verdict: :unproven, effect: :unchanged}},
            ^state} = CookieProof.snapshot(state, @scope, @url, nil, %{}, :unbound)

    assert {{:ok, %Observation{proof: :unbound, verdict: :unproven, effect: :unchanged}}, ^state} =
             CookieProof.validate(state, @scope, nil, %{}, :unbound)

    assert {{:ok, %Observation{proof: :unbound, verdict: :unproven, effect: :unchanged}}, ^state} =
             CookieProof.save(state, @scope, @url, ["id=1"], nil, %{}, :unbound)
  end

  test "a bound empty run attests its existing revision without inserting an empty jar" do
    state = state()
    run = generation(state)

    assert {{:ok, nil, %Observation{proof: proof, verdict: :unproven, effect: :unchanged}},
            ^state} = CookieProof.snapshot(state, @scope, @url, run, %{}, :unbound)

    assert %CookieProof{generation: ^run} = proof
    assert proof.cookie_revision == state.scopes[@scope].cookie_revision

    assert {{:ok, %Observation{proof: ^proof, verdict: :current, effect: :unchanged}}, ^state} =
             CookieProof.validate(state, @scope, run, %{}, proof)

    assert state.cookies == %{}
    assert state.cookie_outcomes == %{}
    assert state.cookie_bytes == 0
  end

  test "a bound nil scope attests empty state and preserves ignored cookie writes" do
    state = state([nil])
    run = generation(state, nil)

    assert {{:ok, nil, %Observation{proof: proof}}, ^state} =
             CookieProof.snapshot(state, nil, @url, run, %{}, :unbound)

    assert {{:ok, %Observation{proof: ^proof, verdict: :current, effect: :unchanged}}, ^state} =
             CookieProof.save(state, nil, @url, ["id=1"], run, %{}, proof)

    assert {{:ok, %Observation{proof: ^proof, verdict: :current}}, ^state} =
             CookieProof.validate(state, nil, run, %{}, proof)
  end

  test "explicit stale generations leave every transition unchanged" do
    state = state()
    stale = {state.incarnation, @scope, make_ref()}

    assert {{:error, :stale}, ^state} =
             CookieProof.snapshot(state, @scope, @url, stale, %{}, :unbound)

    assert {{:error, :stale}, ^state} =
             CookieProof.save(state, @scope, @url, ["id=1"], stale, %{}, :unbound)

    assert {{:error, :stale}, ^state} =
             CookieProof.validate(state, @scope, stale, %{}, :unbound)

    absent = state([])

    assert {{:error, :stale}, ^absent} =
             CookieProof.validate(absent, @scope, stale, %{}, :unbound)
  end

  test "proofs do not cross scope, generation or Store incarnation boundaries" do
    state = state([@scope, "other", 1, 1.0])
    {initial, state} = snapshot(state)

    for scope <- ["other", 1, 1.0] do
      assert {{:ok, %Observation{verdict: :unproven}}, ^state} =
               CookieProof.validate(state, scope, generation(state, scope), %{}, initial.proof)
    end

    {integer, state} = snapshot(state, 1)

    assert {{:ok, %Observation{verdict: :unproven}}, ^state} =
             CookieProof.validate(state, 1.0, generation(state, 1.0), %{}, integer.proof)

    restarted = %{state | incarnation: make_ref()}

    assert {{:ok, %Observation{verdict: :unproven}}, ^restarted} =
             CookieProof.validate(restarted, @scope, generation(restarted), %{}, initial.proof)
  end

  test "own writes compare the expected proof first and return the final proof" do
    {initial, state} = snapshot(state())
    {written, state} = save(state, ["id=one; Path=/"], initial.proof)

    assert written.verdict == :current
    assert written.effect == :changed
    refute written.proof == initial.proof

    assert {{:ok, %Observation{verdict: :current, proof: proof}}, ^state} =
             CookieProof.validate(state, @scope, generation(state), %{}, written.proof)

    assert proof == written.proof

    assert {{:ok, %Observation{verdict: :changed, effect: :unchanged}}, ^state} =
             CookieProof.validate(state, @scope, generation(state), %{}, initial.proof)
  end

  test "future path cookies change proof even when initial Cookie remains empty" do
    {initial, state} = snapshot(state())
    {first, state} = save(state, ["id=A; Path=/private"], initial.proof)

    assert {{:ok, nil, %Observation{proof: proof_a}}, ^state} =
             CookieProof.snapshot(state, @scope, @url, generation(state), %{}, first.proof)

    {second, state} = save(state, ["id=B; Path=/private"], proof_a)
    assert second.verdict == :current
    assert second.effect == :changed

    assert {{:ok, nil, %Observation{verdict: :changed}}, ^state} =
             CookieProof.snapshot(state, @scope, @url, generation(state), %{}, proof_a)

    assert {{:ok, "id=B", %Observation{verdict: :changed}}, ^state} =
             CookieProof.snapshot(
               state,
               @scope,
               "https://example.com/private",
               generation(state),
               %{},
               proof_a
             )
  end

  test "accepted exact no-ops and rejected updates preserve the proof" do
    {initial, state} = snapshot(state())
    {written, state} = save(state, ["id=good; Path=/"], initial.proof)

    for {headers, context} <- [
          {["id=good; Path=/"], %{}},
          {["invalid"], %{}},
          {["missing=1; Max-Age=0; Path=/"], %{}},
          {["id=bad; Secure; Path=/"], %{credentials: :omit}},
          {["id=bad; Path=/"], %{credentials: :same_origin, site: "https://foreign.test/"}},
          {["id=bad; Domain=foreign.test; Path=/"], %{}}
        ] do
      {observation, next} = save(state, headers, written.proof, context)
      assert observation.verdict == :current
      assert observation.effect == :unchanged
      assert observation.proof == written.proof
      assert next.cookie_bytes == state.cookie_bytes
    end
  end

  test "an expiry extension and an effective policy change rotate the proof" do
    {initial, state} = snapshot(state())

    {first, state} =
      save(state, ["id=1; Expires=01 Jan 2040 00:00:00 GMT; Path=/"], initial.proof)

    {extended, state} =
      save(state, ["id=1; Expires=01 Jan 2050 00:00:00 GMT; Path=/"], first.proof)

    assert extended.verdict == :current
    assert extended.effect == :changed
    refute extended.proof == first.proof

    {policy, state} = save(state, [], extended.proof, %{max_cookies: 2})
    assert policy.verdict == :current
    assert policy.effect == :changed

    {same_policy, _state} = save(state, [], policy.proof, %{max_cookies: 2})
    assert same_policy.effect == :unchanged
    assert same_policy.proof == policy.proof
  end

  test "snapshot and validate prune before comparison and preserve the last limit outcome" do
    {initial, state} = snapshot(state())

    {written, state} =
      save(state, ["a=1; Path=/", "b=2; Path=/"], initial.proof, %{max_cookies: 1})

    assert state.cookie_outcomes[@scope].status == :limited
    expired = expire_fixture(state)
    outcome = expired.cookie_outcomes[@scope]

    for operation <- [:snapshot, :validate] do
      {observation, pruned} =
        case operation do
          :snapshot ->
            {{:ok, nil, observation}, next} =
              CookieProof.snapshot(expired, @scope, @url, generation(expired), %{}, written.proof)

            {observation, next}

          :validate ->
            {{:ok, observation}, next} =
              CookieProof.validate(expired, @scope, generation(expired), %{}, written.proof)

            {observation, next}
        end

      assert observation.verdict == :changed
      assert observation.effect == :unchanged
      refute observation.proof == written.proof
      assert pruned.cookie_outcomes[@scope] == outcome
      assert pruned.cookies[@scope].entries == %{}
      assert pruned.cookie_bytes == Jar.retained_cost(pruned.cookies[@scope])
      assert pruned.cookie_bytes < expired.cookie_bytes
    end
  end

  test "a write reports prior expiry separately from its own effect" do
    {initial, state} = snapshot(state())
    {written, state} = save(state, ["id=1; Path=/"], initial.proof)
    state = expire_fixture(state)
    {expired, pruned} = save(state, [], written.proof)

    assert expired.verdict == :changed
    assert expired.effect == :unchanged
    assert pruned.cookie_outcomes[@scope].expired == 1

    {replaced, _state} = save(state, ["id=2; Path=/"], written.proof)
    assert replaced.verdict == :changed
    assert replaced.effect == :changed
  end

  test "retained byte deltas include other scopes and detached header backing" do
    state = state([@scope, "other"])
    {initial, state} = snapshot(state)
    {written, state} = save(state, ["other=1; Path=/"], :unbound, %{}, "other")
    other_bytes = Jar.retained_cost(state.cookies["other"])
    assert state.cookie_bytes == other_bytes
    assert written.verdict == :unproven

    source = "id=" <> String.duplicate("v", 160) <> "; Path=/"
    backing = String.duplicate("x", 2_000_000) <> source
    header = binary_part(backing, 2_000_000, byte_size(source))
    {_written, state} = save(state, [header], initial.proof)
    [cookie] = Cookies.entries(state.cookies[@scope])

    assert :binary.referenced_byte_size(cookie.value) == 160
    assert state.cookie_bytes == other_bytes + Jar.retained_cost(state.cookies[@scope])

    {_deleted, state} = save(state, ["id=1; Max-Age=0; Path=/"], :unbound)
    assert state.cookie_bytes == other_bytes + Jar.retained_cost(state.cookies[@scope])
  end

  test "repeated changes retain one revision and cannot revive an old proof" do
    {initial, state} = snapshot(state())

    state =
      Enum.reduce(1..200, state, fn n, state ->
        {_observation, state} = save(state, ["id=#{n}; Path=/"], :unbound)
        state
      end)

    assert {{:ok, %Observation{verdict: :changed}}, ^state} =
             CookieProof.validate(state, @scope, generation(state), %{}, initial.proof)

    assert map_size(state.scopes) == 1
    assert map_size(state.cookies) == 1
    assert map_size(state.cookie_outcomes) == 1
    assert Enum.sort(Map.keys(state.scopes[@scope])) == [:cookie_revision, :revision]
    assert map_size(state.cookies[@scope].entries) == 1
  end

  test "unknown observations fail closed and inspection reveals no proof fields" do
    secret = "scope-secret"
    state = state([secret])
    run = generation(state, secret)

    for expected <- [:unbound, nil, %{}, %CookieProof{generation: run, cookie_revision: nil}] do
      assert {{:ok, %Observation{verdict: :unproven}}, ^state} =
               CookieProof.validate(state, secret, run, %{}, expected)
    end

    {observation, _state} = snapshot(state, secret)
    refute inspect(observation) =~ secret
    refute inspect(observation.proof) =~ secret
    refute inspect(observation) =~ "cookie_revision"
    refute inspect(observation.proof) =~ "generation"
    refute inspect(observation, structs: false) == inspect(observation)
  end

  defp state(scopes \\ [@scope]) do
    %{
      incarnation: make_ref(),
      scopes: Map.new(scopes, &{&1, %{revision: make_ref(), cookie_revision: make_ref()}}),
      cookies: %{},
      cookie_outcomes: %{},
      cookie_bytes: 0,
      untouched: :preserved
    }
  end

  defp generation(state, scope \\ @scope) do
    {state.incarnation, scope, state.scopes[scope].revision}
  end

  defp snapshot(state, scope \\ @scope) do
    {{:ok, _header, observation}, state} =
      CookieProof.snapshot(state, scope, @url, generation(state, scope), %{}, :unbound)

    {observation, state}
  end

  defp save(state, headers, expected, context \\ %{}, scope \\ @scope) do
    {{:ok, observation}, state} =
      CookieProof.save(state, scope, @url, headers, generation(state, scope), context, expected)

    {observation, state}
  end

  defp expire_fixture(state) do
    jar = state.cookies[@scope]
    [cookie] = Cookies.entries(jar)

    {expired, 0, _limits} =
      Jar.put(jar, %{cookie | expires_at: DateTime.add(DateTime.utc_now(), -1, :second)})

    %{
      state
      | cookies: Map.put(state.cookies, @scope, expired),
        cookie_bytes: state.cookie_bytes + Jar.retained_cost(expired) - Jar.retained_cost(jar)
    }
  end
end
