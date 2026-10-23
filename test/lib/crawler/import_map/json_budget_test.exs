defmodule Crawler.ImportMap.JSONBudgetTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis.Budget
  alias Crawler.ImportMap.JSON

  test "the shared fact quota covers array roots and every child" do
    source = "[" <> Enum.map_join(1..128, ",", fn _ -> "0" end) <> "]"

    assert {:error, {:limit, :lexical_facts}, %Budget{}} =
             JSON.decode_located_result(source, budget(max_facts: 2))
  end

  test "fields and string segments consume facts even when duplicate keys collapse" do
    for source <- [~S({"a":0,"a":1}), ~S("a\nb\tc")] do
      assert {:error, {:limit, :lexical_facts}, %Budget{}} =
               JSON.decode_located_result(source, budget(max_facts: 3))
    end
  end

  test "fact exhaustion stops before the remaining malformed string is read" do
    assert {:error, {:limit, :lexical_facts}, %Budget{}} =
             JSON.decode_located_result(~S([0,"unterminated), budget(max_facts: 2))
  end

  test "a returned budget remains shared across subsequent reads" do
    assert {:ok, 0, residual} = JSON.decode_located_result("0", budget(max_facts: 1))

    assert {:error, {:limit, :lexical_facts}, %Budget{}} =
             JSON.decode_located_result("0", residual)
  end

  test "strings and collection scratch stop at the byte allowance" do
    for source <- [
          "\"" <> String.duplicate("x", 4096) <> "\"",
          "\"" <> String.duplicate(~S(\u0061), 1024) <> "\"",
          "[" <> Enum.map_join(1..128, ",", fn _ -> "0" end) <> "]",
          "{" <> Enum.map_join(1..128, ",", fn i -> "\"k#{i}\":0" end) <> "}"
        ] do
      assert {:error, {:limit, :analysis_bytes}, %Budget{}} =
               JSON.decode_located_result(source, budget(max_total_bytes: 1024))
    end
  end

  test "bounded success retains the exact located AST and standalone shapes" do
    source = "\uFEFF " <> ~S({"a":"old","b":false,"\u0061":["é","\u0061"]})
    assert {:ok, located} = JSON.decode_located_result(source)
    assert {:ok, ^located, _residual} = JSON.decode_located_result(source, budget())
    assert JSON.decode_located(source) == {:ok, located}
    assert JSON.decode(source) == {:ok, {:object, [{"a", ["é", "a"]}, {"b", false}]}}
    assert {:object, [{"a", [{:str, "é", 35, 4}, {:str, "a", 40, 8}]}, {"b", false}]} = located
  end

  test "native limits keep their reasons with a sufficient shared allowance" do
    fixtures = [
      max_depth: String.duplicate("[", 129) <> "?",
      max_string_bytes: "\"" <> String.duplicate("x", 1_048_577) <> "\"",
      max_tokens: "[" <> Enum.map_join(1..100_000, ",", fn _ -> "0" end) <> "]",
      max_number_bytes: String.duplicate("9", 1025),
      max_input_bytes: String.duplicate(" ", 10_485_761)
    ]

    for {key, source} <- fixtures do
      assert {:ok, initial} = Budget.charge(budget(), 4096, facts: 2)
      assert {:ok, initial} = Budget.reserve(initial, 700)
      assert {:error, {:limit, ^key}, residual} = JSON.decode_located_result(source, initial)
      assert residual.retained == initial.retained
      assert residual.scratch == initial.scratch
      assert residual.peak >= initial.peak
      assert residual.counts.facts >= initial.counts.facts
    end
  end

  test "bounded grammar failures remain distinct" do
    for source <- [nil, "{", "[1,]", ~S("\q"), ~S("\uD800"), "01", "1e"] do
      assert {:error, :invalid_json, %Budget{}} = JSON.decode_located_result(source, budget())
    end
  end

  test "completed containers preserve parent scratch and expose string overlap" do
    initial = budget()
    assert {:ok, initial} = Budget.reserve(initial, 700)
    source = ~S({"key":["raw\nescaped",123]})
    assert {:ok, _located, residual} = JSON.decode_located_result(source, initial)
    assert residual.scratch == 700
    assert residual.retained > initial.retained + byte_size(source)
    assert residual.peak > residual.retained + residual.scratch
    assert residual.counts.facts == 9
  end

  test "numeric temporary storage uses the same allowance before conversion" do
    assert {:error, {:limit, :analysis_bytes}, %Budget{}} =
             JSON.decode_located_result(
               String.duplicate("9", 1024),
               budget(max_total_bytes: 1024)
             )

    assert {:ok, :non_finite, residual} = JSON.decode_located_result("1e309", budget())
    assert residual.scratch == 0
    assert residual.peak > residual.retained
  end

  test "every grammar failure returns the latest ledger after local values cease to be live" do
    assert {:ok, initial} = Budget.charge(budget(), 4096, facts: 2)
    assert {:ok, initial} = Budget.reserve(initial, 700)

    fixtures = [
      nil,
      "",
      "?",
      "{",
      ~S({"key"),
      ~S({"key" 0}),
      ~S({"key":0 ?}),
      "[0 ?]",
      "[0,]",
      ~S("\q"),
      ~S("\uD800"),
      ~S("\uDC00"),
      ~S("\uZZZZ"),
      ~S("\uD800\uZZZZ"),
      ~S("\uD800\u0041"),
      "\"unterminated",
      "\"a\n",
      "\"a" <> <<255>>,
      "01",
      "1e",
      ~S({"key":[true,false]} trailing),
      ~S("raw\nescaped\t\q")
    ]

    for source <- fixtures do
      assert {:error, :invalid_json, residual} = JSON.decode_located_result(source, initial)
      assert residual.retained == initial.retained
      assert residual.scratch == initial.scratch
      assert residual.caps == initial.caps
      assert residual.limit == initial.limit
      assert residual.peak >= initial.peak
      assert residual.counts.facts >= initial.counts.facts
      if is_binary(source), do: assert(residual.counts.facts > initial.counts.facts)
      assert JSON.decode_located_result(source) == {:error, :invalid_json}
      assert JSON.decode_located(source) == :error
      assert JSON.decode(source) == :error
    end
  end

  test "recovered syntax errors accumulate facts and retain prior peaks across reads" do
    assert {:ok, initial} = Budget.charge(budget(max_facts: 9), 4096, facts: 1)
    assert {:ok, initial} = Budget.reserve(initial, 700)
    assert {:error, :invalid_json, first} = JSON.decode_located_result("[0,0,]", initial)
    assert first.counts.facts == 5
    assert {:error, :invalid_json, second} = JSON.decode_located_result("[0,0,]", first)
    assert second.counts.facts == 9
    assert {:error, {:limit, :lexical_facts}, exhausted} = JSON.decode_located_result("?", second)
    assert exhausted.counts == second.counts
    assert exhausted.peak >= second.peak
    assert exhausted.retained == initial.retained
    assert exhausted.scratch == initial.scratch

    source = "[\"" <> String.duplicate("x", 10_000) <> "\",]"
    assert {:error, :invalid_json, high} = JSON.decode_located_result(source, budget())
    assert high.retained == 0
    assert high.scratch == 0
    assert high.peak > 10_000
    assert {:ok, false, resumed} = JSON.decode_located_result("false", high)
    assert resumed.peak == high.peak
    assert resumed.counts.facts == high.counts.facts + 1
  end

  test "terminal failures clean local allocations without changing first-error priority" do
    assert {:ok, initial} = Budget.charge(budget(max_facts: 4), 4096, facts: 2)
    assert {:ok, initial} = Budget.reserve(initial, 700)

    assert {:error, {:limit, :lexical_facts}, residual} =
             JSON.decode_located_result(~S([0,"unterminated), initial)

    assert residual.counts.facts == 4
    assert residual.retained == initial.retained
    assert residual.scratch == initial.scratch
    assert residual.peak > initial.peak

    assert {:error, :invalid_json, syntax} =
             JSON.decode_located_result("?" <> String.duplicate("x", 100), initial)

    assert syntax.counts.facts == 3

    assert {:error, {:limit, :max_input_bytes}, unchanged} =
             JSON.decode_located_result(String.duplicate(" ", 10_485_761), residual)

    assert unchanged == residual
  end

  defp budget(opts \\ []) do
    limits = [
      max_total_bytes: 100_000_000,
      max_facts: 1_000_000,
      max_regions: 1000,
      max_occurrences: 1000,
      max_edits: 1000
    ]

    Budget.new(Map.new(Keyword.merge(limits, opts)))
  end
end

defmodule Crawler.ImportMap.JSONBudgetStopTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis.Budget
  alias Crawler.ImportMap.JSON

  test "the parser constructs no next value after the aggregate fact cap" do
    call = {JSON, :parse_value, 5}
    :erlang.trace_pattern(call, true, [:local, :call_count])

    try do
      budget =
        Budget.new(%{
          max_total_bytes: 100_000,
          max_facts: 2,
          max_regions: 1,
          max_occurrences: 1,
          max_edits: 1
        })

      source = "[0," <> String.duplicate("\"x\",", 128) <> "?]"

      assert {:error, {:limit, :lexical_facts}, %Budget{}} =
               JSON.decode_located_result(source, budget)

      assert {:call_count, 2} = :erlang.trace_info(call, :call_count)
    after
      :erlang.trace_pattern(call, false, [:local, :call_count])
    end
  end

  test "byte exhaustion stops a raw string scan within its reserved allowance" do
    call = {JSON, :raw_chunk, 6}
    :erlang.trace_pattern(call, true, [:local, :call_count])

    try do
      budget =
        Budget.new(%{
          max_total_bytes: 1024,
          max_facts: 1000,
          max_regions: 1,
          max_occurrences: 1,
          max_edits: 1
        })

      source = "\"" <> String.duplicate("a", 8192) <> "\""

      assert {:error, {:limit, :analysis_bytes}, %Budget{}} =
               JSON.decode_located_result(source, budget)

      assert {:call_count, calls} = :erlang.trace_info(call, :call_count)
      assert calls > 0
      assert calls < 1024
    after
      :erlang.trace_pattern(call, false, [:local, :call_count])
    end
  end
end
