defmodule Crawler.Parser.CssParser.BadUrlTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.CssParser
  alias Crawler.Snapper.LinkReplacer.Css

  test "invalid unquoted URL values stay opaque and preserve their original bytes" do
    values =
      [~S|foo(bar.png|, ~S|foo"bar.png|, ~S|foo'bar.png|, "foo bar.png"] ++
        Enum.map([0, 8, 11, 14, 31, 127], &"foo#{<<&1>>}bar.png") ++
        Enum.map(["\n", "\r\n", "\f"], &"foo\\#{&1}bar.png")

    for value <- values do
      invalid = "url(#{value})"
      source = invalid <> ";background:url(real.png)"

      assert resources(source) == ["real.png"]
      assert Css.replace(source, value, "offline.png", entity_quotes: false) == source

      assert Css.replace(source, "real.png", "saved.png", entity_quotes: false) ==
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

      assert Css.replace(source, "real.png", "saved.png", entity_quotes: false) ==
               invalid <> ";background:url(saved.png)"
    end

    unfinished = ~S|url(foo"bar.png \) @import 'hidden.css'; url(hidden.png|
    assert resources(unfinished) == []
    assert Css.replace(unfinished, "hidden.png", "saved.png", entity_quotes: false) == unfinished
  end

  test "quoted values and escaped punctuation remain valid URL resources" do
    source = ~S|url("foo(bar.png"),url(foo\(bar.png),url(foo\"bar.png),url(foo\)bar.png)|

    assert resources(source) == ["foo(bar.png", "foo(bar.png", "foo\"bar.png", "foo)bar.png"]

    assert Css.replace(source, "foo(bar.png", "saved.png", entity_quotes: false) ==
             ~S|url("saved.png"),url(saved.png),url(foo\"bar.png),url(foo\)bar.png)|
  end

  test "entity-decoded bad URLs preserve source bytes before a valid quoted value" do
    source = ~S|url(foo&quot;bar.png),url(&quot;real.png&quot;)|

    assert Enum.map(CssParser.spans(source, entity_quotes: true), & &1.value) == ["real.png"]
    assert Css.replace(source, "foo\"bar.png", "saved.png") == source

    assert Css.replace(source, "real.png", "saved.png") ==
             ~S|url(foo&quot;bar.png),url(&quot;saved.png&quot;)|
  end

  defp resources(source), do: Enum.map(CssParser.spans(source), & &1.value)
end
