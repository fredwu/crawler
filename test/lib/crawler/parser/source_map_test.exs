defmodule Crawler.Parser.SourceMapTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis
  alias Crawler.Parser.SourceMap

  @map_opts %{
    url: "http://host/maps/app.js.map",
    referrer_url: "http://host/maps/app.js.map",
    content_type: "application/json",
    fetch_kind: :source_map
  }

  test "sourceRoot prefixes only a relative source" do
    rooted =
      ~s|{"version":3,"sourceRoot":"../src","sources":["/abs.ts","app.ts","https://cdn.example/lib.ts","webpack://app/boot.ts"],"mappings":""}|

    assert urls(rooted) == [
             "http://host/abs.ts",
             "http://host/src/app.ts",
             "https://cdn.example/lib.ts"
           ]

    empty = ~s|{"version":3,"sourceRoot":"","sources":["app.ts"],"mappings":""}|
    missing = ~s|{"version":3,"sources":["app.ts"],"mappings":""}|
    assert urls(empty) == ["http://host/maps/app.ts"]
    assert urls(missing) == ["http://host/maps/app.ts"]

    absolute =
      ~s|{"version":3,"sourceRoot":"https://cdn.test/src","sources":["/abs.ts","app.ts","https://other.test/lib.ts"],"mappings":""}|

    assert urls(absolute) == [
             "http://host/abs.ts",
             "https://cdn.test/src/app.ts",
             "https://other.test/lib.ts"
           ]
  end

  test "a non-integer version or invalid JSON adds no sources" do
    assert urls(~s|{"version":3.0,"sources":["app.ts"],"mappings":""}|) == []
    assert urls(~s|{"version":2,"sources":["app.ts"],"mappings":""}|) == []
    assert urls("{") == []
  end

  test "a data map decodes base64 and ignores a bad percent escape" do
    opts = %{
      url: "http://host/js/app.js",
      referrer_url: "http://host/js/app.js",
      content_type: "application/javascript"
    }

    json = ~s|{"version":3,"sources":["src/app.ts"],"mappings":""}|
    encoded = "data:application/json;BASE64," <> Base.encode64(json)
    refs = SourceMap.link_refs("//# sourceMappingURL=#{encoded}", opts, :javascript)
    assert Enum.map(refs, & &1.url) == ["http://host/js/src/app.ts"]

    broken = "//# sourceMappingURL=data:application/json,%ZZ"
    assert SourceMap.link_refs(broken, opts, :javascript) == []
  end

  test "an external file resolves from the landed URL, not sourceURL or document base" do
    body = "//# sourceURL=generated/app.js\n//# sourceMappingURL=app.js.map\n"

    landed =
      SourceMap.javascript(body, %{
        content_type: "application/javascript",
        url: "http://host/base/app.js",
        referrer_url: "http://host/cdn/app.js",
        document_base: "http://host/assets/"
      })

    assert landed.url == "http://host/cdn/app.js.map"

    fallback = %{
      content_type: "application/javascript",
      url: "http://host/base/app.js",
      referrer_url: "",
      document_base: "http://host/assets/"
    }

    assert SourceMap.javascript(body, fallback).url == "http://host/base/app.js.map"

    assert Enum.map(SourceMap.link_refs(body, fallback, :javascript), & &1.url) == [
             "http://host/base/app.js.map"
           ]

    css = "/*# sourceURL=generated/app.css */\n/*# sourceMappingURL=app.css.map */\n"

    sheet = %{
      content_type: "text/css",
      url: "http://host/base/app.css",
      referrer_url: "",
      document_base: "http://host/assets/"
    }

    assert SourceMap.css(css, sheet).url == "http://host/base/app.css.map"

    assert Enum.map(SourceMap.link_refs(css, sheet, :css), & &1.url) == [
             "http://host/base/app.css.map"
           ]
  end

  test "a style sourceURL does not move the map and is not fetched" do
    body = "/*# sourceURL=generated/app.css */\n/*# sourceMappingURL=app.css.map */\n"
    page = "http://example.com/page"
    base = "http://example.com/assets/"

    discovery = %{
      content_type: "text/html",
      url: page,
      referrer_url: base,
      document_base: base
    }

    rewrite = %{
      content_type: "text/css",
      inline_source: true,
      headers: [],
      url: page,
      referrer_url: base
    }

    assert_style_map(body, discovery)
    assert_style_map(body, rewrite)
  end

  test "an inline sourceURL is the base of sources inside a data map" do
    raw = ~s|{"version":3,"sources":["app.ts"],"mappings":""}|
    data = "data:application/json," <> raw
    body = "//# sourceURL=generated/app.js\n//# sourceMappingURL=#{data}\n"
    page = "http://example.com/page"
    base = "http://example.com/assets/"
    source = base <> "generated/app.ts"

    discovery = %{
      content_type: "text/html",
      url: page,
      referrer_url: base,
      document_base: base
    }

    rewrite = %{
      content_type: "application/javascript",
      inline_source: true,
      headers: [],
      url: page,
      referrer_url: base,
      document_base: base
    }

    assert_data_sources(body, discovery, source, page)
    assert_data_sources(body, rewrite, source, page)
  end

  test "a rewritten data map keeps a hash inside the payload" do
    json =
      ~s|{"version":3,"file":"a#b.js","sources":["app.ts"],"sourcesContent":[null],"mappings":"A#A"}|

    data = "data:application/json," <> URI.encode(json, &URI.char_unreserved?/1)
    body = "//# sourceMappingURL=#{data}"
    page = "http://example.com/page"
    script = "http://example.com/js/app.js"
    source = "http://example.com/js/app.ts"

    opts = %{
      content_type: "application/javascript",
      url: page,
      referrer_url: script
    }

    assert Enum.map(SourceMap.link_refs(body, opts, :javascript), & &1.url) == [source]

    text = render_data_map(body, opts)

    assert URI.parse(text).fragment == nil

    decoded = decoded_data(text)
    assert String.contains?(decoded, "fixtures/app.ts")
    refute String.contains?(decoded, ~s("app.ts"))
    assert String.contains?(decoded, "a#b.js")
    assert String.contains?(decoded, "A#A")

    assert decoded ==
             ~s|{"version":3,"file":"a#b.js","sources":["fixtures/app.ts"],"sourcesContent":[null],"mappings":"A#A"}|
  end

  test "a bound local map drops sourceRoot and keeps unrelated map members" do
    map = "http://example.com/js/app.js.map"
    lib = "https://cdn.test/lib.ts"

    body =
      ~s|{"version":3,"sourceRoot":"../src","sources":["app.ts","#{lib}"],"mappings":"AAAA","file":"app.js"}|

    {:ok, saved} = replace_local_map(body, map_file_opts(map))

    assert String.contains?(saved, ~s("sourceRoot":""))
    refute String.contains?(saved, ~s("sourceRoot":"../src"))
    assert String.contains?(saved, "fixtures/app.ts")
    assert String.contains?(saved, "fixtures/lib.ts")
    assert String.contains?(saved, ~s("mappings":"AAAA"))
    assert String.contains?(saved, ~s("file":"app.js"))

    sections =
      ~s|{"version":3,"sourceRoot":"../src","sections":[{"map":{"version":3,"sourceRoot":"lib","sources":["inline.ts"],"mappings":""}}]}|

    {:ok, section_saved} = replace_local_map(sections, map_file_opts(map))
    assert String.contains?(section_saved, ~s("sourceRoot":""))
    refute String.contains?(section_saved, ~s("sourceRoot":"../src"))
    refute String.contains?(section_saved, ~s("sourceRoot":"lib"))
    assert String.contains?(section_saved, "fixtures/inline.ts")

    embedded =
      ~s|{"version":3,"sourceRoot":"../src","sources":["app.ts"],"sourcesContent":["export {}"],"mappings":""}|

    assert replace_local_map(embedded, map_file_opts(map)) ==
             {:ok, embedded}

    index =
      ~s|{"version":3,"sections":[{"url":"part.js.map"},{"map":{"version":3,"sourceRoot":"../src","sources":["app.ts"],"sourcesContent":["export {}"],"mappings":"AAAA"}}]}|

    {:ok, index_saved} = replace_local_map(index, map_file_opts(map))
    assert String.contains?(index_saved, ~s("sourceRoot":"../src"))
    assert String.contains?(index_saved, "fixtures/part.js.map")
    assert String.contains?(index_saved, "export {}")
  end

  test "a saved data map drops sourceRoot around an offline source" do
    json = ~s|{"version":3,"sourceRoot":"../src","sources":["app.ts"],"mappings":"AAAA"}|
    data = "data:application/json," <> URI.encode(json, &URI.char_unreserved?/1)
    body = "//# sourceMappingURL=#{data}"
    page = "http://example.com/page"
    script = "http://example.com/js/app.js"

    opts = %{
      content_type: "application/javascript",
      url: page,
      referrer_url: script
    }

    assert Enum.map(SourceMap.link_refs(body, opts, :javascript), & &1.url) == [
             "http://example.com/src/app.ts"
           ]

    text = render_data_map(body, opts)

    decoded = decoded_data(text)
    assert String.contains?(decoded, ~s("sourceRoot":""))
    refute String.contains?(decoded, ~s("sourceRoot":"../src"))
    assert String.contains?(decoded, "fixtures/app.ts")
    assert String.contains?(decoded, ~s("mappings":"AAAA"))

    section =
      ~s|{"version":3,"sections":[{"url":"part.js.map"},{"map":{"version":3,"sourceRoot":"../src","sources":["app.ts"],"sourcesContent":["export {}"],"mappings":"AAAA"}}]}|

    section_data = "data:application/json," <> URI.encode(section, &URI.char_unreserved?/1)
    section_body = "//# sourceMappingURL=#{section_data}"

    section_text = render_data_map(section_body, opts)

    section_decoded = decoded_data(section_text)

    assert String.contains?(section_decoded, ~s("sourceRoot":"../src"))

    assert String.contains?(
             section_decoded,
             "fixtures/part.js.map"
           )

    assert String.contains?(section_decoded, "export {}")

    assert section_decoded ==
             ~s|{"version":3,"sections":[{"url":"fixtures/part.js.map"},{"map":{"version":3,"sourceRoot":"../src","sources":["app.ts"],"sourcesContent":["export {}"],"mappings":"AAAA"}}]}|
  end

  test "a classic script reads a source map comment after a division" do
    body = "await /x//# sourceMappingURL=app.js.map"
    page = "http://host/page"
    script = "http://host/js/app.js"
    map = "http://host/js/app.js.map"

    opts = %{
      content_type: "application/javascript",
      url: page,
      referrer_url: script,
      javascript_goal: :script
    }

    assert SourceMap.javascript(body, opts).url == map

    assert {:ok, analysis} = Analysis.analyze(body, opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)

    assert [
             %{
               url: ^map,
               source_role: {:javascript, :script},
               context: %{fetch_kind: :source_map}
             }
           ] = collection.occurrences

    assert {:ok, bound} =
             Analysis.bind(collection, fn ref ->
               assert ref.value == map
               %{fixture: :classic_map, path: "fixtures/app.js.map"}
             end)

    assert {:ok, saved} =
             Analysis.render(analysis, bound, fn ref -> {:local, ref.target.path} end)

    assert saved == "await /x//# sourceMappingURL=fixtures/app.js.map"

    module = Map.put(opts, :javascript_goal, :module)
    assert SourceMap.javascript(body, module) == nil
  end

  test "a CSS string or a slash comment is not a source map note" do
    css = """
    /*# sourceMappingURL=real.css.map */
    //# sourceMappingURL=nope.css.map
    body { content: "/*# sourceMappingURL=fake.css.map */"; }
    """

    note =
      SourceMap.css(css, %{
        url: "http://host/app.css",
        referrer_url: "http://host/app.css",
        content_type: "text/css"
      })

    assert note.url == "http://host/real.css.map"
  end

  test "bound data maps keep BOM, encoding, and unrelated bytes while escaping fixture paths" do
    payload =
      "\uFEFF" <>
        ~S|{ "version":3, "sourceRoot":"../src", "sources":["app.ts"], "mappings":"A#A", "file":"a#b.js" }|

    path = "fixtures/a\"b\\c#d.ts"

    expected =
      "\uFEFF" <>
        ~S|{ "version":3, "sourceRoot":"", "sources":["fixtures/a\"b\\c#d.ts"], "mappings":"A#A", "file":"a#b.js" }|

    opts = %{url: "https://example.test/js/app.js", content_type: "application/javascript"}

    for encoding <- [:percent, :base64] do
      meta =
        if encoding == :base64, do: "data:application/json;base64", else: "data:application/json"

      data = SourceMap.encode_data(payload, meta, encoding)
      source = "/* café */\n//# sourceMappingURL=" <> data <> "\n"

      assert Enum.map(SourceMap.link_refs(source, opts, :javascript), & &1.url) == [
               "https://example.test/src/app.ts"
             ]

      assert {:ok, rendered} = replace_local_map(source, opts, path)

      assert rendered ==
               "/* café */\n//# sourceMappingURL=" <>
                 SourceMap.encode_data(expected, meta, encoding) <> "\n"

      [_, emitted] = String.split(rendered, "//# sourceMappingURL=", parts: 2)
      emitted = String.trim_trailing(emitted, "\n")
      assert URI.parse(emitted).fragment == nil
      assert {:ok, ^expected, ^meta, ^encoding} = SourceMap.decode_data(emitted)
    end
  end

  defp replace_local_map(source, opts, app_path \\ "fixtures/app.ts") do
    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)

    assert {:ok, bound} =
             Analysis.bind(collection, fn
               %{source_role: :source_map, value: "app.ts", context: %{fetch_kind: nil}} ->
                 %{fixture: :app, path: app_path}

               %{
                 source_role: :source_map,
                 value: "https://cdn.test/lib.ts",
                 context: %{fetch_kind: nil}
               } ->
                 %{fixture: :library, path: "fixtures/lib.ts"}

               %{source_role: :source_map, value: "inline.ts", context: %{fetch_kind: nil}} ->
                 %{fixture: :inline, path: "fixtures/inline.ts"}

               %{
                 source_role: :source_map,
                 value: "part.js.map",
                 context: %{fetch_kind: :source_map}
               } ->
                 %{fixture: :part, path: "fixtures/part.js.map"}

               _ref ->
                 nil
             end)

    Analysis.render(analysis, bound, fn
      %{target: %{path: path}} -> {:local, path}
      _ref -> :keep
    end)
  end

  defp render_data_map(body, opts) do
    {source, opts} =
      if opts.content_type == "text/html" do
        {"<script type=\"module\">" <> body <> "</script>", Map.put(opts, :assets, ["js"])}
      else
        {body, opts}
      end

    assert {:ok, rendered} = replace_local_map(source, opts)
    [prefix, original_tail] = String.split(source, "//# sourceMappingURL=", parts: 2)
    [_, tail] = String.split(rendered, "//# sourceMappingURL=", parts: 2)
    data = tail |> String.split(["\n", "</script>"], parts: 2) |> hd()
    original_data = original_tail |> String.split(["\n", "</script>"], parts: 2) |> hd()

    suffix =
      binary_part(
        original_tail,
        byte_size(original_data),
        byte_size(original_tail) - byte_size(original_data)
      )

    assert rendered == prefix <> "//# sourceMappingURL=" <> data <> suffix
    data
  end

  defp map_file_opts(map) do
    %{
      fetch_kind: :source_map,
      url: map,
      referrer_url: map,
      content_type: "application/json"
    }
  end

  defp urls(body) do
    body
    |> SourceMap.entries(@map_opts)
    |> Enum.map(& &1.url)
  end

  defp assert_style_map(body, opts) do
    assert SourceMap.css(body, opts).url == "http://example.com/assets/app.css.map"

    assert Enum.map(SourceMap.link_refs(body, opts, :css), & &1.url) == [
             "http://example.com/assets/app.css.map"
           ]
  end

  defp assert_data_sources(body, opts, source, _page) do
    assert Enum.map(SourceMap.link_refs(body, opts, :javascript), & &1.url) == [source]

    text = render_data_map(body, opts)

    decoded = decoded_data(text)
    assert String.contains?(decoded, "fixtures/app.ts")

    refute String.contains?(
             decoded,
             "http://example.com/assets/app.ts"
           )

    refute String.contains?(decoded, "generated/app.js")
  end

  defp decoded_data(url) do
    assert {:ok, payload, _meta, _encoding} = SourceMap.decode_data(url)
    payload
  end
end
