defmodule Crawler.HTTP.DocumentHeadersBudgetTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis.Budget
  alias Crawler.HTTP.DocumentHeaders

  test "retains refresh-first order and every native link attribute" do
    headers = [
      {"link", ~S|<a>;rel=preload;as=image;imagesrcset="a 1x,b 2x";type="image/png";crossorigin|},
      {:Refresh, "0;url=next"},
      {~c"LINK", ~S|<b>;rel=stylesheet|}
    ]

    expected = [
      {"meta", [{"http-equiv", "refresh"}, {"content", "0;url=next"}], []},
      {"link",
       [
         {"rel", "preload"},
         {"href", "a"},
         {"as", "image"},
         {"imagesrcset", "a 1x,b 2x"},
         {"type", "image/png"},
         {"crossorigin", ""}
       ], []},
      {"link", [{"rel", "stylesheet"}, {"href", "b"}], []}
    ]

    assert {:ok, ^expected, result} = DocumentHeaders.elements_result(headers, budget())
    assert result.scratch == 0
    assert DocumentHeaders.elements(headers) == expected
  end

  test "keeps the canonical quote angle escape and duplicate-parameter precedence" do
    fixtures = [
      {~S|<a,b>; rel="preload"; imagesrcset="a 1x,b 2x"|,
       [{"link", [{"rel", "preload"}, {"href", "a,b"}, {"imagesrcset", "a 1x,b 2x"}], []}]},
      {~S|<a>; rel=first; rel=second; crossorigin; crossorigin=use-credentials|,
       [{"link", [{"rel", "first"}, {"href", "a"}, {"crossorigin", ""}], []}]},
      {~S|<a>; rel="pre\"load"; as=style, <b>; rel=next|,
       [
         {"link", [{"rel", "pre\"load\"; as=style"}, {"href", "a"}], []},
         {"link", [{"rel", "next"}, {"href", "b"}], []}
       ]},
      {~S|<a>; rel="pre\\load"; as=style, <b>; rel=next|,
       [
         {"link", [{"rel", "preload"}, {"href", "a"}, {"as", "style"}], []},
         {"link", [{"rel", "next"}, {"href", "b"}], []}
       ]},
      {~S|<a<b,c>>; rel=preload, <d>;rel=next|,
       [
         {"link", [{"rel", "preload"}, {"href", "a<b,c"}], []},
         {"link", [{"rel", "next"}, {"href", "d"}], []}
       ]},
      {~S|<a>; rel="unfinished, <b>;rel=next|,
       [{"link", [{"rel", "unfinished, <b>;rel=next"}, {"href", "a"}], []}]},
      {~S|, <a>; rel=preload,,|, [{"link", [{"rel", "preload"}, {"href", "a"}], []}]}
    ]

    for {value, expected} <- fixtures do
      assert {:ok, ^expected, _budget} =
               DocumentHeaders.elements_result([{"link", value}], budget())

      assert DocumentHeaders.elements([{"link", value}]) == expected
    end
  end

  test "tokens parameters and output fields share an aggregate fact quota" do
    source = Enum.map_join(1..128, ",", fn i -> "<#{i}>;rel=preload" end)

    assert {:error, {:limit, :lexical_facts}} =
             DocumentHeaders.elements_result([{"link", source}], budget(max_facts: 8))

    assert {:ok, [_element], residual} =
             DocumentHeaders.elements_result([{"link", "<a>;rel=preload"}], budget(max_facts: 8))

    assert residual.counts.facts == 8

    assert {:error, {:limit, :lexical_facts}} =
             DocumentHeaders.elements_result([{"refresh", "0;url=next"}], residual)
  end

  test "ignored and duplicate parameters also consume the shared quota" do
    for param <- ["title=ignored", "rel=preload"] do
      source = "<a>;rel=preload;" <> Enum.map_join(1..128, ";", fn _ -> param end)

      assert {:error, {:limit, :lexical_facts}} =
               DocumentHeaders.elements_result([{"link", source}], budget(max_facts: 6))
    end
  end

  test "scratch stays within the caller allowance even without an emitted element" do
    for source <- [String.duplicate("x", 8192), "<a>;title=" <> String.duplicate("x", 8192)] do
      assert {:error, {:limit, :analysis_bytes}} =
               DocumentHeaders.elements_result([{"link", source}], budget(max_total_bytes: 1024))
    end
  end

  test "success preserves caller scratch and charges output copies and reversal overlap" do
    assert {:ok, initial} = Budget.reserve(budget(), 700)
    headers = [{"link", "<a>;rel=preload;crossorigin"}, {"refresh", "0;url=next"}]
    assert {:ok, [_, _], result} = DocumentHeaders.elements_result(headers, initial)
    assert result.scratch == 700
    assert result.retained > initial.retained
    assert result.peak > result.retained + result.scratch
    assert initial.retained == 0
  end

  test "ordinary heterogeneous names are matched without a growing conversion buffer" do
    for key <- ["LiNK", "linK", :LINK, ~c"LiNK", [?L, ["i"], ?n, ?K]] do
      assert {:ok, [{"link", [{"rel", "next"}, {"href", "a"}], []}], _budget} =
               DocumentHeaders.elements_result([{key, "<a>;rel=next"}], budget())
    end

    assert {:ok, [], _budget} =
             DocumentHeaders.elements_result([{123, "value"}, {1.25, "value"}], budget())
  end

  test "invalid and inert inputs retain the empty-list result" do
    for headers <- [
          nil,
          %{},
          [],
          [nil, {"link", nil}],
          [{"refresh", " \t"}],
          [{"link", "invalid, <a>;as=image"}]
        ] do
      assert {:ok, [], _budget} = DocumentHeaders.elements_result(headers, budget())
      assert DocumentHeaders.elements(headers) == []
    end
  end

  test "all header readers use bounded names and fund matching value copies" do
    alias Crawler.Parser.SourceMap
    alias Crawler.Parser.SpeculationRules
    tiny = budget(max_total_bytes: 1)
    headers = [{String.duplicate("X", 65_536), ""}, {123, ""}]
    assert {:ok, [], ^tiny} = SpeculationRules.header_urls_result(headers, tiny)

    opts = %{
      content_type: "text/javascript",
      url: "https://example.test/app.js",
      headers: headers
    }

    assert {:ok, nil, ^tiny} = SourceMap.header_reference_result(opts, tiny)

    assert {:error, {:limit, :analysis_bytes}} =
             SourceMap.header_reference_result(
               %{opts | headers: [{"SOURCEMAP", String.duplicate(" ", 65_536)}]},
               budget(max_total_bytes: 1000)
             )

    assert {:ok, nil, ^tiny} =
             SourceMap.javascript_result(
               "",
               Map.put(opts, :source_map_notes, []),
               {"", [], []},
               tiny
             )

    assert {:error, {:limit, :analysis_bytes}} =
             SourceMap.javascript_result(
               "",
               Map.merge(opts, %{source_map_notes: [], headers: [{"SOURCEMAP", "map.json"}]}),
               {"", [], []},
               tiny
             )

    for key <- [
          "SPECULATION-RULES",
          :"Speculation-Rules",
          ~c"Speculation-Rules",
          [~c"SPECULATION", "-RULES"]
        ] do
      assert {:ok, ["rules.json"], result} =
               SpeculationRules.header_urls_result([{key, ~s|"rules.json"|}], budget())

      assert result.counts.facts == 1
      assert result.scratch == 0
      assert result.retained >= byte_size("rules.json")
    end

    for key <- ["SOURCEMAP", :SourceMap, ~c"SourceMap", [~c"SOURCE", "MAP"]] do
      current = %{opts | headers: [{key, "  map.json  "}]}
      assert {:ok, "map.json", result} = SourceMap.header_reference_result(current, budget())
      assert result.scratch == 0
      assert result.retained == byte_size("map.json") + Budget.cost(:binary)
      assert SourceMap.header_reference(current) == "map.json"
    end
  end

  test "ignored malformed header values preserve counts peak and parent scratch" do
    alias Crawler.Parser.SourceMap
    alias Crawler.Parser.SpeculationRules
    {:ok, seed} = Budget.charge(budget(max_facts: 2), 4096, facts: 1)
    {:ok, seed} = Budget.reserve(seed, 700)

    assert {:ok, [], latest} =
             SpeculationRules.header_urls_result([{"speculation-rules", ~s|"unfinished|}], seed)

    assert latest.counts.facts == 2
    assert latest.scratch == seed.scratch
    assert latest.retained == seed.retained
    assert latest.peak > seed.peak

    assert {:error, {:limit, :lexical_facts}} =
             SpeculationRules.header_urls_result([{"speculation-rules", ~s|"unfinished|}], latest)

    opts = %{
      content_type: "text/css",
      headers: [{"SourceMap", "  "}, {"X-SourceMap", " x.map "}, {"SourceMap", " primary.map "}]
    }

    assert {:ok, "primary.map", latest} = SourceMap.header_reference_result(opts, seed)
    assert latest.scratch == seed.scratch
    assert latest.retained > seed.retained
    assert SourceMap.header_reference(Map.put(opts, :inline_source, true)) == nil
    assert SourceMap.header_reference(%{opts | content_type: "text/html"}) == nil
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

defmodule Crawler.HTTP.DocumentHeadersBudgetStopTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis.Budget
  alias Crawler.HTTP.DocumentHeaders

  test "irrelevant speculation header names never call the normalizer" do
    Code.ensure_loaded!(String)
    call = {String, :downcase, 1}

    traced(call, fn ->
      headers = [{String.duplicate("X", 65_536), ""}]

      assert {:ok, [], _budget} =
               Crawler.Parser.SpeculationRules.header_urls_result(headers, budget(100))

      assert {:call_count, 0} = :erlang.trace_info(call, :call_count)
    end)
  end

  test "a fact-limited entry never invokes a later element reader" do
    call = {DocumentHeaders, :link_element, 3}

    traced(call, fn ->
      source = "<a>;rel=preload," <> Enum.map_join(1..128, ",", fn _ -> "<b>;rel=next" end)

      assert {:error, {:limit, :lexical_facts}} =
               DocumentHeaders.elements_result([{"link", source}], budget(8))

      assert {:call_count, 1} = :erlang.trace_info(call, :call_count)
    end)
  end

  test "a fact-limited parameter stops before the next parameter is scanned" do
    param_call = {DocumentHeaders, :param_pair, 1}
    token_call = {DocumentHeaders, :append_token, 11}

    traced(param_call, fn ->
      traced(token_call, fn ->
        prefix = "<a>;rel=preload;"
        source = prefix <> "title=" <> String.duplicate("x", 8192)

        assert {:error, {:limit, :lexical_facts}} =
                 DocumentHeaders.elements_result([{"link", source}], budget(6))

        assert {:call_count, 2} = :erlang.trace_info(param_call, :call_count)
        assert {:call_count, calls} = :erlang.trace_info(token_call, :call_count)
        assert calls < byte_size(source) + 20
      end)
    end)
  end

  test "a low byte quota stops the delimiter reader before its tail" do
    call = {DocumentHeaders, :append_token, 11}

    traced(call, fn ->
      limits = %{
        max_total_bytes: 1024,
        max_facts: 10000,
        max_regions: 1,
        max_occurrences: 1,
        max_edits: 1
      }

      assert {:error, {:limit, :analysis_bytes}} =
               DocumentHeaders.elements_result(
                 [{"link", String.duplicate("x", 8192)}],
                 Budget.new(limits)
               )

      assert {:call_count, calls} = :erlang.trace_info(call, :call_count)
      assert calls > 0
      assert calls < 100
    end)
  end

  test "an unsupported struct never invokes its String.Chars protocol" do
    Code.ensure_loaded!(String.Chars.URI)
    call = {String.Chars.URI, :to_string, 1}

    traced(call, fn ->
      headers = [{%URI{path: "link"}, "<a>;rel=next"}]

      assert {:error, :unsupported_header_name} =
               DocumentHeaders.elements_result(headers, budget(100))

      assert DocumentHeaders.elements(headers) == []
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
      fun.()
    after
      :erlang.trace_pattern(call, false, [:local, :call_count])
    end
  end
end
