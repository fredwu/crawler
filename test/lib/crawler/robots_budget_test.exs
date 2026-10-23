defmodule Crawler.RobotsBudgetTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis.Budget
  alias Crawler.Robots

  test "header and meta effects share the same residual fact allowance" do
    tags = [meta("robots", "nofollow")]
    opts = %{headers: [{"x-robots-tag", "index"}]}

    assert {:error, {:limit, :lexical_facts}} =
             Robots.nofollow_result(tags, opts, budget(max_facts: 8))

    assert {:ok, true, residual} = Robots.nofollow_result(tags, opts, budget(max_facts: 9))
    assert residual.counts.facts == 9
    assert {:error, {:limit, :lexical_facts}} = Robots.nofollow_result([], opts, residual)
  end

  test "page and agent directives preserve comma and first-colon semantics" do
    fixtures = [
      {"nofollow", true},
      {"NONE", true},
      {"index,nofollow", true},
      {"googlebot: nofollow", false},
      {"crawler: none", true},
      {"crawler: noindex, nofollow", true},
      {"crawler: nofollow:extra", false},
      {"crawler: noindex,googlebot: none", false},
      {" crawler : nofollow ", true}
    ]

    for {content, expected} <- fixtures do
      opts = %{headers: [{"X-Robots-Tag", content}], user_agent: "Crawler/1"}
      assert {:ok, ^expected, _budget} = Robots.nofollow_result([], opts, budget())
      assert Robots.header_nofollow?(opts.headers, opts.user_agent) == expected
      assert Robots.meta_nofollow_tags?([meta("robots", content)], opts.user_agent) == expected
    end
  end

  test "matching uses every product token while ignoring URL words" do
    ua = "Mozilla/5.0 (compatible; Crawler/1; https://github.com/fredwu/crawler)"

    for {name, expected} <- [
          {"mozilla", true},
          {"crawler", true},
          {"5", true},
          {"github", false},
          {"https", false},
          {"fredwu", false}
        ] do
      opts = %{headers: [{"x-robots-tag", name <> ": nofollow"}], user_agent: ua}
      assert {:ok, ^expected, _budget} = Robots.nofollow_result([], opts, budget())

      assert {:ok, ^expected, _budget} =
               Robots.nofollow_result([meta(name, "nofollow")], %{user_agent: ua}, budget())
    end
  end

  test "inactive meta tags stay inert and eligible names retain normalization" do
    for flags <- [%{closing?: true}, %{in_template?: true}, %{in_shadow_root?: true}] do
      assert {:ok, false, _budget} =
               Robots.nofollow_result(
                 [Map.merge(meta("robots", "nofollow"), flags)],
                 %{},
                 budget()
               )
    end

    for name <- [" Robots ", " CRAWLER "] do
      assert {:ok, true, _budget} = Robots.nofollow_result([meta(name, "none")], %{}, budget())
    end

    assert {:ok, false, _budget} =
             Robots.nofollow_result([%{meta("robots", "nofollow") | name: "link"}], %{}, budget())

    assert {:ok, false, _budget} =
             Robots.nofollow_result([meta("googlebot", "nofollow")], %{}, budget())
  end

  test "owned temporary structures retire while caller-held bytes remain" do
    initial = budget()
    assert {:ok, initial} = Budget.charge(initial, 900)
    assert {:ok, initial} = Budget.reserve(initial, 700)
    opts = %{headers: [{"x-robots-tag", "index"}], user_agent: "Crawler/1"}
    assert {:ok, false, result} = Robots.nofollow_result([], opts, initial)
    assert result.retained == 900
    assert result.scratch == 700
    assert result.peak > result.retained + result.scratch
  end

  test "long user agents names and contents fail before owned buffers grow" do
    large = String.duplicate("x", 8192)

    cases = [
      {[], %{user_agent: large}},
      {[], %{headers: [{large, "index"}]}},
      {[], %{headers: [{"x-robots-tag", large}]}},
      {[meta(large, "index")], %{}},
      {[meta("robots", large)], %{}}
    ]

    for {tags, opts} <- cases do
      assert {:error, {:limit, :analysis_bytes}} =
               Robots.nofollow_result(tags, opts, budget(max_total_bytes: 4096))
    end
  end

  test "native XML meta lookups reject foreign and uppercase attributes" do
    for {name, content} <- [
          {"q:name", "content"},
          {"NAME", "content"},
          {"name", "q:content"},
          {"name", "CONTENT"}
        ] do
      source =
        ~s|<html xmlns="http://www.w3.org/1999/xhtml" xmlns:q="urn:foreign"><meta #{name}="robots" #{content}="nofollow"/></html>|

      assert {:ok, %{tags: tags}} = Crawler.XMLSpans.analyze(source)
      assert {:ok, false, result} = Robots.nofollow_result(tags, %{}, budget())
      assert result.scratch == 0
    end

    assert {:ok, %{tags: tags}} =
             Crawler.XMLSpans.analyze(~s|<html><meta name="robots" content="nofollow"/></html>|,
               content_type: "application/xhtml+xml"
             )

    assert {:ok, true, _budget} = Robots.nofollow_result(tags, %{}, budget())
    assert Robots.meta_nofollow?(~s|<META NAME="robots" CONTENT="nofollow">|, "crawler")
  end

  test "the root owns bypass and namespace decisions" do
    opts = %{respect_robots: false, robots_nofollow: false, headers: [{"x-robots-tag", "none"}]}
    assert {:ok, true, _budget} = Robots.nofollow_result([], opts, budget())
    assert {:ok, false, _budget} = Robots.nofollow_result([], %{robots_nofollow: true}, budget())
  end

  test "safe heterogeneous names and native nonbinary fallbacks remain supported" do
    for name <- ["X-Robots-Tag", :"X-Robots-Tag", ~c"X-Robots-Tag", ["X-", ~c"Robots", "-Tag"]] do
      assert {:ok, true, result} =
               Robots.nofollow_result([], %{headers: [{name, "none"}]}, budget())

      assert result.scratch == 0
    end

    assert {:ok, false, _budget} =
             Robots.nofollow_result([], %{headers: [{1, "none"}, {1.5, "none"}]}, budget())

    for ua <- [nil, 123, %URI{}] do
      assert {:ok, true, _budget} =
               Robots.nofollow_result([meta("crawler", "none")], %{user_agent: ua}, budget())
    end

    assert {:ok, false, _budget} =
             Robots.nofollow_result([], %{headers: [{"x-robots-tag", %URI{}}]}, budget())
  end

  defp meta(name, content) do
    %{
      name: "meta",
      closing?: false,
      in_template?: false,
      in_shadow_root?: false,
      attributes: [%{name: "name", decoded: name}, %{name: "content", decoded: content}]
    }
  end

  defp budget(opts \\ []) do
    limits = [
      max_total_bytes: 1_000_000,
      max_facts: 10000,
      max_regions: 1000,
      max_occurrences: 1000,
      max_edits: 1000
    ]

    Budget.new(Map.new(Keyword.merge(limits, opts)))
  end
