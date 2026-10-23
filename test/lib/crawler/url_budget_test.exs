defmodule Crawler.URLBudgetTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis.Budget
  alias Crawler.URL

  test "rejects external base amplification before parsing or formatting" do
    base = "http://host/" <> String.duplicate("directory/", 512) <> "page"
    {result, calls} = traced(fn -> URL.resolve_result("child", base, budget(32_768)) end)
    assert result == {:error, {:limit, :analysis_bytes}}
    assert calls == []
  end

  test "reserves the output before the final URI formatter" do
    raw = "http://host/a b?x=%2F"
    {:ok, _url, ample} = URL.resolve_result(raw, nil, Budget.unlimited())
    {result, calls} = traced(fn -> URL.resolve_result(raw, nil, budget(ample.peak - 1)) end)
    assert result == {:error, {:limit, :analysis_bytes}}
    assert {URI, :parse, 1} in calls
    refute {String.Chars.URI, :to_string, 1} in calls
  end

  test "keeps merge scratch and final output live together" do
    raw = "../child?"
    base = "http://host/a/b/page"
    {:ok, _url, ample} = URL.resolve_result(raw, base, Budget.unlimited())
    {result, calls} = traced(fn -> URL.resolve_result(raw, base, budget(ample.peak - 1)) end)
    assert result == {:error, {:limit, :analysis_bytes}}
    assert {URI, :merge, 2} in calls
    refute {String.Chars.URI, :to_string, 1} in calls
  end

  test "parses each reference and base once through the canonical resolver" do
    {result, calls} =
      traced(fn ->
        URL.resolve_result("../child?", "http://host/a/page", budget(1_000_000))
      end)

    assert {:ok, "http://host/child?", %{scratch: 0}} = result
    assert Enum.count(calls, &(&1 == {URI, :parse, 1})) == 2
    assert Enum.count(calls, &(&1 == {URI, :merge, 2})) == 1
    assert Enum.count(calls, &(&1 == {String.Chars.URI, :to_string, 1})) == 1
  end

  test "settles only the owned result and preserves outer holds and counters" do
    {:ok, initial} = Budget.charge(budget(1_000_000), 123, facts: 2)
    {:ok, initial} = Budget.reserve(initial, 456)
    {:ok, url, result} = URL.resolve_result("../a%2Fb?", "http://host/dir/page", initial)
    assert url == "http://host/a%2fb?"
    assert result.retained == initial.retained + byte_size(url) + Budget.cost(:binary)
    assert result.scratch == initial.scratch
    assert result.counts == initial.counts
    assert result.peak > result.retained + result.scratch
  end

  test "carried retained URLs consume one shared allowance" do
    raw = "http://host/page"
    {:ok, _, ample} = URL.resolve_result(raw, nil, Budget.unlimited())
    {:ok, _, first} = URL.resolve_result(raw, nil, budget(ample.peak))
    assert URL.resolve_result(raw, nil, first) == {:error, {:limit, :analysis_bytes}}
    assert first.scratch == 0
  end

  test "skip releases local holds and keeps inherited ownership" do
    {:ok, initial} = Budget.charge(budget(1_000_000), 123, facts: 1)
    {:ok, initial} = Budget.reserve(initial, 456)

    for {raw, base} <- [
          {"", nil},
          {nil, "http://host/"},
          {"relative", nil},
          {"relative", %{}},
          {"mailto:x@y", "http://host/"},
          {"child", "http://host:bad/"},
          {"http://a\u200Db.com/", nil}
        ] do
      assert {:skip, result} = URL.resolve_result(raw, base, initial)
      assert result.retained == initial.retained
      assert result.scratch == initial.scratch
      assert result.counts == initial.counts
    end
  end

  test "Unicode host scratch fails before IDNA conversion" do
    raw = "http://例.com/"
    ascii = "http://a.com/"
    {:ok, _, ample} = URL.resolve_result(ascii, nil, Budget.unlimited())
    {result, calls} = traced(fn -> URL.resolve_result(raw, nil, budget(ample.peak + 10_000)) end)
    assert result == {:error, {:limit, :analysis_bytes}}
    refute {Unicode.IDNA, :to_ascii, 2} in calls
  end

  test "path scratch covers percent buffers and segment lists" do
    raw = String.duplicate("./%FF/a%2Fb/../", 32) <> "my page?x=%2E&y=\\tail"
    base = "http://127.1/a//page"
    {:ok, expected} = URL.resolve(raw, base)
    {:ok, ^expected, result} = URL.resolve_result(raw, base, budget(4_000_000))
    assert result.scratch == 0
    assert result.retained == byte_size(expected) + Budget.cost(:binary)
    assert URL.resolve_result(raw, base, budget(256)) == {:error, {:limit, :analysis_bytes}}
  end

  defp budget(limit) do
    Budget.new(%{
      max_total_bytes: limit,
      max_facts: 100,
      max_regions: 100,
      max_occurrences: 100,
      max_edits: 100
    })
  end

  defp traced(fun) do
    functions = [
      {URI, :parse, 1},
      {URI, :merge, 2},
      {String.Chars.URI, :to_string, 1},
      {Unicode.IDNA, :to_ascii, 2}
    ]

    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :go -> :ok
        end

        send(parent, {:resolved, self(), fun.()})
      end)

    for mfa <- functions, do: :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(pid, true, [:call, :arity])
    send(pid, :go)

    try do
      collect(pid, monitor, nil, [])
    after
      for mfa <- functions, do: :erlang.trace_pattern(mfa, false, [:local])
    end
  end

  defp collect(pid, monitor, result, calls) do
    receive do
      {:trace, ^pid, :call, mfa} ->
        collect(pid, monitor, result, [mfa | calls])

      {:resolved, ^pid, result} ->
        collect(pid, monitor, result, calls)

      {:DOWN, ^monitor, :process, ^pid, :normal} ->
        {result, Enum.reverse(calls)}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        flunk("resolver child failed: #{inspect(reason)}")
    after
      5_000 ->
        Process.exit(pid, :kill)
        flunk("resolver child timed out")
    end
  end
end
