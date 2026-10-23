defmodule Crawler.Parser.FacadeAnalysisTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.HTMLSpans
  alias Crawler.Parser
  alias Crawler.Parser.Callbacks
  alias Crawler.Parser.HtmlParser
  alias Crawler.Parser.LinkParser
  alias Crawler.Snapper.LinkReplacer

  @opts %{
    url: "https://example.test/dir/page",
    referrer_url: "https://example.test/dir/page",
    content_type: "text/html",
    html_tag: "a",
    assets: ["css", "js", "images"],
    depth: 3
  }

  test "XHTML facade policy ignores foreign attributes and keeps callback order" do
    source =
      ~s|<html xmlns="http://www.w3.org/1999/xhtml" xmlns:q="urn:foreign"><base q:href="https://wrong.test/"/><meta q:name="robots" content="nofollow"/><link q:rel="manifest" href="foreign"/><a q:href="inert"/><link rel="manifest" href="valid"/><a href="next"/></html>|

    opts = Map.put(@opts, :content_type, "application/xhtml+xml")
    assert {:ok, prepared} = Parser.prepare_for_parse(source, opts)

    assert Enum.map(prepared.occurrences, &{&1.value, &1.url}) == [
             {"valid", "https://example.test/dir/valid"},
             {"next", "https://example.test/dir/next"}
           ]

    handler = fn element, _opts -> element end
    public = Parser.emit(prepared, handler)

    assert List.flatten(public) == [
             nil,
             {"link", "valid", "href", "https://example.test/dir/valid"},
             {"link", "next", "href", "https://example.test/dir/next"}
           ]

    assert Parser.emit_bound(prepared, handler, fn ref, _raw ->
             assert ref.value in ["valid", "next"]
             :ok
           end) == public

    assert {:ok, output} = LinkReplacer.replace_prepared(prepared, &Analysis.online_fallback/1)
    assert output =~ ~s|q:href="https://wrong.test/"|
    assert output =~ ~s|q:rel="manifest" href="foreign"|
    assert output =~ ~s|q:href="inert"|
  end

  test "XHTML tags with no canonical child attributes emit no callbacks" do
    opts = Map.put(@opts, :content_type, "application/xhtml+xml")

    source =
      ~s|<html xmlns="http://www.w3.org/1999/xhtml" xmlns:q="urn:foreign"><a q:href="next"/><a HREF="next"/><iframe q:srcdoc="&lt;a href='child'&gt;"/></html>|

    assert {:ok, prepared} = Parser.prepare_for_parse(source, opts)
    assert prepared.occurrences == []
    assert prepared.groups == List.duplicate({:element, [], []}, 3)
    assert Enum.all?(HtmlParser.references(prepared.analysis, opts), &(&1.attributes == []))

    assert Parser.emit(prepared, fn _, _ -> flunk("inert XML emitted a callback") end) == [
             nil,
             nil,
             nil
           ]

    assert Parser.emit_bound(
             prepared,
             fn _, _ -> flunk("inert XML emitted a bound callback") end,
             fn _, _ -> flunk("inert XML emitted an observer") end
           ) == [nil, nil, nil]
  end

  test "bound emission preserves groups and observes every explicit HTML dedup member" do
    source =
      ~s|<img src="one.png" srcset="one.png 1x, one.png 2x">| <>
        ~s|<a href="javascript:void(0)">skip</a>| <>
        ~s|<script>import("./a.js");import("./a.js");</script>| <>
        ~s|<iframe srcdoc='<img src="one.png" srcset="one.png 1x, one.png 2x">'></iframe>|

    assert {:ok, prepared} = Parser.prepare_for_parse(source, @opts)

    handler = fn element, opts ->
      raw = {:ok, %{target_handle: {:job, element, opts.html_tag}}}
      send(self(), {:bridge_event, {:handler, element, raw}})
      raw
    end

    public = Parser.emit(prepared, handler)
    public_events = bridge_events()

    observer = fn occurrence, raw ->
      send(self(), {:bridge_event, {:observed, occurrence, raw}})
      :ok
    end

    :erlang.trace_pattern({Budget, :new, 1}, true, [:call_count])

    try do
      assert Parser.emit_bound(prepared, handler, observer) === public
      assert {:call_count, 0} = :erlang.trace_info({Budget, :new, 1}, :call_count)
    after
      :erlang.trace_pattern({Budget, :new, 1}, false, [:call_count])
    end

    events = bridge_events()
    assert Enum.filter(events, &match?({:handler, _, _}, &1)) == public_events
    observed = for {:observed, occurrence, _raw} <- events, do: occurrence.id
    assert MapSet.new(observed) == MapSet.new(prepared.occurrences, & &1.id)
    assert length(observed) == length(prepared.occurrences)
    assert length(public_events) == 4

    assert prepared.callback_members |> Map.values() |> Enum.map(&length/1) |> Enum.sort() == [
             3,
             3
           ]

    Enum.reduce(events, nil, fn
      {:handler, _element, raw}, _previous ->
        raw

      {:observed, _occurrence, raw}, previous ->
        assert raw === previous
        previous
    end)

    native_members = 8 * :erts_debug.flat_size(prepared.callback_members)

    assert prepared.collection.budget.retained >=
             prepared.analysis.budget.retained + native_members

    assert prepared.collection.budget.limit == prepared.analysis.budget.limit
    assert prepared.collection.budget.caps == prepared.analysis.budget.caps
  end

  test "CSS dedup observers keep contexts separate and scripts retain separate goals" do
    css = ~s|@import "same.css";a{background:url(same.css);mask:url(same.css)}|
    opts = Map.merge(@opts, %{content_type: "text/css", html_tag: "link"})
    assert {:ok, prepared} = Parser.prepare_for_parse(css, opts)

    handler = fn element, opts ->
      raw =
        {:ok,
         %{
           target_handle:
             {:job, opts.html_tag, opts[:javascript_goal], opts[:credentials], opts[:style_group]}
         }}

      send(self(), {:bridge_event, {:handler, element, raw}})
      raw
    end

    observer = fn occurrence, raw ->
      send(self(), {:bridge_event, {:observed, occurrence, raw}})
      :ok
    end

    expected = Parser.emit(prepared, handler)
    public_events = bridge_events()
    assert Parser.emit_bound(prepared, handler, observer) === expected
    events = bridge_events()
    assert Enum.filter(events, &match?({:handler, _, _}, &1)) == public_events
    observed = for {:observed, occurrence, raw} <- events, do: {occurrence, raw}
    assert length(observed) == length(prepared.occurrences)
    assert length(public_events) == 2
    assert prepared.callback_members |> Map.values() |> Enum.map(&length/1) == [2]
    assert MapSet.size(MapSet.new(observed, fn {_occurrence, raw} -> raw end)) == 2

    scripts =
      ~s|<script src="same.js"></script><script type="module" src="same.js"></script><script type="module" crossorigin="use-credentials" src="same.js"></script>|

    assert {:ok, prepared} = Parser.prepare_for_parse(scripts, @opts)
    assert prepared.callback_members == %{}

    assert Parser.emit_bound(prepared, handler, observer) ===
             Parser.emit(prepared, fn _element, opts ->
               {:ok,
                %{
                  target_handle:
                    {:job, opts.html_tag, opts[:javascript_goal], opts[:credentials],
                     opts[:style_group]}
                }}
             end)

    events = bridge_events()
    observed = for {:observed, occurrence, raw} <- events, do: {occurrence, raw}
    assert length(observed) == 3
    assert MapSet.size(MapSet.new(observed, fn {_occurrence, raw} -> raw end)) == 3
  end

  test "raw terminal, rejection, nil and list handler results keep public normalization" do
    assert {:ok, prepared} =
             Parser.prepare_for_parse(
               ~s|<a href="one">1</a><iframe srcdoc='<a href="two">2</a>'></iframe>|,
               @opts
             )

    for raw <- [
          {:ok, %{target_handle: :accepted}},
          {:terminal, :cached, %{target_handle: :replayed}},
          {:error, :filtered},
          nil,
          false,
          [{:ok, :nested}, nil]
        ] do
      handler = fn _element, _opts -> raw end
      expected = Parser.emit(prepared, handler)

      assert Parser.emit_bound(prepared, handler, fn occurrence, actual ->
               send(self(), {:bridge_event, {:observed, occurrence, actual}})
               :ok
             end) === expected

      events = bridge_events()
      assert length(events) == 2
      assert Enum.all?(events, fn {:observed, _occurrence, actual} -> actual === raw end)
    end
  end

  test "observer failures stop remaining members and later handlers explicitly" do
    source = ~s|<img src="one.png" srcset="one.png 1x, one.png 2x"><a href="later">L</a>|
    assert {:ok, prepared} = Parser.prepare_for_parse(source, @opts)
    [[first, failed, _last]] = Map.values(prepared.callback_members)

    handler = fn element, _opts ->
      send(self(), {:bridge_event, {:handler, element, :raw}})
      :raw
    end

    observer = fn occurrence, raw ->
      send(self(), {:bridge_event, {:observed, occurrence, raw}})
      if occurrence.id == failed, do: {:error, :record_failed}, else: :ok
    end

    assert Parser.emit_bound(prepared, handler, observer) == {:error, :record_failed}
    events = bridge_events()
    assert Enum.count(events, &match?({:handler, _, _}, &1)) == 1
    assert for({:observed, occurrence, :raw} <- events, do: occurrence.id) == [first, failed]

    assert Parser.emit_bound(prepared, handler, fn _, _ -> :invalid end) ==
             {:error, :invalid_observer_result}

    assert Enum.count(bridge_events(), &match?({:handler, _, _}, &1)) == 1
    missing = %{prepared | callback_members: nil}

    assert Parser.emit_bound(
             missing,
             fn _, _ -> flunk("missing membership must not dispatch") end,
             fn _, _ -> flunk("missing membership must not observe") end
           ) ==
             {:error, :missing_callback_members}
  end

  test "observed dedup members bind the same funded collection for rendering" do
    source = ~s|<img src="one.png" srcset="one.png 1x, one.png 2x">|

    assert {:ok, prepared} =
             Parser.prepare_for_parse(source, Map.put(@opts, :max_total_bytes, 20_000_000))

    raw = {:ok, %{target_handle: {:canonical_job, 17}}}

    assert Parser.emit_bound(prepared, fn _, _ -> raw end, fn occurrence, actual ->
             send(self(), {:bridge_event, {:observed, occurrence, actual}})
             :ok
           end) === Parser.emit(prepared, fn _, _ -> raw end)

    admitted =
      Map.new(bridge_events(), fn {:observed, occurrence, {:ok, opts}} ->
        {occurrence.id, opts.target_handle}
      end)

    assert map_size(admitted) == 3
    assert {:ok, bound} = LinkReplacer.bind_prepared(prepared, &Map.fetch!(admitted, &1.id))
    assert bound.callback_members === prepared.callback_members
    assert bound.collection.budget.limit == prepared.collection.budget.limit

    assert {:ok, body} =
             LinkReplacer.replace_prepared(bound, fn occurrence ->
               assert occurrence.target == {:canonical_job, 17}
               {:local, "saved.png"}
             end)

    assert body == ~s|<img src="saved.png" srcset="saved.png 1x, saved.png 2x">|

    assert {:ok, opaque} =
             Parser.prepare_for_parse(<<255>>, %{content_type: "image/png", html_tag: "img"})

    assert Parser.emit_bound(opaque, fn _, _ -> flunk("opaque dispatch") end, fn _, _ ->
             flunk("opaque observation")
           end) == []
  end

  defp bridge_events(events \\ []) do
    receive do
      {:bridge_event, event} -> bridge_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  test "public callbacks retain element grouping, plain deduplication, and repeated script references" do
    source =
      ~s|<img src="one.png" srcset="one.png 1x, one.png 2x">| <>
        ~s|<a href="javascript:void(0)">skip</a>| <>
        ~s|<script>import("./a.js");import("./a.js");</script>|

    image = {"link", "one.png", "src", "https://example.test/dir/one.png"}
    script = {"link", "./a.js", "href", "https://example.test/dir/a.js"}

    assert Parser.parse_links(source, @opts, fn element, _opts -> element end) ==
             [image, nil, [script, script]]

    assert {:ok, prepared} = Parser.prepare_for_parse(source, @opts)
    assert length(prepared.occurrences) == 5
  end

  @tag :render
  test "one cached analysis feeds callback emission and a bound-target render batch" do
    Code.ensure_loaded!(HTMLSpans)

    for count <- [1, 100, 1_000] do
      source = Enum.map_join(1..count, &~s|<a href="page#{&1}">#{&1}</a>|)
      :erlang.trace_pattern({HTMLSpans, :tags_result, 3}, true, [:call_count])
      :erlang.trace_pattern({HTMLSpans, :reduce_tags_result, 5}, true, [:call_count])
      :erlang.trace_pattern({HTMLSpans, :tags, 2}, true, [:call_count])

      try do
        assert {:ok, analysis} = Analysis.analyze(source, @opts)
        assert {:ok, prepared} = Parser.prepare(analysis, @opts, %{})
        :erlang.trace_pattern({Analysis, :occurrences_result, 2}, true, [:call_count])
        :erlang.trace_pattern({Analysis, :occurrences_result, 3}, true, [:call_count])
        :erlang.trace_pattern({Crawler.Analysis.Render, :run, 4}, true, [:call_count])
        assert length(Parser.emit(prepared, fn element, _opts -> element end)) == count
        assert length(Parser.emit(prepared, fn element, _opts -> element end)) == count
        assert prepared.occurrences === prepared.collection.occurrences
        assert {:ok, bound} = LinkReplacer.bind_prepared(prepared, &{:job, &1.id})
        assert bound.collection.source_revision == analysis.revision
        assert bound.collection.budget.limit == prepared.collection.budget.limit
        assert bound.collection.budget.retained > prepared.collection.budget.retained
        prepared = bound

        assert {:ok, output} =
                 LinkReplacer.replace_prepared(prepared, fn occurrence ->
                   assert occurrence.target == {:job, occurrence.id}
                   {:local, "saved/" <> occurrence.value}
                 end)

        assert output =~ ~s|href="saved/page1"|

        assert {:call_count, 0} =
                 :erlang.trace_info({Analysis, :occurrences_result, 2}, :call_count)

        assert {:call_count, 0} =
                 :erlang.trace_info({Analysis, :occurrences_result, 3}, :call_count)

        assert {:call_count, 1} =
                 :erlang.trace_info({Crawler.Analysis.Render, :run, 4}, :call_count)

        assert {:call_count, retained_scans} =
                 :erlang.trace_info({HTMLSpans, :tags_result, 3}, :call_count)

        assert {:call_count, reduced_scans} =
                 :erlang.trace_info({HTMLSpans, :reduce_tags_result, 5}, :call_count)

        assert retained_scans <= 1
        assert reduced_scans <= 1
        assert max(retained_scans, reduced_scans) == 1
        assert {:call_count, 0} = :erlang.trace_info({HTMLSpans, :tags, 2}, :call_count)
      after
        :erlang.trace_pattern({Analysis, :occurrences_result, 2}, false, [:call_count])
        :erlang.trace_pattern({Analysis, :occurrences_result, 3}, false, [:call_count])
        :erlang.trace_pattern({Crawler.Analysis.Render, :run, 4}, false, [:call_count])
        :erlang.trace_pattern({HTMLSpans, :tags_result, 3}, false, [:call_count])
        :erlang.trace_pattern({HTMLSpans, :reduce_tags_result, 5}, false, [:call_count])
        :erlang.trace_pattern({HTMLSpans, :tags, 2}, false, [:call_count])
      end
    end
  end

  test "a first relative HTML base applies before its source position exactly once" do
    source = ~s|<a href="before">B</a><base href="assets/"><a href="after">A</a>|

    assert Parser.parse_links(source, @opts, fn element, opts -> {element, opts.referrer_url} end) ==
             [
               {{"link", "before", "href", "https://example.test/dir/assets/before"},
                "https://example.test/dir/assets/"},
               {{"link", "after", "href", "https://example.test/dir/assets/after"},
                "https://example.test/dir/assets/"}
             ]
  end

  test "inline CSS callback source tags survive cached interpretation" do
    source =
      ~s|<style>.x{background:url(a.png)}</style><div style="background:url(b.png)"></div>| <>
        ~s|<svg><rect fill="url(c.png)"/></svg>|

    assert Parser.parse_links(source, @opts, fn _element, opts -> opts.reference_tag end) ==
             ["style", "div", "rect"]
  end

  test "srcdoc callback groups isolate response headers and robots policy" do
    source =
      ~s|<meta name="robots" content="nofollow"><a href="outer">X</a>| <>
        ~s|<iframe srcdoc='<a href="inner">I</a><img src="image.png">'></iframe>|

    opts = Map.put(@opts, :headers, [{"X-Robots-Tag", "nofollow"}])

    found =
      Parser.parse_links(source, opts, fn element, opts ->
        refute Map.has_key?(opts, :headers)
        refute Map.has_key?(opts, :robots_nofollow)
        {element, opts.depth}
      end)

    assert found == [
             [
               {{"link", "inner", "href", "https://example.test/dir/inner"}, 3},
               {{"link", "image.png", "src", "https://example.test/dir/image.png"}, 3}
             ]
           ]
  end

  test "nested srcdoc callback indexes contain only the nested document occurrences" do
    source =
      ~s|<a href="root">R</a>| <>
        ~s|<iframe srcdoc='<a href="middle">M</a><iframe srcdoc="&lt;a href=deep&gt;D&lt;/a&gt;"></iframe>'></iframe>|

    assert Parser.parse_links(source, @opts, fn element, _opts -> element end) ==
             [
               {"link", "root", "href", "https://example.test/dir/root"},
               [
                 {"link", "middle", "href", "https://example.test/dir/middle"},
                 {"link", "deep", "href", "https://example.test/dir/deep"}
               ]
             ]
  end

  test "control-file callbacks retain public JSON spans and referring page depths" do
    source = ~s|{"start_url":"home","icons":[{"src":"icon.png"}]}|
    opts = Map.put(@opts, :fetch_kind, :manifest)

    assert [{page, 2, page_span}, {image, 3, image_span}] =
             Parser.parse_links(source, opts, fn element, opts ->
               {element, opts.depth, opts.json_span}
             end)

    assert page == {"link", "home", "href", "https://example.test/dir/home"}
    assert image == {"link", "icon.png", "href", "https://example.test/dir/icon.png"}
    assert HTMLSpans.slice(source, page_span) == ~s|"home"|
    assert HTMLSpans.slice(source, image_span) == ~s|"icon.png"|
  end

  test "tagged analysis failures are not converted to empty successful discovery" do
    assert Parser.parse_links(
             ~S|{"start_url":"bad\q"}|,
             Map.put(@opts, :fetch_kind, :manifest),
             fn _element, _opts -> flunk("invalid JSON must not emit") end
           ) == {:error, :invalid_json}

    assert Parser.parse_links(
             "<svg><g/></svg>",
             Map.merge(@opts, %{content_type: "image/svg+xml", max_facts: 1}),
             fn _element, _opts -> flunk("limited XML must not emit") end
           ) == {:error, {:limit, :lexical_facts}}

    assert Parser.parse_links(
             "<svg><g/></svg>",
             Map.merge(@opts, %{content_type: "image/svg+xml", max_xml_tokens: 1}),
             fn _element, _opts -> flunk("XML token exhaustion must not emit") end
           ) == {:error, {:limit, :xml_tokens}}
  end

  test "guarded opaque image bytes remain untouched without UTF-8 or XML analysis" do
    body = <<0xFF, 0, 1>>
    opts = Map.merge(@opts, %{html_tag: "img", content_type: "image/svg+xml"})

    assert Parser.parse_links(body, opts, fn _element, _opts ->
             flunk("opaque bytes must not emit")
           end) == []

    assert LinkReplacer.replace_links(body, opts) == {:ok, body}
  end

  @tag :render
  test "standalone rewrite uses safe online targets and cannot invent local handles" do
    source = ~s|<a href="https://user:password@example.test/next#part">N</a>|

    assert LinkReplacer.replace_links(source, @opts) ==
             {:ok, ~s|<a href="https://example.test/next#part">N</a>|}

    assert {:ok, prepared} = Parser.prepare_for_parse(source, @opts)

    assert LinkReplacer.replace_prepared(prepared, fn _ -> {:local, "invented.html"} end) ==
             {:error, :unbound_local_target}
  end

  test "an incompatible cached JavaScript goal selects a separate lexical analysis" do
    source =
      ~S|const n=await /g;var await=4;import(".\/hidden.js");const m=g/g;import("./real.js");|

    opts =
      Map.merge(@opts, %{
        content_type: "application/javascript",
        html_tag: "script",
        javascript_goal: :module
      })

    assert {:ok, module} = Parser.prepare_for_parse(source, opts)
    assert length(module.occurrences) == 1

    assert {:ok, classic} =
             Parser.prepare_for_parse(module.analysis, Map.put(opts, :javascript_goal, :script))

    assert length(classic.occurrences) == 2
    assert classic.analysis_revision != module.analysis_revision
    assert classic.source == module.source
  end

  test "managed pure prepare consumes an explicit snapshot without state-owner calls" do
    source = "<style>body{background:var(--missing,url(fallback.png))}</style>"
    assert {:ok, analysis} = Analysis.analyze(source, @opts)
    opts = Map.put(@opts, :generation, make_ref())

    assert Parser.prepare(analysis, opts, %{}) == {:error, :missing_managed_css_snapshot}

    assert Parser.prepare(analysis, opts, %{css_tokens: %{}}) == {:error, :missing_css_revision}

    assert {:ok, prepared} =
             Parser.prepare(analysis, opts, %{
               css_tokens: %{},
               css_references: %{},
               css_revision: :pending
             })

    assert prepared.occurrences == []
    assert prepared.css_collection.groups != []
    assert prepared.css_collection.source_revision == analysis.revision
    assert prepared.collection.source_revision == analysis.revision
    assert prepared.collection.budget.limit == prepared.css_collection.budget.limit
    assert prepared.collection.budget.retained > prepared.css_collection.budget.retained
  end

  test "public collection preparation preserves charged continuation without rebuilding groups" do
    source = ~s|<style>body{background:url(asset.png)}</style><a href="next">N</a>|
    opts = Map.merge(@opts, %{max_total_bytes: 1_234_567, max_facts: 4_321, max_occurrences: 321})
    context = Map.put(opts, :style_group, opts.url)
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, groups} = Analysis.css_groups_result(analysis, context)
    assert groups.groups != []
    assert {:ok, css_context} = Crawler.Parser.CssSheets.resolve_groups(opts, groups.groups)
    assert {:ok, charged} = Budget.charge(groups.budget, 4_096)
    groups = %{groups | budget: charged}
    managed = Map.put(opts, :generation, make_ref())

    traced = [
      {Analysis, :analyze, 2},
      {Analysis, :analyze, 3},
      {Analysis, :css_groups_result, 2},
      {Analysis, :occurrences_result, 2},
      {Crawler.Parser.CssSheets, :resolve_groups, 2}
    ]

    for mfa <- traced do
      :erlang.trace_pattern(mfa, true, [:call_count])
    end

    try do
      assert {:ok, prepared} = Parser.prepare_collection(analysis, managed, css_context, groups)
      assert prepared.css_collection === groups
      assert prepared.css_revision === css_context.css_revision
      assert prepared.opts.style_group == opts.url
      assert prepared.collection.source_revision == analysis.revision
      assert prepared.collection.budget.limit == charged.limit
      assert prepared.collection.budget.caps == charged.caps
      assert prepared.collection.budget.retained > charged.retained

      assert Enum.all?(charged.counts, fn {key, count} ->
               prepared.collection.budget.counts[key] >= count
             end)

      assert length(prepared.occurrences) == 2

      for mfa <- traced do
        assert {:call_count, 0} = :erlang.trace_info(mfa, :call_count)
      end
    after
      for mfa <- traced do
        :erlang.trace_pattern(mfa, false, [:call_count])
      end
    end

    assert Parser.prepare_collection(analysis, managed, css_context, nil) ==
             {:error, :invalid_budget_continuation}

    assert Parser.prepare_collection(analysis, managed, css_context, %{}) ==
             {:error, :invalid_budget_continuation}

    assert {:ok, other} = Analysis.analyze(source <> " ", opts)

    assert Parser.prepare_collection(other, managed, css_context, groups) ==
             {:error, :invalid_budget_continuation}
  end

  test "public managed binary convenience normalizes numeric limits without acquiring authority" do
    opts = Map.merge(@opts, %{generation: make_ref(), max_body: 0})

    assert Parser.parse_links("<a href='x'>X</a>", opts, fn _, _ -> flunk("over byte limit") end) ==
             {:error, {:limit, :source_bytes}}

    assert_raise ArgumentError, fn ->
      Parser.parse_links("", Map.put(opts, :max_body, -1), fn _, _ -> :unused end)
    end
  end

  test "source identity stays separate from the goal-specific analysis revision" do
    source = ~s|import("./real.js");|

    opts =
      Map.merge(@opts, %{
        content_type: "application/javascript",
        html_tag: "script",
        source_revision: :decoded_bytes
      })

    assert {:ok, module} =
             Parser.prepare_for_parse(source, Map.put(opts, :javascript_goal, :module))

    assert {:ok, classic} =
             Parser.prepare_for_parse(source, Map.put(opts, :javascript_goal, :script))

    assert module.source_revision == classic.source_revision
    assert module.source_revision == :decoded_bytes
    assert module.analysis_revision != classic.analysis_revision
  end

  test "callback preparation rejects projection growth within the original allowance" do
    source = Enum.map_join(1..100, &~s|<a href="next#{&1}">N</a>|)
    opts = Map.put(@opts, :max_total_bytes, 20_000_000)
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)
    cap = collection.budget.peak + 1
    opts = Map.put(@opts, :max_total_bytes, cap)

    assert {:ok, limited} = Analysis.analyze(source, opts)
    assert {:ok, original} = Analysis.occurrences_result(limited, opts)
    assert Callbacks.prepare(limited, opts, original) == {:error, {:limit, :analysis_bytes}}
    assert Parser.prepare(limited, opts, %{}) == {:error, {:limit, :analysis_bytes}}
    assert original.budget.limit == cap
  end

  @tag :render
  test "binding and rendering cannot renew an exhausted facade allowance" do
    source = Enum.map_join(1..100, &~s|<a href="next#{&1}">N</a>|)
    opts = Map.put(@opts, :max_total_bytes, 20_000_000)
    assert {:ok, prepared} = Parser.prepare_for_parse(source, opts)
    cap = prepared.collection.budget.peak + 1
    opts = Map.put(@opts, :max_total_bytes, cap)
    assert {:ok, limited} = Parser.prepare_for_parse(source, opts)

    assert LinkReplacer.bind_prepared(limited, &{:job, &1.id}) ==
             {:error, {:limit, :analysis_bytes}}

    assert LinkReplacer.replace_prepared(limited, &Analysis.online_fallback/1) ==
             {:error, {:limit, :analysis_bytes}}

    assert limited.collection.budget.limit == cap

    assert Budget.available(limited.collection.budget) ==
             cap - prepared.collection.budget.retained
  end

  @tag :render
  test "render consumes the bound collection even if a caller changes the list view" do
    assert {:ok, prepared} = Parser.prepare_for_parse(~s|<a href="next">N</a>|, @opts)
    assert {:ok, bound} = LinkReplacer.bind_prepared(prepared, &{:job, &1.id})
    bound = %{bound | occurrences: []}

    assert Parser.emit(bound, fn element, _opts -> element end) ==
             [{"link", "next", "href", "https://example.test/dir/next"}]

    assert LinkReplacer.replace_prepared(bound, fn occurrence ->
             assert occurrence.target == {:job, occurrence.id}
             {:local, "saved.html"}
           end) == {:ok, ~s|<a href="saved.html">N</a>|}
  end

  test "cached source headers remain part of the analysis compatibility boundary" do
    source = ~s|<a href="next">N</a>|
    opts = Map.put(@opts, :headers, [{"Link", "<map.json>; rel=modulepreload"}])
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, _prepared} = Parser.prepare(analysis, opts, %{})

    assert Parser.prepare(analysis, Map.put(opts, :headers, []), %{}) ==
             {:error, :incompatible_source_options}
  end

  test "the tuple and DOM-child public APIs remain available" do
    assert LinkParser.parse({"a", [{"href", "next"}], []}, @opts, fn element, _opts -> element end) ==
             {"link", "next", "href", "https://example.test/dir/next"}

    assert HtmlParser.parse(~s|<a href="next">Out<b>Live</b></a>|, %{}) ==
             [{"a", [{"href", "next"}], ["Out", {"b", [], ["Live"]}]}]
  end
end