end

defmodule Crawler.RobotsBudgetStopTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis.Budget
  alias Crawler.Robots
  alias Crawler.Robots.Directives

  test "fact exhaustion stops before normalizing a later directive" do
    traced({Directives, :directive_piece, 2}, fn call ->
      value = "index," <> String.duplicate("x,", 1024) <> "nofollow"

      assert {:error, {:limit, :lexical_facts}} =
               Robots.nofollow_result([], %{headers: [{"x-robots-tag", value}]}, budget(6))

      assert {:call_count, 1} = :erlang.trace_info(call, :call_count)
    end)
  end

  test "fact exhaustion never inserts the next product into the token set" do
    traced({MapSet, :put, 2}, fn call ->
      assert {:error, {:limit, :lexical_facts}} =
               Robots.nofollow_result([], %{user_agent: "a b c d"}, budget(7))

      assert {:call_count, 1} = :erlang.trace_info(call, :call_count)
    end)
  end

  test "unknown structs never invoke String.Chars protocols" do
    Code.ensure_loaded!(String.Chars.URI)

    traced({String.Chars.URI, :to_string, 1}, fn call ->
      assert {:error, :unsupported_robots_scalar} =
               Robots.nofollow_result(
                 [],
                 %{headers: [{%URI{path: "x-robots-tag"}, "none"}]},
                 budget(100)
               )

      assert {:call_count, 0} = :erlang.trace_info(call, :call_count)
    end)
  end

  defp budget(facts) do
    Budget.new(%{
      max_total_bytes: 1_000_000,
      max_facts: facts,
      max_regions: 1,
      max_occurrences: 1,
      max_edits: 1
    })
  end

  defp traced(call, fun) do
    :erlang.trace_pattern(call, true, [:local, :call_count])

    try do
      fun.(call)
    after
      :erlang.trace_pattern(call, false, [:local, :call_count])
    end
  end
end
