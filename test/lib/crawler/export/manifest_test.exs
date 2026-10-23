defmodule Crawler.Export.ManifestTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis.Occurrence
  alias Crawler.Export.Manifest
  alias Crawler.Export.Paths
  alias Crawler.Job.Outcome

  @id String.duplicate("e", 24)
  @limits %{
    max_targets: 20,
    max_representations: 20,
    max_artifacts: 20,
    max_edges: 100,
    max_manifest_bytes: 200_000,
    max_staged_bytes: 20_000,
    max_staged_metadata_bytes: 2_000,
    max_file_bytes: 2_000,
    max_files: 100
  }

  test "all limits, epoch and public identity are explicit" do
    assert {:error, :invalid_limits} = Manifest.new(@id, :epoch, %{})
    assert {:error, :invalid_epoch} = Manifest.new(@id, nil, @limits)
    assert {:error, :invalid_public_id} = Manifest.new("user:password", :epoch, @limits)
    assert {:ok, _} = Manifest.new(@id, :epoch, @limits)
  end

  test "MIME extensions depend on the response and preserve module compatibility" do
    for {type, suffix} <- [
          {"text/css; charset=utf-8", ".css"},
          {"APPLICATION/JAVASCRIPT", ".js"},
          {"text/ecmascript", ".js"},
          {"application/xhtml+xml", ".xhtml"},
          {"image/svg+xml", ".svg"},
          {"application/manifest+json", ".webmanifest"},
          {nil, ".bin"},
          {"made-up", ".bin"},
          {"text/plain", ".txt"}
        ] do
      assert {:ok, path} = Paths.artifact(@id, type)
      assert Path.extname(path) == suffix
    end

    assert {:error, :invalid_public_id} = Paths.artifact("../secret", "text/css")
    assert {:error, :invalid_artifact_path} = Paths.relative("other/a.js", "resources/b.js")
  end

  for order <- [[:first, :second], [:second, :first]] do
    test "credential representations and interpretation variants preserve edges in #{inspect(order)} order" do
      order = unquote(order)
      state = new()

      state =
        Enum.reduce(order, state, fn target, state ->
          representation = if target == :first, do: :authenticated, else: :anonymous

          state
          |> admit(target, representation)
          |> response(representation, "application/javascript")
          |> interpretation(target, if(target == :first, do: "a", else: "b"))
          |> edges(target, [])
          |> settle(target)
        end)

      state =
        state
        |> admit(:classic, :authenticated)
        |> interpretation(:classic, "c")
        |> edges(:classic, [])
        |> settle(:classic)

      refs = [occurrence(:one, :first), occurrence(:two, :second), occurrence(:three, :classic)]

      state =
        state
        |> admit(:page, :page_rep)
        |> response(:page_rep)
        |> interpretation(:page, "p")
        |> edges(:page, refs)
        |> settle(:page)

      assert {:ok, snapshot, _} = Manifest.seal(state, :epoch, :seal)
      assert {:local, first} = Manifest.resolve(snapshot, :page, hd(refs))
      assert {:local, second} = Manifest.resolve(snapshot, :page, Enum.at(refs, 1))
      assert {:local, classic} = Manifest.resolve(snapshot, :page, Enum.at(refs, 2))
      assert Enum.uniq([first, second, classic]) == [first, second, classic]
      assert Enum.all?([first, second, classic], &String.ends_with?(&1, ".js"))
      assert map_size(snapshot.artifacts) == 4
      assert snapshot.artifacts.first.source_handle == snapshot.artifacts.classic.source_handle
    end
  end

  test "cycles resolve against assigned eligible paths without published targets" do
    state = new()

    refs = %{
      html: occurrence(:html_css, :css),
      css: occurrence(:css_js, :js),
      js: occurrence(:js_html, :html)
    }

    state =
      Enum.reduce(
        [{:html, "text/html", "h"}, {:css, "text/css", "c"}, {:js, "text/javascript", "j"}],
        state,
        fn {target, type, id}, state ->
          state
          |> admit(target, target)
          |> response(target, type)
          |> interpretation(target, id)
          |> edges(target, [refs[target]])
          |> settle(target)
        end
      )

    assert {:ok, snapshot, state} = Manifest.seal(state, :epoch, :seal)

    for source <- [:html, :css, :js],
        do: assert({:local, _} = Manifest.resolve(snapshot, source, refs[source]))

    assert state.rendered == %{}
  end

  for status <- [:failed, :rejected, :limited, :cancelled, :absent] do
    test "#{status} targets retain credential-free online destinations" do
      status = unquote(status)
      ref = occurrence(:edge, if(status == :absent, do: nil, else: :target))

      state =
        new()
        |> admit(:page, :page_rep)
        |> response(:page_rep)
        |> interpretation(:page, "p")
        |> edges(:page, [ref])
        |> settle(:page)

      state =
        if status == :absent,
          do: state,
          else: state |> admit(:target, :target_rep) |> settle(:target, status)

      assert {:ok, snapshot, _} = Manifest.seal(state, :epoch, :seal)

      assert {:online, "https://example.com/extensionless"} =
               Manifest.resolve(snapshot, :page, ref)

      assert ref.fragment == "anchor"
      assert length(Manifest.public_manifest(snapshot).resources) == 1
    end
  end

  test "public metadata is a whitelist and does not expose credentials or private handles" do
    state =
      new()
      |> admit(:page, :page_rep)
      |> response(:page_rep)
      |> interpretation(:page, "p")
      |> edges(:page, [occurrence(:edge, nil)])
      |> settle(:page)

    assert {:ok, snapshot, state} = Manifest.seal(state, :epoch, :seal)
    public = Manifest.public_manifest(snapshot)
    assert Map.keys(hd(public.resources)) |> Enum.sort() == [:content_type, :id, :path, :url]
    text = inspect(public)

    for private <- [
          "private-user",
          "private-password",
          "authorization",
          "source_handle",
          "analysis_handle",
          "occurrences_handle",
          "page_rep"
        ],
        do: refute(text =~ private)

    refute inspect(state) =~ "responses"
    refute inspect(snapshot) =~ "source_handle"
    assert hd(public.references).target == nil
  end

  test "success without a staged compatible interpretation cannot seal" do
    state = new() |> admit(:page, :rep) |> settle(:page)
    assert {:error, :unstaged_success} = Manifest.seal(state, :epoch, :seal)
    state = state |> response(:rep) |> interpretation(:page, "p")
    assert {:error, :unstaged_success} = Manifest.seal(state, :epoch, :seal)
    assert {:ok, _, _} = state |> edges(:page, []) |> Manifest.seal(:epoch, :seal)
  end

  test "pending source IO, outcomes and stale epochs block sealing" do
    state = admit(new(), :page, :rep)
    assert {:error, :pending_outcomes} = Manifest.seal(state, :epoch, :seal)
    assert {:ok, state} = Manifest.reserve(state, :ticket, :source, "one.bin", 1)
    assert {:error, :pending_writes} = Manifest.seal(state, :epoch, :seal)
    assert {:error, :stale_epoch} = Manifest.seal(state, :old_epoch, :seal)
  end

  test "sealing closes admission, source mutation and a second seal" do
    state = complete()
    assert {:ok, _, state} = Manifest.seal(state, :epoch, :seal)

    assert {:error, :closed_export} =
             Manifest.admit(state, :late, :late_rep, :late_interpretation)

    assert {:error, :closed_export} = Manifest.put_response(state, :rep, %{})
    assert {:error, :closed_export} = Manifest.reserve(state, :late, :source, "late.bin", 1)
    assert {:error, :closed_export} = Manifest.seal(state, :epoch, :other_seal)
  end

  test "occurrence bindings cannot select another target or source revision" do
    ref = occurrence(:edge, :target)
    state = complete([ref])
    assert {:ok, snapshot, _} = Manifest.seal(state, :epoch, :seal)

    assert {:error, :invalid_occurrence_binding} =
             Manifest.resolve(snapshot, :page, %{ref | target: :other})

    assert {:error, :invalid_occurrence_binding} =
             Manifest.resolve(snapshot, :page, %{ref | source_revision: :other})

    assert {:error, :invalid_occurrence_binding} =
             Manifest.resolve(snapshot, :page, %{ref | url: "https://other.com/"})

    assert {:error, :invalid_occurrence_binding} = Manifest.resolve(snapshot, :other, ref)
  end

  test "outcome identity mismatches and duplicate target registration are explicit" do
    state = admit(new(), :page, :rep)
    assert {:error, :target_exists} = Manifest.admit(state, :page, :rep, :page)
    wrong = %{Outcome.new(:succeeded) | representation_id: :wrong}
    assert {:error, :outcome_identity_mismatch} = Manifest.settle(state, :page, wrong)
    assert {:error, :unknown_target} = Manifest.settle(state, :missing, Outcome.new(:failed))
  end

  test "artifact IDs are distinct and response source revisions are required" do
    state =
      new()
      |> admit(:page, :rep)
      |> response(:rep)
      |> interpretation(:page, "p")
      |> admit(:other, :rep)

    attrs = interpretation_attrs("p")
    assert {:error, :artifact_exists} = Manifest.put_interpretation(state, :other, attrs)

    assert {:error, :source_revision_mismatch} =
             Manifest.put_interpretation(state, :other, %{attrs | source_revision: :old})

    duplicate = occurrence(:same, nil)

    assert {:error, :duplicate_occurrence} =
             Manifest.put_edges(state, :page, [duplicate, duplicate])
  end

  test "opaque payload handles do not cause bodies, analysis or outcome reasons to be retained" do
    state = admit(new(), :page, :rep)
    state = write(state, :source, "source.bin", :source, 1)
    secret = String.duplicate("private-response", 10_000)

    attrs = %{
      source_handle: :disk,
      source_revision: :revision,
      source_ticket: :source,
      final_url: "https://example.com/",
      content_type: "text/css",
      body: secret,
      analysis: secret
    }

    assert {:ok, state} = Manifest.put_response(state, :rep, attrs)
    outcome = Outcome.new(:failed, secret)
    assert {:ok, state} = Manifest.settle(state, :page, outcome)
    assert :erlang.external_size(state) < 5_000
    assert state.responses.rep.source_handle == :disk
    assert state.targets.page.outcome == :failed
  end

  test "binary assets use source copies without a fake lexical analysis" do
    state = new() |> admit(:image, :image_rep) |> response(:image_rep, "image/png")

    assert {:ok, state} =
             Manifest.put_interpretation(state, :image, %{
               source_revision: :revision,
               render_mode: :copy,
               public_id: String.duplicate("i", 24)
             })

    assert {:error, :copy_has_occurrences} =
             Manifest.put_edges(state, :image, [occurrence(:edge, nil)])

    state = state |> edges(:image, []) |> settle(:image)
    assert {:ok, snapshot, _} = Manifest.seal(state, :epoch, :seal)
    assert snapshot.artifacts.image.render_mode == :copy
    assert snapshot.artifacts.image.analysis_handle == nil
    assert snapshot.artifacts.image.occurrences_handle == nil
    assert String.ends_with?(snapshot.artifacts.image.path, ".png")
  end

  test "large real occurrence IDs use the bounded metadata envelope rather than a second identity" do
    state = new() |> admit(:page, :rep) |> response(:rep) |> interpretation(:page, "p")
    ref = %{occurrence(:edge, nil) | id: {:source, String.duplicate("context", 100)}}
    assert {:ok, state} = Manifest.put_edges(state, :page, [ref])
    state = settle(state, :page)
    assert {:ok, snapshot, _} = Manifest.seal(state, :epoch, :seal)
    assert {:online, _} = Manifest.resolve(snapshot, :page, ref)

    state =
      new(%{max_artifacts: 1})
      |> admit(:page, :rep)
      |> response(:rep)
      |> interpretation(:page, "p")
      |> admit(:other, :rep)

    assert {:error, {:limit, :max_artifacts}} =
             Manifest.put_interpretation(state, :other, interpretation_attrs("q"))
  end

  test "all retained metadata, identity counts, edge counts and peak staged bytes are bounded" do
    for {key, action} <- [
          {:max_targets, fn state -> Manifest.admit(state, :other, :rep, :other) end},
          {:max_representations,
           fn state -> Manifest.admit(state, :other, :other_rep, :other) end}
        ] do
      state = new(%{key => 1}) |> admit(:page, :rep)
      assert {:error, {:limit, ^key}} = action.(state)
    end

    state = new(%{max_manifest_bytes: 1})
    assert {:error, {:limit, :max_manifest_bytes}} = Manifest.admit(state, :page, :rep, :page)
    state = new(%{max_staged_bytes: 10, max_file_bytes: 10})
    assert {:ok, state} = Manifest.reserve(state, :one, :source, "one.bin", 6)
    assert {:ok, state} = Manifest.written(state, :one)

    assert {:error, {:limit, :max_staged_bytes}} =
             Manifest.reserve(state, :two, :source, "two.bin", 5)

    assert {:error, {:limit, :max_file_bytes}} =
             Manifest.reserve(state, :two, :source, "two.bin", 11)

    state = new(%{max_staged_metadata_bytes: 1})

    assert {:error, {:limit, :max_staged_metadata_bytes}} =
             Manifest.reserve(state, :one, :metadata, "facts.bin", 2)

    state = new(%{max_files: 1})
    assert {:ok, state} = Manifest.reserve(state, :one, :source, "one.bin", 1)
    assert {:error, {:limit, :max_files}} = Manifest.reserve(state, :two, :source, "two.bin", 1)

    state =
      new(%{max_edges: 1}) |> admit(:page, :rep) |> response(:rep) |> interpretation(:page, "p")

    assert {:error, {:limit, :max_edges}} =
             Manifest.put_edges(state, :page, [occurrence(:one, nil), occurrence(:two, nil)])
  end

  test "ready requires every rendered file and the public manifest before promotion acknowledgment" do
    assert {:ok, snapshot, state} = Manifest.seal(complete(), :epoch, :seal)
    assert Manifest.status(state).state == :finalizing
    assert {:error, :unrendered_artifact} = Manifest.ready(state, :seal, :manifest)
    path = snapshot.artifacts.page.path
    state = write(state, :archive, path, :archive, 4)
    assert {:ok, state} = Manifest.rendered(state, :seal, :page, :archive)
    assert {:error, :missing_public_manifest} = Manifest.validate_commit(state, :seal, :manifest)
    state = write(state, :archive, "manifest.json", :manifest, 100)
    assert :ok = Manifest.validate_commit(state, :seal, :manifest)
    assert {:ok, state} = Manifest.ready(state, :seal, :manifest)
    assert Manifest.status(state).state == :ready
    assert {:error, :closed_export} = Manifest.cancel(state)
  end

  for terminal <- [:failed, :cancelled] do
    test "#{terminal} cannot become ready and a sealed token cannot bypass revocation" do
      assert {:ok, _, state} = Manifest.seal(complete(), :epoch, :seal)

      result =
        case unquote(terminal) do
          :failed -> Manifest.fail(state, :write)
          :cancelled -> Manifest.cancel(state)
        end

      assert {:ok, state} = result
      assert {:error, :closed_export} = Manifest.ready(state, :seal, :manifest)

      assert {:error, :closed_export} =
               Manifest.reserve(state, :archive, :archive, "manifest.json", 1)
    end
  end

  defp new(overrides \\ %{}) do
    {:ok, state} = Manifest.new(@id, :epoch, Map.merge(@limits, overrides))
    state
  end

  defp admit(state, target, representation) do
    {:ok, state} = Manifest.admit(state, target, representation, target)
    state
  end

  defp write(state, area, path, ticket, size) do
    {:ok, state} = Manifest.reserve(state, ticket, area, path, size)
    {:ok, state} = Manifest.written(state, ticket)
    state
  end

  defp response(state, representation, type \\ "text/html") do
    ticket = {:source, representation}
    path = "source-#{map_size(state.responses)}.bin"
    state = write(state, :source, path, ticket, 20)

    {:ok, state} =
      Manifest.put_response(state, representation, %{
        source_handle: {:disk, representation},
        source_revision: :revision,
        source_ticket: ticket,
        content_type: type,
        final_url: "https://private-user:private-password@example.com/misleading.txt",
        authorization: "private-password",
        headers: [{"set-cookie", "private-password"}],
        opts: %{auth: "private-password"}
      })

    state
  end

  defp interpretation_attrs(id),
    do: %{
      public_id: String.duplicate(id, 24),
      source_revision: :revision,
      analysis_revision: :revision,
      render_mode: :rewrite,
      analysis_handle: :analysis,
      occurrences_handle: :occurrences
    }

  defp interpretation(state, target, id) do
    {:ok, state} = Manifest.put_interpretation(state, target, interpretation_attrs(id))
    state
  end

  defp edges(state, target, refs) do
    {:ok, state} = Manifest.put_edges(state, target, refs)
    state
  end

  defp settle(state, target, outcome \\ :succeeded) do
    {:ok, state} = Manifest.settle(state, target, Outcome.new(outcome))
    state
  end

  defp occurrence(id, target),
    do: %Occurrence{
      id: id,
      region: :root,
      value: "./extensionless#anchor",
      url: "https://private-user:private-password@example.com/extensionless",
      context: %{},
      target: target,
      source_revision: :revision,
      fragment: "anchor"
    }

  defp complete(refs \\ []),
    do:
      new()
      |> admit(:page, :rep)
      |> response(:rep)
      |> interpretation(:page, "p")
      |> edges(:page, refs)
      |> settle(:page)
end
