defmodule Crawler.Analysis.JSONResultTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis

  @opts %{
    content_type: "application/json",
    url: "https://example.test/dir/file.json",
    max_bytes: 20_000_000
  }

  test "all JSON resource keys reach every root control role as explicit JSON limits" do
    fixtures = [
      max_depth: String.duplicate("[", 129) <> "0" <> String.duplicate("]", 129),
      max_tokens: "[" <> Enum.map_join(1..100_001, ",", fn _ -> "0" end) <> "]",
      max_string_bytes: "\"" <> String.duplicate("x", 1_048_577) <> "\"",
      max_number_bytes: String.duplicate("1", 1_025),
      max_input_bytes: String.duplicate(" ", 10_485_761)
    ]

    for role <- [:manifest, :speculation_rules, :source_map], {key, source} <- fixtures do
      assert {:error, {:limit, {:json, ^key}}} =
               Analysis.analyze(source, Map.put(@opts, :fetch_kind, role))
    end
  end

  test "invalid root JSON keeps an invalid result distinct from resource limits" do
    for role <- [:manifest, :speculation_rules, :source_map],
        source <- [~S|{"bad":"\q"}|, "{", "[1,]"] do
      assert {:error, :invalid_json} = Analysis.analyze(source, Map.put(@opts, :fetch_kind, role))
    end
  end

  test "inline import maps and rules propagate JSON depth and string limits in HTML and XHTML" do
    limited = [
      max_depth: String.duplicate("[", 129) <> "0" <> String.duplicate("]", 129),
      max_string_bytes: "\"" <> String.duplicate("x", 1_048_577) <> "\""
    ]

    for type <- ["text/html", "application/xhtml+xml"],
        role <- ["importmap", "speculationrules"],
        {key, payload} <- limited do
      source = ~s|<script type="#{role}">#{payload}</script><a href="next">next</a>|

      assert {:error, {:limit, {:json, ^key}}} =
               Analysis.analyze(source, Map.put(@opts, :content_type, type))
    end
  end

  test "invalid inline maps and rules stay inert and preserve later references" do
    for role <- ["importmap", "speculationrules"] do
      source =
        ~s|<script type="#{role}">| <> ~S|{"bad":"\q"}| <> ~s|</script><a href="next">next</a>|

      opts = Map.merge(@opts, %{content_type: "text/html", assets: ["js"]})
      assert {:ok, analysis} = Analysis.analyze(source, opts)
      assert {:ok, [ref]} = Analysis.occurrences(analysis, opts)
      assert ref.value == "next"
    end
  end

  test "embedded percent and base64 data maps propagate limits through JS, CSS and headers" do
    payload = String.duplicate("[", 129) <> "0" <> String.duplicate("]", 129)

    for encoding <- [:percent, :base64], type <- ["text/javascript", "text/css"] do
      meta =
        if encoding == :base64, do: "data:application/json;base64", else: "data:application/json"

      url = Crawler.Parser.SourceMap.encode_data(payload, meta, encoding)

      source =
        if type == "text/css",
          do: "/*# sourceMappingURL=" <> url <> " */",
          else: "//# sourceMappingURL=" <> url

      opts = Map.put(@opts, :content_type, type)
      assert {:error, {:limit, {:json, :max_depth}}} = Analysis.analyze(source, opts)

      assert {:error, {:limit, {:json, :max_depth}}} =
               Analysis.analyze("", Map.put(opts, :headers, [{"sourcemap", url}]))
    end
  end

  test "a limited inline JSON region inside srcdoc cannot become empty success" do
    payload = String.duplicate("[", 129) <> "0" <> String.duplicate("]", 129)
    source = "<iframe srcdoc='<script type=\"importmap\">" <> payload <> "</script>'></iframe>"

    assert {:error, {:limit, {:json, :max_depth}}} =
             Analysis.analyze(source, Map.put(@opts, :content_type, "text/html"))
  end
end

defmodule Crawler.Analysis.JSONRoleReuseTest do
  use ExUnit.Case, async: false

  alias Crawler.Analysis
  alias Crawler.Analysis.Occurrence

  @opts %{
    content_type: "application/json",
    url: "https://example.test/dir/shared.json",
    assets: ["images"]
  }
  @source ~s|{"version":3,"sourceRoot":"../src","sources":["source.js"],"start_url":"./home","prefetch":[{"urls":["./next"]}]}|

  test "each supported root role order derives and renders from one located JSON read" do
    call = {Crawler.ImportMap.JSON, :decode_located_result, 2}

    for first <- [:manifest, :speculation_rules, :source_map],
        second <- [:manifest, :speculation_rules, :source_map],
        first != second do
      :erlang.trace_pattern(call, true, [:call_count])

      try do
        opts = Map.put(@opts, :fetch_kind, first)
        assert {:ok, analysis} = Analysis.analyze(@source, opts)
        assert analysis.mode == :json
        assert analysis.stats.scans == %{json: 1}

        for role <- [first, second] do
          assert {:ok, [ref]} = Analysis.occurrences(analysis, Map.put(opts, :fetch_kind, role))
          assert ref.source_role == role
          assert ref.source_mode == :json
          assert ref.context.fetch_kind == nil
          ref = Occurrence.bind(ref, {:target, role})

          assert {:ok, output} =
                   Analysis.render(analysis, [ref], fn ref ->
                     {:target, selected_role} = ref.target
                     {:local, "/saved/" <> Atom.to_string(selected_role)}
                   end)

          case role do
            :manifest ->
              assert output =~ ~s|"start_url":"/saved/manifest"|
              assert output =~ ~s|"sources":["source.js"]|

            :speculation_rules ->
              assert output =~ ~s|"urls":["/saved/speculation_rules"]|
              assert output =~ ~s|"sourceRoot":"../src"|

            :source_map ->
              assert output =~ ~s|"sources":["/saved/source_map"]|
              assert output =~ ~s|"sourceRoot":""|
              assert output =~ ~s|"start_url":"./home"|
          end
        end

        assert {:call_count, 1} = :erlang.trace_info(call, :call_count)
      after
        :erlang.trace_pattern(call, false, [:call_count])
      end
    end
  end

  test "JSON roles do not alter lexical revision or erase interpretation identity" do
    assert {:ok, manifest} = Analysis.analyze(@source, Map.put(@opts, :fetch_kind, :manifest))

    assert {:ok, rules} =
             Analysis.analyze(@source, Map.put(@opts, :fetch_kind, :speculation_rules))

    assert manifest.revision == rules.revision

    assert {:ok, [manifest_ref]} =
             Analysis.occurrences(manifest, Map.put(@opts, :fetch_kind, :manifest))

    assert {:ok, [rules_ref]} =
             Analysis.occurrences(manifest, Map.put(@opts, :fetch_kind, :speculation_rules))

    refute manifest_ref.id == rules_ref.id

    assert {:ok, _output} =
             Analysis.render(rules, [Occurrence.bind(manifest_ref, :target)], fn _ ->
               {:local, "saved"}
             end)

    assert {:error, :incompatible_interpretations} =
             Analysis.render(manifest, [manifest_ref, rules_ref], fn _ -> :keep end)

    assert {:error, :incompatible_source_options} =
             Analysis.occurrences(manifest, Map.put(@opts, :fetch_kind, :unsupported))

    assert {:ok, different} =
             Analysis.analyze(@source <> " ", Map.put(@opts, :fetch_kind, :manifest))

    assert {:error, :invalid_occurrence} =
             Analysis.render(different, [manifest_ref], fn _ -> :keep end)
  end
end
