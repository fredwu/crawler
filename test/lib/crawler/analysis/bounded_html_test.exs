defmodule Crawler.Analysis.BoundedHTMLTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis.Budget
  alias Crawler.HTMLSpans
  alias Crawler.HTMLSpans.Markup

  test "tag and attribute quotas stop the canonical reader before later values" do
    source = "<div " <> Enum.map_join(1..128, " ", &"data-#{&1}='&amp;'") <> "></div>"
    {result, calls} = traced(fn -> HTMLSpans.tags_result(source, [], budget(2)) end)
    assert result == {:error, {:limit, :lexical_facts}}
    assert calls[{Markup, :read_attribute, 3}] == 1
    assert calls[{Floki, :parse_fragment, 1}] == 1

    {result, calls} = traced(fn -> HTMLSpans.tags_result(source, [], budget(1)) end)
    assert result == {:error, {:limit, :lexical_facts}}
    assert calls[{Markup, :read_attribute, 3}] == 0
    assert calls[{Floki, :parse_fragment, 1}] == 0
  end

  test "a byte limit rejects a large attribute before entity parser allocation" do
    source = "<img src='" <> String.duplicate("&amp;", 1024) <> "'>"
    {result, calls} = traced(fn -> HTMLSpans.tags_result(source, [], budget(100, 4096)) end)
    assert result == {:error, {:limit, :analysis_bytes}}
    assert calls[{Floki, :parse_fragment, 1}] == 0
    assert calls[{Markup, :read_attribute, 3}] == 1
  end

  test "tag quotas stop before reading another tag" do
    source = String.duplicate("<i>", 128)
    {result, calls} = traced(fn -> HTMLSpans.tags_result(source, [], budget(2)) end)
    assert result == {:error, {:limit, :lexical_facts}}
    assert calls[{Markup, :read_result, 4}] == 2
  end

  test "quotas are aggregate across calls and standalone attribute reads" do
    assert {:ok, [tag], remaining} = HTMLSpans.tags_result("<i a='x'>", [], budget(3))
    assert HTMLSpans.value(tag, "a") == "x"
    assert remaining.counts.facts == 2

    assert {:ok, [_attribute], remaining} =
             HTMLSpans.attributes_result("<i b='y'>", 0, [], remaining)

    assert remaining.counts.facts == 3
    assert {:error, {:limit, :lexical_facts}} = HTMLSpans.tags_result("<br>", [], remaining)
  end

  test "context and self closing decisions reuse the same attribute read" do
    source = "<math><annotation-xml encoding='TEXT&#47;HTML'><svg><font color=red/>"
    {result, calls} = traced(fn -> HTMLSpans.tags_result(source, [], budget(20)) end)
    assert {:ok, tags, remaining} = result
    assert Enum.map(tags, & &1.namespace) == [:math, :math, :svg, :html]
    assert remaining.counts.facts == 6
    assert remaining.scratch == 0
    assert calls[{Markup, :read_result, 4}] == 4
    assert calls[{Markup, :read_attribute, 3}] == 2
    assert calls[{HTMLSpans, :attributes, 3}] == 0
    assert HTMLSpans.tags(source) == tags

    assert {:ok, projected, _remaining} =
             HTMLSpans.tags_result(source, [attributes: false], budget(20))

    assert Enum.all?(projected, &(&1.attributes == []))
    assert Enum.map(projected, & &1.namespace) == Enum.map(tags, & &1.namespace)
  end

  test "span decoding stops before decoding the next entity and uses no whole match list" do
    {result, calls} =
      traced(fn ->
        HTMLSpans.decode_with_spans_result(String.duplicate("&amp;", 128), budget(2))
      end)

    assert result == {:error, {:limit, :lexical_facts}}
    assert calls[{Floki, :parse_fragment, 1}] == 1
    assert calls[{Regex, :scan, 3}] == 0
  end

  test "span decoding preserves ambiguous entities and byte mappings" do
    expected =
      {"a&b c&copy=tail",
       [
         {0, 1, 0, 1},
         {1, 1, 1, 5},
         {2, 1, 6, 1},
         {3, 1, 7, 6},
         {4, 1, 13, 1},
         {5, 5, 14, 5},
         {10, 5, 19, 5}
       ]}

    assert {:ok, ^expected, remaining} =
             HTMLSpans.decode_with_spans_result("a&amp;b&#x20;c&copy=tail", budget(20))

    assert remaining.counts.facts == 7
    assert remaining.scratch == 0
    assert remaining.peak > remaining.retained
    assert HTMLSpans.decode_with_spans("a&amp;b&#x20;c&copy=tail") == expected
  end

  test "decoder reserves overlapping parser work before parsing" do
    {result, calls} =
      traced(fn -> HTMLSpans.decode_result(String.duplicate("x", 64), budget(20, 4096)) end)

    assert result == {:error, {:limit, :analysis_bytes}}
    assert calls[{Floki, :parse_fragment, 1}] == 0
  end

  test "global first active base and foreign raw text facts retain source order" do
    source =
      "<a href='early'><template><base href='/ignored/'></template>" <>
        "<base href='/first/'><base href='/later/'><svg><script>literal</script></svg>"

    assert {:ok, tags, remaining} = HTMLSpans.tags_result(source, [], budget(100))
    assert tags == HTMLSpans.tags(source)
    assert [first, later] = HTMLSpans.base_tags(source)
    assert HTMLSpans.value(first, "href") == "/first/"
    assert HTMLSpans.value(later, "href") == "/later/"
    assert remaining.scratch == 0
  end

  test "incomplete tokens and declaration boundaries retain native behaviour" do
    for source <- [
          "<a",
          "<i a='unfinished",
          "<i a=unfinished",
          "<!-->",
          "<!--->",
          "<?" <> String.duplicate("x", 8192) <> ">"
        ] do
      assert {:ok, tags, remaining} = HTMLSpans.tags_result(source, [], budget(100))
      assert tags == HTMLSpans.tags(source)
      assert remaining.scratch == 0
    end
  end

  test "streamed tags release scanner records without refunding aggregate facts" do
    source = String.duplicate("<br>", 128)

    assert {:ok, 128, remaining} =
             HTMLSpans.reduce_tags_result(
               source,
               [attributes: false],
               budget(128, 4096),
               0,
               fn _tag, count, budget -> {:cont, count + 1, budget} end
             )

    assert remaining.retained == 0
    assert remaining.scratch == 0
    assert remaining.counts.facts == 128

    assert {:error, {:limit, :lexical_facts}} =
             HTMLSpans.reduce_tags_result(
               source,
               [attributes: false],
               budget(127, 4096),
               0,
               fn _tag, count, budget -> {:cont, count + 1, budget} end
             )
  end

  test "streaming retains context authority and releases it on close or halt" do
    source = "<div><template><meta charset='utf-8'></template></div>"

    assert {:ok, [true], remaining} =
             HTMLSpans.reduce_tags_result(
               source,
               [attributes: false],
               budget(20, 8192),
               [],
               fn tag, acc, budget ->
                 assert budget.retained > 0

                 case tag.name do
                   "meta" ->
                     with {:ok, budget} <- Budget.charge(budget, 16),
                          do: {:cont, [tag.in_template? | acc], budget}

                   _name ->
                     {:cont, acc, budget}
                 end
               end
             )

    assert remaining.retained == 16
    assert remaining.scratch == 0

    {result, calls} =
      traced(fn ->
        HTMLSpans.reduce_tags_result("<div><br><br>", [], budget(20), nil, fn _tag,
                                                                              _acc,
                                                                              budget ->
          {:halt, :done, budget}
        end)
      end)

    assert {:ok, :done, remaining} = result
    assert remaining.retained == 0
    assert remaining.counts.facts == 1
    assert calls[{Markup, :read_result, 4}] == 1
  end

  test "an unchanged large source requires no whole source or tag list reservation" do
    assert {:ok, :unchanged, remaining} =
             HTMLSpans.reduce_tags_result(
               String.duplicate("ordinary text ", 8192),
               [attributes: false],
               budget(1, 512),
               :unchanged,
               fn _tag, acc, budget -> {:cont, acc, budget} end
             )

    assert remaining.retained == 0
    assert remaining.peak == 0
  end

  defp budget(facts, bytes \\ 1_048_576) do
    Budget.new(%{
      max_total_bytes: bytes,
      max_facts: facts,
      max_regions: 100,
      max_occurrences: 100,
      max_edits: 100
    })
  end

  defp traced(fun) do
    mfas = [
      {Markup, :read_attribute, 3},
      {Markup, :read_result, 4},
      {Floki, :parse_fragment, 1},
      {HTMLSpans, :attributes, 3},
      {Regex, :scan, 3}
    ]

    for mfa <- mfas, do: :erlang.trace_pattern(mfa, true, [:local])
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          :go -> :ok
        end

        result = fun.()
        send(parent, {:result, self(), result})

        receive do
          :finish -> :ok
        end
      end)

    :erlang.trace(pid, true, [:call])
    send(pid, :go)

    try do
      {result, calls} = collect_trace(pid, nil, Map.new(mfas, &{&1, 0}), nil)
      send(pid, :finish)

      receive do
        {:DOWN, ^monitor, :process, ^pid, :normal} -> :ok
      after
        5000 -> flunk("trace child stalled")
      end

      {result, calls}
    after
      for mfa <- mfas, do: :erlang.trace_pattern(mfa, false, [:local])
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end
  end

  defp collect_trace(pid, result, calls, delivery) do
    receive do
      {:trace, ^pid, :call, {module, function, arguments}} ->
        mfa = {module, function, length(arguments)}
        collect_trace(pid, result, Map.update!(calls, mfa, &(&1 + 1)), delivery)

      {:result, ^pid, value} ->
        collect_trace(pid, value, calls, :erlang.trace_delivered(pid))

      {:trace_delivered, ^pid, ^delivery} ->
        {result, calls}

      {:DOWN, _monitor, :process, ^pid, reason} ->
        flunk("trace child failed: #{inspect(reason)}")
    after
      5000 -> flunk("trace timed out")
    end
  end
end
