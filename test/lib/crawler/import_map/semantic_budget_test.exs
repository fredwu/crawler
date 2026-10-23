defmodule Crawler.ImportMap.SemanticBudgetTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis.Budget
  alias Crawler.Analysis.Limits
  alias Crawler.ImportMap
  alias Crawler.ImportMap.JSON

  @base "https://example.test/page"

  test "invalid semantic attempts restore only their storage after unwinding" do
    {:ok, decoded} = JSON.decode_located(~s|{"imports":{"x":"./x.js"},"scopes":null}|)
    {:ok, seed} = Budget.charge(budget(), 4096, facts: 2, regions: 1)
    {:ok, seed} = Budget.reserve(seed, 700)

    assert {:error, :invalid_import_map, first} =
             ImportMap.from_located_result(decoded, @base, seed)

    assert first.retained == seed.retained
    assert first.scratch == seed.scratch
    assert first.counts == %{seed.counts | facts: 3}
    assert first.peak > seed.peak

    assert {:error, :invalid_import_map, second} =
             ImportMap.from_located_result(decoded, @base, first)

    assert second.retained == seed.retained
    assert second.scratch == seed.scratch
    assert second.counts == %{seed.counts | facts: 4}
    assert second.peak >= first.peak
    assert ImportMap.from_located(decoded, @base) == :error
    assert ImportMap.parse(~s|{"imports":{"x":"./x.js"},"scopes":null}|, @base) == :error
  end

  test "binding facts accumulate across independently affordable semantic failures" do
    {:ok, decoded} = JSON.decode_located(~s|{"imports":{"x":null},"scopes":null}|)

    assert {:error, :invalid_import_map, first} =
             ImportMap.from_located_result(decoded, @base, budget(max_facts: 1))

    assert first.counts.facts == 1

    assert {:error, {:limit, :lexical_facts}, stopped} =
             ImportMap.from_located_result(decoded, @base, first)

    assert stopped.counts.facts == 1
    assert stopped.retained == 0
    assert stopped.scratch == 0
    assert stopped.peak >= first.peak
  end

  test "first terminal Budget error precedes later semantic rejection" do
    {:ok, decoded} = JSON.decode_located(~s|{"imports":{"x":null,"y":null},"scopes":null}|)

    assert {:error, {:limit, :lexical_facts}, stopped} =
             ImportMap.from_located_result(decoded, @base, budget(max_facts: 1))

    assert stopped.counts.facts == 1
    assert stopped.retained == 0
    assert stopped.scratch == 0

    assert {:error, {:limit, :analysis_bytes}, stopped} =
             ImportMap.from_located_result(decoded, @base, budget(max_total_bytes: 1))

    assert stopped.counts.facts == 0
  end

  test "opaque URL failures remain terminal errors without a fabricated ledger" do
    {:ok, decoded} = JSON.decode_located(~s|{"imports":{"x":"./x.js"},"scopes":null}|)

    assert {:error, {:limit, :analysis_bytes}} =
             ImportMap.from_located_result(decoded, @base, budget(max_total_bytes: 10_000))
  end

  test "native success and error projections preserve duplicate and scope semantics" do
    for source <- [
          ~s|{"imports":{"x":"./old.js","x":"./new.js","blocked":null}}|,
          ~s|{"imports":{"pkg/":"./lib/"},"scopes":{"./nested/":{"x":"./scoped.js"}}}|,
          ~s|{"imports":{"":"./ignored.js","x":123},"scopes":{}}|,
          ~s|{}|,
          ~s|{"imports":null}|,
          ~s|{"scopes":false}|,
          ~s|[]|
        ] do
      {:ok, decoded} = JSON.decode_located(source)

      case ImportMap.from_located_result(decoded, @base, budget()) do
        {:ok, parsed, result} ->
          assert parsed == ImportMap.parse(source, @base)
          assert parsed == ImportMap.from_located(decoded, @base)
          assert result.scratch == 0

        {:error, :invalid_import_map, result} ->
          assert ImportMap.parse(source, @base) == :error
          assert result.retained == 0
          assert result.scratch == 0
      end
    end
  end

  defp budget(opts \\ []) do
    {:ok, limits} = Limits.new(Map.new(opts))
    Budget.new(limits)
  end
end
