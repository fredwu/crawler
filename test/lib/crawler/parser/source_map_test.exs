defmodule Crawler.Parser.SourceMapTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker
  alias Crawler.Parser.ScriptReferences
  alias Crawler.Parser.SourceMap
  alias Crawler.Snapper.LinkReplacer

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

    text =
      body
      |> SourceMap.javascript(opts)
      |> SourceMap.rewrite_text(page, opts, :javascript, true)

    assert URI.parse(text).fragment == nil

    decoded = decoded_data(text)
    assert String.contains?(decoded, Linker.offline_link(page, source))
    refute String.contains?(decoded, ~s("app.ts"))
    assert String.contains?(decoded, "a#b.js")
    assert String.contains?(decoded, "A#A")
  end

  test "a saved map drops sourceRoot after a source becomes an offline path" do
    map = "http://example.com/js/app.js.map"
    source = "http://example.com/src/app.ts"
    lib = "https://cdn.test/lib.ts"
    nested = "http://example.com/js/lib/inline.ts"

    body =
      ~s|{"version":3,"sourceRoot":"../src","sources":["app.ts","#{lib}"],"mappings":"AAAA","file":"app.js"}|

    {:ok, saved} = LinkReplacer.replace_links(body, map_file_opts(map))

    assert String.contains?(saved, ~s("sourceRoot":""))
    refute String.contains?(saved, ~s("sourceRoot":"../src"))
    assert String.contains?(saved, Linker.offline_link(map, source))
    assert String.contains?(saved, Linker.offline_link(map, lib))
    assert String.contains?(saved, ~s("mappings":"AAAA"))
    assert String.contains?(saved, ~s("file":"app.js"))

    sections =
      ~s|{"version":3,"sourceRoot":"../src","sections":[{"map":{"version":3,"sourceRoot":"lib","sources":["inline.ts"],"mappings":""}}]}|

    {:ok, section_saved} = LinkReplacer.replace_links(sections, map_file_opts(map))
    assert String.contains?(section_saved, ~s("sourceRoot":""))
    refute String.contains?(section_saved, ~s("sourceRoot":"../src"))
    refute String.contains?(section_saved, ~s("sourceRoot":"lib"))
    assert String.contains?(section_saved, Linker.offline_link(map, nested))

    embedded =
      ~s|{"version":3,"sourceRoot":"../src","sources":["app.ts"],"sourcesContent":["export {}"],"mappings":""}|

    assert LinkReplacer.replace_links(embedded, map_file_opts(map)) ==
             {:ok, embedded}

    part = "http://example.com/js/part.js.map"

    index =
      ~s|{"version":3,"sections":[{"url":"part.js.map"},{"map":{"version":3,"sourceRoot":"../src","sources":["app.ts"],"sourcesContent":["export {}"],"mappings":"AAAA"}}]}|

    {:ok, index_saved} = LinkReplacer.replace_links(index, map_file_opts(map))
    assert String.contains?(index_saved, ~s("sourceRoot":"../src"))
    assert String.contains?(index_saved, Linker.offline_link(map, part))
    assert String.contains?(index_saved, "export {}")
  end

  test "a saved data map drops sourceRoot around an offline source" do
    json = ~s|{"version":3,"sourceRoot":"../src","sources":["app.ts"],"mappings":"AAAA"}|
    data = "data:application/json," <> URI.encode(json, &URI.char_unreserved?/1)
    body = "//# sourceMappingURL=#{data}"
    page = "http://example.com/page"
    script = "http://example.com/js/app.js"
    source = "http://example.com/src/app.ts"

    opts = %{
      content_type: "application/javascript",
      url: page,
      referrer_url: script
    }

    text =
      body
      |> SourceMap.javascript(opts)
      |> SourceMap.rewrite_text(page, opts, :javascript, true)

    decoded = decoded_data(text)
    assert String.contains?(decoded, ~s("sourceRoot":""))
    refute String.contains?(decoded, ~s("sourceRoot":"../src"))
    assert String.contains?(decoded, Linker.offline_link(page, source))
    assert String.contains?(decoded, ~s("mappings":"AAAA"))

    section =
      ~s|{"version":3,"sections":[{"url":"part.js.map"},{"map":{"version":3,"sourceRoot":"../src","sources":["app.ts"],"sourcesContent":["export {}"],"mappings":"AAAA"}}]}|

    section_data = "data:application/json," <> URI.encode(section, &URI.char_unreserved?/1)
    section_body = "//# sourceMappingURL=#{section_data}"

    section_text =
      section_body
      |> SourceMap.javascript(opts)
      |> SourceMap.rewrite_text(page, opts, :javascript, true)

    section_decoded = decoded_data(section_text)

    assert String.contains?(section_decoded, ~s("sourceRoot":"../src"))

    assert String.contains?(
             section_decoded,
             Linker.offline_link(page, "http://example.com/js/part.js.map")
           )

    assert String.contains?(section_decoded, "export {}")
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

    saved = ScriptReferences.rewrite(body, opts)
    assert saved == "await /x//# sourceMappingURL=" <> Linker.offline_link(page, map)

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

  defp assert_data_sources(body, opts, source, page) do
    assert Enum.map(SourceMap.link_refs(body, opts, :javascript), & &1.url) == [source]

    text =
      body
      |> SourceMap.javascript(opts)
      |> SourceMap.rewrite_text(page, opts, :javascript, true)

    decoded = decoded_data(text)
    assert String.contains?(decoded, Linker.offline_link(page, source))

    refute String.contains?(
             decoded,
             Linker.offline_link(page, "http://example.com/assets/app.ts")
           )

    refute String.contains?(decoded, "generated/app.js")
  end

  defp decoded_data(url) do
    [_, payload] = String.split(url, ",", parts: 2)
    URI.decode(payload)
  end
end
