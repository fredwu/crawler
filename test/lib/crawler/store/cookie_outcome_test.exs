defmodule Crawler.Store.CookieOutcomeTest do
  use ExUnit.Case, async: true

  alias Crawler.Store.CookieProof

  @fields [:status, :processed, :expired, :evicted, :rejected, :unprocessed?, :limits]

  test "absent outcomes return nil without binding a scope or creating state" do
    state = %{cookie_outcomes: %{}, scopes: %{}, cookies: %{}}
    assert CookieProof.outcome(state, :absent) == nil
    assert state == %{cookie_outcomes: %{}, scopes: %{}, cookies: %{}}
  end

  test "latest save is projected without jar, proof, credential or internal fields" do
    secret = "private-cookie-value"

    outcome =
      Map.merge(outcome(), %{header: secret, jar: secret, proof: make_ref(), credentials: secret})

    state = %{cookie_outcomes: %{scope: outcome}, cookies: %{scope: secret}}
    before = :erlang.term_to_binary(state)
    projected = CookieProof.outcome(state, :scope)

    assert projected == Map.take(outcome, @fields)
    assert Enum.sort(Map.keys(projected)) == Enum.sort(@fields)
    assert projected.limits == [:max_cookie_bytes, :max_cookie_updates]
    refute inspect(projected) =~ secret

    for _ <- 1..10, do: assert(CookieProof.outcome(state, :scope) == projected)
    assert :erlang.term_to_binary(state) == before
  end

  test "a later real save replaces the outcome and leaves another scope separate" do
    state = state()
    generation = {state.incarnation, :scope, state.scopes.scope.revision}

    {{:ok, observation}, limited} =
      CookieProof.save(
        state,
        :scope,
        "https://example.com/",
        ["a=1; Path=/", "b=2; Path=/"],
        generation,
        %{max_cookies: 1},
        :unbound
      )

    assert %{status: :limited, evicted: 1, limits: [:max_cookies]} =
             CookieProof.outcome(limited, :scope)

    {{:ok, _}, replaced} =
      CookieProof.save(
        limited,
        :scope,
        "https://example.com/",
        ["b=3; Path=/"],
        generation,
        %{max_cookies: 1},
        observation.proof
      )

    assert %{status: :ok, processed: 1, evicted: 0, limits: []} =
             CookieProof.outcome(replaced, :scope)

    assert CookieProof.outcome(replaced, :other) == outcome()
    assert CookieProof.outcome(replaced, :missing) == nil
  end

  defp outcome do
    %{
      status: :limited,
      processed: 2,
      expired: 1,
      evicted: 0,
      rejected: 1,
      unprocessed?: true,
      limits: [:max_cookie_bytes, :max_cookie_updates]
    }
  end

  defp state do
    %{
      incarnation: make_ref(),
      scopes: %{scope: %{revision: make_ref(), cookie_revision: make_ref()}},
      cookies: %{},
      cookie_bytes: 0,
      cookie_outcomes: %{other: outcome()}
    }
  end
end
