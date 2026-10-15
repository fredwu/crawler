defmodule Crawler.ImportMapTest do
  use ExUnit.Case, async: true

  alias Crawler.ImportMap
  alias Crawler.ImportMap.JSON

  @base "http://example.com/assets/"
  @page "http://example.com/app.html"

  test "decodes import map JSON and rejects broken values" do
    assert JSON.decode("\uFEFF{}") == {:ok, {:object, []}}

    assert JSON.decode(~s|{"a":"/a.js","a":"/b.js"}|) ==
             {:ok, {:object, [{"a", "/a.js"}, {"a", "/b.js"}]}}

    assert ImportMap.parse(~s|{"imports":{"vue":"/a.js","vue":"/b.js"}}|, @base).imports["vue"] ==
             "http://example.com/b.js"

    assert {:ok, {:object, [{"a", <<0x10000::utf8>>}]}} =
             JSON.decode(~s|{"a":"\\uD800\\uDC00"}|)

    assert JSON.decode(~s|{"a":"\\uD800"}|) == :error
    assert JSON.decode(~s|{"a":"\\uDC00"}|) == :error
    assert JSON.decode(~s|{"a":"\\uD800\\uD800"}|) == :error
    assert JSON.decode("{,}") == :error
    assert JSON.decode(~s|{"a":1,}|) == :error
    assert JSON.decode("[1,]") == :error
    assert JSON.decode("[]") == {:ok, []}
    assert JSON.decode(~s|{"a":1e309}|) == {:ok, {:object, [{"a", :non_finite}]}}
    assert JSON.decode(~s|{"a":-1e309}|) == {:ok, {:object, [{"a", :non_finite}]}}
  end

  test "resolves exact names, prefixes, blocks, and ignored entries" do
    map =
      map(~s|{
        "integrity": {"vue": "sha256-abc"},
        "imports": {
          "vue": "./vue.js",
          "react": "http://cdn.test/react.js",
          "/js/lib.js": "/mapped.js",
          "blocked": null,
          "gone": "data:text/javascript,1",
          "": "/empty.js",
          "bad": 1,
          "lib/": "/lib/",
          "lib/extra/": "/extra/",
          "lib/a.js": "/exact-a.js",
          "pre/": "/not-dir"
        }
      }|)

    assert resolve("vue", map, @base) == {:ok, "http://example.com/assets/vue.js"}
    assert resolve("react", map, @base) == {:ok, "http://cdn.test/react.js"}
    assert resolve("/js/lib.js", map, @base) == {:ok, "http://example.com/mapped.js"}
    assert resolve("blocked", map, @base) == :blocked
    assert resolve("gone", map, @base) == :blocked
    assert resolve("lodash", map, @base) == :unmapped
    assert resolve("lib", map, @base) == :unmapped
    assert resolve("lib/a.js", map, @base) == {:ok, "http://example.com/exact-a.js"}
    assert resolve("lib/b.js", map, @base) == {:ok, "http://example.com/lib/b.js"}
    assert resolve("lib/extra/b.js", map, @base) == {:ok, "http://example.com/extra/b.js"}
    assert resolve("lib/../secret.js", map, @base) == :blocked
    assert resolve("pre/a.js", map, @base) == :unmapped
    assert resolve("./app.js", map, @base) == {:ok, "http://example.com/assets/app.js"}
  end

  test "matches one absolute key for the same address and keeps a rebased relative URL" do
    map = map(~s|{"imports":{"/js/lib.js":"/mapped.js"}}|, @page)

    for spec <- ["/js/lib.js", "./js/lib.js", "./foo/../js/lib.js"] do
      assert resolve(spec, map, @page) == {:ok, "http://example.com/mapped.js"}
    end

    rebased = map(~s|{"imports":{"/js/lib.js":"/mapped.js"}}|)
    assert resolve("/js/lib.js", rebased, @base) == {:ok, "http://example.com/mapped.js"}

    assert resolve("./foo/../js/lib.js", rebased, @base) ==
             {:ok, "http://example.com/assets/js/lib.js"}
  end

  test "uses the longest matching scope and falls through a missing name" do
    map =
      map(~s|{
        "imports": {"vue": "./vue.js", "react": "/react.js"},
        "scopes": {
          "/js": {"vue": "/exact-scope.js"},
          "/js/": {"vue": "./js-vue.js", "react": null},
          "/js/app/": {"vue": "/js/app/vue.js"},
          "/bad": "nope"
        }
      }|)

    assert resolve("vue", map, "http://example.com/js/app/main.js") ==
             {:ok, "http://example.com/js/app/vue.js"}

    assert resolve("vue", map, "http://example.com/js/other.js") ==
             {:ok, "http://example.com/assets/js-vue.js"}

    assert resolve("react", map, "http://example.com/js/other.js") == :blocked

    assert resolve("vue", map, "http://example.com/js") ==
             {:ok, "http://example.com/exact-scope.js"}

    assert resolve("vue", map, "http://example.com/other.js") ==
             {:ok, "http://example.com/assets/vue.js"}

    assert resolve("react", map, "http://example.com/other.js") ==
             {:ok, "http://example.com/react.js"}
  end

  test "keeps an earlier address, including null, and adds a new name" do
    first =
      map(~s|{"imports":{"a":"/a1.js","blocked":null},"scopes":{"/js/":{"a":"/scope-a.js"}}}|)

    second =
      map(
        ~s|{"imports":{"a":"/a2.js","blocked":"/blocked.js","b":"/b.js"},"scopes":{"/js/":{"a":"/scope-b.js","c":"/c.js"}}}|
      )

    merged = ImportMap.merge(second, first)

    assert resolve("a", merged, @page) == {:ok, "http://example.com/a1.js"}
    assert resolve("blocked", merged, @page) == :blocked
    assert resolve("b", merged, @page) == {:ok, "http://example.com/b.js"}

    assert resolve("a", merged, "http://example.com/js/app.js") ==
             {:ok, "http://example.com/scope-a.js"}

    assert resolve("c", merged, "http://example.com/js/app.js") ==
             {:ok, "http://example.com/c.js"}
  end

  test "ignores an invalid map and a bad scope without dropping earlier entries" do
    first = map(~s|{"imports":{"a":"/a1.js"}}|)

    assert ImportMap.merge_source("{not json", first, @base) == first
    assert ImportMap.merge_source("[]", first, @base) == first
    assert ImportMap.merge_source(~s|{"imports":[]} |, first, @base) == first
    assert ImportMap.merge_source(~s|{"scopes":[]} |, first, @base) == first

    assert ImportMap.merge_source(
             ~s|{"imports":null,"scopes":{"/js/":{"vue":"/vue.js"}}}|,
             first,
             @base
           ) ==
             first

    assert ImportMap.merge_source(~s|{"imports":false} |, first, @base) == first

    assert ImportMap.merge_source(~s|{"scopes":null,"imports":{"b":"/b.js"}}|, first, @base) ==
             first

    assert ImportMap.merge_source(~s|{"scopes":false} |, first, @base) == first
    assert ImportMap.merge_source(~s|{"imports":1e309} |, first, @base) == first

    overflow =
      ImportMap.merge_source(~s|{"imports":{"b":1e309,"c":"/c.js"}}|, first, @page)

    assert resolve("b", overflow, @page) == :unmapped
    assert resolve("c", overflow, @page) == {:ok, "http://example.com/c.js"}

    merged =
      ImportMap.merge_source(
        ~s|{"imports":{"b":"/b.js"},"scopes":{"/js/":"nope","/ok/":{"b":"/ok.js"}}}|,
        first,
        @page
      )

    assert resolve("a", merged, @page) == {:ok, "http://example.com/a1.js"}
    assert resolve("b", merged, @page) == {:ok, "http://example.com/b.js"}

    assert resolve("b", merged, "http://example.com/ok/app.js") ==
             {:ok, "http://example.com/ok.js"}

    assert resolve("b", merged, "http://example.com/js/app.js") ==
             {:ok, "http://example.com/b.js"}
  end

  test "ignores a prefix whose resolved address does not end with /" do
    map =
      map(~s|{"imports":{
        "http://example.com/lib/":"http://example.com/lib/?v=1",
        "http://example.com/":"http://example.com/root/"
      }}|)

    assert resolve("http://example.com/lib/a.js", map, "http://example.com/js/app.js") ==
             {:ok, "http://example.com/root/lib/a.js"}

    queried = map(~s|{"imports":{"/lib/":"/lib/?v=1"}}|)

    assert resolve("/lib/.", queried, "http://example.com/js/app.js") ==
             {:ok, "http://example.com/lib/"}

    assert resolve("pkg/a.js", map(~s|{"imports":{"pkg/":"/pkg/?v=1"}}|), @base) == :unmapped

    assert resolve("ok/a.js", map(~s|{"imports":{"ok/":"/ok/"}}|), @base) ==
             {:ok, "http://example.com/ok/a.js"}

    assert resolve("lib/a.js", map(~s|{"imports":{"lib/":"/lib/#x"}}|), @base) ==
             {:ok, "http://example.com/lib/a.js"}

    scoped =
      map(~s|{"imports":{"lib/":"/top/"},"scopes":{"/js/":{"lib/":"/lib/?v=1"}}}|)

    assert resolve("lib/a.js", scoped, "http://example.com/js/app.js") ==
             {:ok, "http://example.com/top/a.js"}
  end

  test "ignores a non-http prefix that does not end with /" do
    map =
      map(~s|{"imports":{
        "/lib/":"data:text/javascript,1",
        "/blob/":"blob:http://example.com/id",
        "gone":"data:text/javascript,export {}",
        "/keep/":"data:text/javascript,1/"
      }}|)

    assert resolve("/lib/a.js", map, "http://example.com/js/app.js") ==
             {:ok, "http://example.com/lib/a.js"}

    assert resolve("/blob/a.js", map, "http://example.com/js/app.js") ==
             {:ok, "http://example.com/blob/a.js"}

    assert resolve("gone", map, @base) == :blocked
    assert resolve("/keep/a.js", map, "http://example.com/js/app.js") == :blocked

    scoped =
      map(
        ~s|{"imports":{"lib/":"/top/","/lib/":"/root/"},"scopes":{"/js/":{"lib/":"data:text/javascript,1"}}}|
      )

    assert resolve("lib/a.js", scoped, "http://example.com/js/app.js") ==
             {:ok, "http://example.com/top/a.js"}

    assert resolve("/lib/a.js", scoped, "http://example.com/js/app.js") ==
             {:ok, "http://example.com/root/a.js"}

    merged =
      ImportMap.merge(
        map(~s|{"imports":{"lib/":"/lib/"}}|),
        map(~s|{"imports":{"lib/":"data:text/javascript,1"}}|)
      )

    assert resolve("lib/a.js", merged, @base) == {:ok, "http://example.com/lib/a.js"}
  end

  defp map(text, base \\ @base) do
    parsed = ImportMap.parse(text, base)
    assert %{imports: _imports, scopes: _scopes} = parsed
    parsed
  end

  defp resolve(specifier, map, base), do: ImportMap.resolve(specifier, map, base)
end
