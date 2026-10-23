defmodule Crawler.Export.AnalysisIntegrationTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis
  alias Crawler.Analysis.Occurrence
  alias Crawler.Export.Manifest
  alias Crawler.Job.Outcome

  @opts %{
    url: "https://user:password@example.test/page",
    referrer_url: "https://user:password@example.test/page",
    content_type: "text/html",
    assets: ["js", "css", "images"]
  }
  @limits %{
    max_targets: 20,
    max_representations: 20,
    max_artifacts: 20,
    max_edges: 100,
    max_manifest_bytes: 1_000_000,
    max_staged_bytes: 100_000,
    max_staged_metadata_bytes: 10_000,
    max_file_bytes: 20_000,
    max_files: 100
  }

  for order <- [[:include, :same_origin], [:same_origin, :include]] do
    test "actual Analysis occurrences render credential variants in #{inspect(order)} arrival order" do
      source =
        ~s|<p data-keep='&#38;'>keep</p><base href="/assets/"><script type="module" crossorigin="use-credentials" src="same" integrity="old"></script><script type="module" src="same" integrity="other"></script><a href="missing#anchor">online</a>|

      assert {:ok, analysis} = Analysis.analyze(source, @opts)
      assert {:ok, refs} = Analysis.occurrences(analysis, @opts)

      refs =
        Enum.map(refs, fn ref ->
          if ref.value == "same", do: Occurrence.bind(ref, ref.context.credentials), else: ref
        end)

      {:ok, state} = Manifest.new(String.duplicate("e", 24), :epoch, @limits)

      state =
        Enum.reduce(unquote(order), state, fn target, state ->
          id = if target == :include, do: "a", else: "b"
          resource(state, target, target, analysis.revision, id, "text/javascript", [])
        end)

      state = resource(state, :page, :page_rep, analysis.revision, "p", "text/html", refs)
      assert {:ok, snapshot, _} = Manifest.seal(state, :epoch, :seal)

      assert {:ok, output, stats} =
               Analysis.render_with_stats(analysis, refs, &Manifest.resolve(snapshot, :page, &1))

      assert stats.batches == 1
      assert output =~ ~s|src="./#{String.duplicate("a", 24)}.js"|
      assert output =~ ~s|src="./#{String.duplicate("b", 24)}.js"|
      assert output =~ ~s|href="https://example.test/assets/missing#anchor"|
      assert output =~ ~s|<p data-keep='&#38;'>keep</p>|
      refute output =~ "integrity="
      refute output =~ "<base href="
      refute output =~ "password"
      refute inspect(Manifest.public_manifest(snapshot)) =~ "password"
    end
  end

  test "actual XML bases and source-safe fragments survive absent-target fallback" do
    source =
      ~s|<svg xml:base="https://user:password@example.test/assets/"><image href="missing#&quot;anchor"/></svg>|

    opts = Map.put(@opts, :content_type, "image/svg+xml")
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, [ref]} = Analysis.occurrences(analysis, opts)
    {:ok, state} = Manifest.new(String.duplicate("e", 24), :epoch, @limits)
    state = resource(state, :page, :page_rep, analysis.revision, "p", "image/svg+xml", [ref])
    assert {:ok, snapshot, _} = Manifest.seal(state, :epoch, :seal)

    assert {:ok, output} =
             Analysis.render(analysis, [ref], &Manifest.resolve(snapshot, :page, &1))

    refute output =~ "xml:base"
    refute output =~ "password"
    assert output =~ "https://example.test/assets/missing#%22anchor"
    assert {:ok, _} = Crawler.XMLSpans.analyze(output)
  end

  test "one physical source supports distinct actual classic and module lexical revisions" do
    source = ~s|import("./child.js");|
    source_revision = :crypto.hash(:sha256, source)

    contexts =
      for goal <- [:script, :module], into: %{} do
        opts = Map.merge(@opts, %{content_type: "text/javascript", javascript_goal: goal})
        {:ok, analysis} = Analysis.analyze(source, opts)
        {:ok, refs} = Analysis.occurrences(analysis, opts)
        {goal, {analysis, refs}}
      end

    refute elem(contexts.script, 0).revision == elem(contexts.module, 0).revision
    {:ok, state} = Manifest.new(String.duplicate("e", 24), :epoch, @limits)
    {:ok, state} = Manifest.admit(state, :script, :shared, :script)
    {:ok, state} = Manifest.admit(state, :module, :shared, :module)
    {:ok, state} = Manifest.reserve(state, :source, :source, "shared.bin", byte_size(source))
    {:ok, state} = Manifest.written(state, :source)

    {:ok, state} =
      Manifest.put_response(state, :shared, %{
        source_handle: :one_disk_source,
        source_revision: source_revision,
        source_ticket: :source,
        content_type: "text/javascript",
        final_url: "https://example.test/code"
      })

    state =
      Enum.reduce(contexts, state, fn {goal, {analysis, refs}}, state ->
        {:ok, state} =
          Manifest.put_interpretation(state, goal, %{
            source_revision: source_revision,
            analysis_revision: analysis.revision,
            render_mode: :rewrite,
            analysis_handle: {:analysis, goal},
            occurrences_handle: {:refs, goal},
            public_id: String.duplicate(if(goal == :script, do: "s", else: "m"), 24)
          })

        {:ok, state} = Manifest.put_edges(state, goal, refs)
        {:ok, state} = Manifest.settle(state, goal, Outcome.new(:succeeded))
        state
      end)

    assert {:ok, snapshot, _} = Manifest.seal(state, :epoch, :seal)
    assert snapshot.artifacts.script.source_handle == snapshot.artifacts.module.source_handle

    for {goal, {analysis, refs}} <- contexts do
      assert {:ok, output} =
               Analysis.render(analysis, refs, &Manifest.resolve(snapshot, goal, &1))

      assert output == ~s|import("https://example.test/child.js");|
    end
  end

  defp resource(state, target, representation, revision, public_id, type, refs) do
    {:ok, state} = Manifest.admit(state, target, representation, target)
    ticket = {:source, target}

    {:ok, state} =
      Manifest.reserve(state, ticket, :source, "source-#{map_size(state.responses)}.bin", 1)

    {:ok, state} = Manifest.written(state, ticket)

    {:ok, state} =
      Manifest.put_response(state, representation, %{
        source_handle: {:disk, target},
        source_revision: revision,
        source_ticket: ticket,
        content_type: type,
        final_url: "https://user:password@example.test/extensionless"
      })

    {:ok, state} =
      Manifest.put_interpretation(state, target, %{
        source_revision: revision,
        analysis_revision: revision,
        render_mode: :rewrite,
        analysis_handle: {:analysis, target},
        occurrences_handle: {:occurrences, target},
        public_id: String.duplicate(public_id, 24)
      })

    {:ok, state} = Manifest.put_edges(state, target, refs)
    {:ok, state} = Manifest.settle(state, target, Outcome.new(:succeeded))
    state
  end
end
