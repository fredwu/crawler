defmodule Crawler.Parser.CssParser.BadUrlTest do
  use ExUnit.Case, async: true

  alias Crawler.Analysis
  alias Crawler.Parser.CssParser

  test "invalid unquoted URL values stay opaque and preserve their original bytes" do
    values =
      [~S|foo(bar.png|, ~S|foo"bar.png|, ~S|foo'bar.png|, "foo bar.png"] ++
        Enum.map([0, 8, 11, 14, 31, 127], &"foo#{<<&1>>}bar.png") ++
        Enum.map(["\n", "\r\n", "\f"], &"foo\\#{&1}bar.png")

    for value <- values do
      invalid = "url(#{value})"
      source = invalid <> ";background:url(real.png)"

      assert resources(source) == ["real.png"]
      assert render_css(source, value, "offline.png") == source

      assert render_css(source, "real.png", "saved.png") ==
               invalid <> ";background:url(saved.png)"
    end
  end

  test "bad URL recovery ignores escaped closing parentheses and URL-like remnants" do
    for escaped_close <- [~S|\)|, ~S|\29 |] do
      invalid =
        ~S|url(foo"bar.png | <>
          escaped_close <>
          ~S| @import 'hidden.css'; url(hidden.png))|

      source = invalid <> ";background:url(real.png)"
      assert resources(source) == ["real.png"]

      assert render_css(source, "real.png", "saved.png") ==
               invalid <> ";background:url(saved.png)"
    end

    unfinished = ~S|url(foo"bar.png \) @import 'hidden.css'; url(hidden.png|
    assert resources(unfinished) == []
    assert render_css(unfinished, "hidden.png", "saved.png") == unfinished
  end

  test "quoted values and escaped punctuation remain valid URL resources" do
    source = ~S|url("foo(bar.png"),url(foo\(bar.png),url(foo\"bar.png),url(foo\)bar.png)|

    assert resources(source) == ["foo(bar.png", "foo(bar.png", "foo\"bar.png", "foo)bar.png"]

    assert render_css(source, "foo(bar.png", "saved.png") ==
             ~S|url("saved.png"),url(saved.png),url(foo\"bar.png),url(foo\)bar.png)|
  end

  test "entity-decoded bad URLs preserve source bytes before a valid quoted value" do
    source = ~S|url(foo&quot;bar.png),url(&quot;real.png&quot;)|

    assert Enum.map(CssParser.spans(source, entity_quotes: true), & &1.value) == ["real.png"]

    assert render_css(attribute(source), "foo\"bar.png", "saved.png", "text/html") ==
             attribute(source)

    assert render_css(attribute(source), "real.png", "saved.png", "text/html") ==
             attribute(~S|url(foo&quot;bar.png),url(&quot;saved.png&quot;)|)
  end

  defp resources(source), do: Enum.map(CssParser.spans(source), & &1.value)

  defp attribute(source), do: ~s|<div style="#{source}"></div>|

  defp render_css(source, value, path, type \\ "text/css") do
    opts = %{
      url: "https://example.test/styles/main.css",
      content_type: type,
      assets: ["css", "images"]
    }

    assert {:ok, analysis} = Analysis.analyze(source, opts)
    assert {:ok, collection} = Analysis.occurrences_result(analysis, opts)

    assert {:ok, bound} =
             Analysis.bind(collection, fn ref ->
               if ref.source_role == :css and ref.context.html_tag == "link" and
                    ref.value == value,
                  do: %{fixture: :css_resource, path: path}
             end)

    assert {:ok, rendered} =
             Analysis.render(analysis, bound, fn
               %{target: %{fixture: :css_resource, path: path}} -> {:local, path}
               _ref -> :keep
             end)

    rendered
  end
end
