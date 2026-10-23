defmodule Crawler.SnapperTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis
  alias Crawler.Analysis.Budget
  alias Crawler.Options
  alias Crawler.Parser
  alias Crawler.Snapper

  @id "standalone0000000000000001"
  @bom <<0xEF, 0xBB, 0xBF>>

  setup do
    root =
      Path.join([File.cwd!(), "test", "tmp", "snapper-#{System.unique_integer([:positive])}"])

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    opts =
      Options.assign_defaults(%{
        public_id: @id,
        save_to: root,
        url: "https://private-user:private-password@example.test/dir/fake.js",
        content_type: "text/html"
      })

    {:ok, root: root, opts: opts}
  end

  test "HTML output has one BOM and keeps unrelated source", %{root: root, opts: opts} do
    source = "<!-- note --><p title='café &amp; tea'>source</p>"
    assert {:ok, artifact} = Snapper.snap(source, opts)
    assert File.read!(Path.join(root, artifact.path)) == @bom <> source

    assert {:ok, ^artifact} = Snapper.snap(@bom <> source, opts)
    assert File.read!(Path.join(root, artifact.path)) == @bom <> source
  end

  for {type, suffix, source} <- [
        {"application/xhtml+xml", ".xhtml", "<?xml version='1.0'?><html>café</html>"},
        {"application/xml", ".xml", "<?xml version='1.0'?><root>café</root>"},
        {"text/css", ".css", "@charset 'utf-8'; .café { color: red }"},
        {"text/javascript", ".js", "const label = 'café';"},
        {"text/plain", ".txt", "café"},
        {"image/png", ".png", <<0x89, 0xFF, 0xE9, 0>>},
        {"application/x-unknown", ".bin", <<0xFF, 0xFE, 0, 1>>}
      ] do
    test "#{type} keeps its bytes and response suffix", %{root: root, opts: opts} do
      source = unquote(source)
      opts = %{opts | content_type: unquote(type)}
      assert {:ok, artifact} = Snapper.snap(source, opts)
      assert Path.extname(artifact.path) == unquote(suffix)
      assert File.read!(Path.join(root, artifact.path)) == source
    end
  end

  test "supported text rejects raw invalid UTF-8 without an implicit decoder", %{
    root: root,
    opts: opts
  } do
    assert {:error, :invalid_utf8} = Snapper.snap(<<255>>, opts)
    assert File.ls!(root) == []
  end

  test "unbound references stay online even after another standalone file is saved", %{
    root: root,
    opts: opts
  } do
    target = "https://private-user:private-password@example.test/next?q=1&x=2"
    target_opts = %{opts | public_id: "standalone0000000000000002", url: target}
    assert {:ok, saved_target} = Snapper.snap("<p>TARGET</p>", target_opts)
    assert File.read!(Path.join(root, saved_target.path)) == @bom <> "<p>TARGET</p>"

    source = ~s|<p data-keep='&amp;'>keep</p><a href="#{target}#section">next</a>|
    assert {:ok, artifact} = Snapper.snap(source, opts)

    expected =
      ~s|<p data-keep='&amp;'>keep</p><a href="https://example.test/next?q&#61;1&amp;x&#61;2#section">next</a>|

    assert File.read!(Path.join(root, artifact.path)) == @bom <> expected

    assert Floki.attribute(Floki.parse_document!(expected), "a", "href") ==
             ["https://example.test/next?q=1&x=2#section"]

    refute File.read!(Path.join(root, artifact.path)) =~ saved_target.path
  end

  test "Prepared uses its authoritative collection and existing analysis", %{
    root: root,
    opts: opts
  } do
    source = ~s|<a href="next#anchor">next</a><!-- untouched -->|
    assert {:ok, prepared} = Parser.prepare_for_parse(source, opts)
    prepared = %{prepared | source: <<255>>, occurrences: [], groups: []}

    assert {:ok, artifact} = Snapper.snap(prepared, opts)

    assert File.read!(Path.join(root, artifact.path)) ==
             @bom <> ~s|<a href="https://example.test/dir/next#anchor">next</a><!-- untouched -->|
  end

  test "HTML BOM output must fit the continuing post-render allocation budget", %{
    root: root,
    opts: opts
  } do
    source = "<p>" <> String.duplicate("x", 65_536) <> "</p><a href='next'>next</a>"
    assert {:ok, prepared} = Parser.prepare_for_parse(source, opts)

    assert {:ok, rendered, original_stats} =
             Analysis.render_with_stats(
               prepared.analysis,
               prepared.collection,
               &Analysis.online_fallback/1
             )

    assert original_stats.budget.retained > prepared.collection.budget.retained
    needed = byte_size(rendered) + byte_size(@bom) + Budget.cost(:binary)
    unavailable = original_stats.budget.limit - original_stats.budget.retained - needed + 1

    assert {:ok, budget} =
             Budget.charge(prepared.collection.budget, unavailable)

    constrained = %{prepared | collection: %{prepared.collection | budget: budget}}

    assert {:ok, ^rendered, stats} =
             Analysis.render_with_stats(
               constrained.analysis,
               constrained.collection,
               &Analysis.online_fallback/1
             )

    assert stats.budget.limit - stats.budget.retained == needed - 1
    assert Budget.available(constrained.collection.budget) >= needed
    assert {:error, {:limit, :analysis_bytes}} = Snapper.snap(constrained, opts)
    refute File.exists?(Path.join(root, "resources"))
    assert File.ls!(Path.join(root, ".crawler-fs-claims")) == [".crawler-fs-owner"]

    assert {:ok, budget} = Budget.charge(prepared.collection.budget, unavailable - 1)
    constrained = %{prepared | collection: %{prepared.collection | budget: budget}}
    assert {:ok, artifact} = Snapper.snap(constrained, opts)
    assert File.read!(Path.join(root, artifact.path)) == @bom <> rendered
  end

  test "an existing BOM reuses the rendered binary with no additional allocation", %{
    root: root,
    opts: opts
  } do
    source = @bom <> "<p>unchanged</p>"
    assert {:ok, prepared} = Parser.prepare_for_parse(source, opts)

    assert {:ok, budget} =
             Budget.charge(
               prepared.collection.budget,
               Budget.available(prepared.collection.budget)
             )

    prepared = %{prepared | collection: %{prepared.collection | budget: budget}}
    assert {:ok, artifact} = Snapper.snap(prepared, opts)
    assert File.read!(Path.join(root, artifact.path)) == source
  end
end
