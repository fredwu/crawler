defmodule Crawler.LinkerTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis
  alias Crawler.Linker

  doctest Linker

  test "bound fragments use sanitized URL input and preserve existing escapes" do
    page = "http://example.com/blog/post"
    opts = %{url: page, content_type: "text/html", assets: []}

    for {fragment, expected} <- [
          {"x\ny", "xy"},
          {"x\ry", "xy"},
          {"x\ty", "xy"},
          {"xy\0\x1F ", "xy"},
          {"x%0Ay%0D%09%00%2F", "x%0Ay%0D%09%00%2F"},
          {"x%ZZ", "x%25ZZ"}
        ] do
      source = ~s|<a href="next##{fragment}">next</a>|
      assert {:ok, analysis} = Analysis.analyze(source, opts)
      assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)

      assert [
               %{
                 source_mode: :html,
                 source_role: :attribute,
                 value: value,
                 url: "http://example.com/blog/next",
                 fragment: ^expected,
                 context: %{html_tag: "a"}
               }
             ] = collection.occurrences

      assert value == "next#" <> fragment

      assert {:ok, bound} =
               Analysis.bind(collection, fn _ref ->
                 %{fixture: :next, path: "fixtures/next.html"}
               end)

      assert {:ok, rendered} =
               Analysis.render(analysis, bound, fn ref -> {:local, ref.target.path} end)

      assert rendered == ~s|<a href="fixtures/next.html##{expected}">next</a>|
    end
  end
end
