defmodule Crawler.Parser.CssParser.ImportRulesTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser
  alias Crawler.Parser.CssParser
  alias Crawler.Parser.CssSheets

  test "an import counts only in the stylesheet prelude" do
    css = """
    @charset "utf-8";
    @layer reset, theme;
    @import "reset.css" layer(reset);
    @import "theme.css" layer(theme) supports(display: grid);
    @import "print.css" print;
    @layer components;
    @import "components.css";
    @namespace url("http://www.w3.org/2000/svg");
    @import "after-namespace.css";
    body { background: url("shown.png"); }
    @import "after-rule.css";
    """

    assert values(css) == [
             {"reset.css", :import},
             {"theme.css", :import},
             {"print.css", :import},
             {"shown.png", :url}
           ]
  end

  test "a nested import is ignored and a picture in that rule still loads" do
    css = """
    @import "ok.css" screen;
    @media screen {
      @import "no-media.css";
      body { background: url("shown.png"); }
    }
    @supports (display: grid) {
      @import "no-supports.css";
    }
    @supports (background: url("idle.png")) {
      p { background: url("yes.png"); }
    }
    @layer base {
      @import "no-layer.css";
    }
    @container (min-width: 10px) {
      @import "no-container.css";
      section { background: url("boxed.png"); }
    }
    div {
      @import "no-nested.css";
      background: url("inner.png");
    }
    """

    assert values(css) == [
             {"ok.css", :import},
             {"shown.png", :url},
             {"yes.png", :url},
             {"boxed.png", :url},
             {"inner.png", :url}
           ]
  end

  test "a broken import loads nothing, including a picture in its block" do
    css = """
    @import "one.css" url("two.css");
    @import "idle.css" "extra.css";
    @import "idle-layer.css" layer(one) layer(two);
    @import "idle-supports.css" supports();
    @import "blocked.css" {
      body { background: url("inner.png"); }
    }
    @import "ok.css" layer supports(display: grid) screen;
    @import "typed.css" supports(background: url("test.png"));
    @import "late.css" supports(display: grid) layer;
    @import "negative.css" supports(not (display: block));
    """

    assert values(css) == [
             {"ok.css", :import},
             {"typed.css", :import},
             {"negative.css", :import}
           ]
  end

  test "an unknown statement keeps later imports and its block does not" do
    assert values(~s|@import "before.css"; @foo; @import "after.css";|) == [
             {"before.css", :import},
             {"after.css", :import}
           ]

    assert values(~s|@import "before.css"; @foo { } @import "after.css";|) == [
             {"before.css", :import}
           ]
  end

  test "a block at-rule needs a block before it ends the prelude" do
    for rule <- [
          "@media screen;",
          "@supports (display: grid);",
          "@keyframes a;",
          "@page;",
          "@font-face;",
          "@property --x;"
        ] do
      assert values(rule <> ~s| @import "a.css";|) == [{"a.css", :import}]
    end

    assert values(~s|@media screen {} @import "no.css";|) == []
    assert values(~s|@import "a.css"; @layer x; @import "no.css";|) == [{"a.css", :import}]
    assert values(~s|@layer reset; @import "a.css";|) == [{"a.css", :import}]

    assert values(~s|@supports-condition { color: red; } @import "a.css";|) == [
             {"a.css", :import}
           ]
  end

  test "a truncated import at the top still counts" do
    assert values(~s|@import "theme.css|) == [{"theme.css", :import}]
    assert values("@import url(theme.css") == [{"theme.css", :import}]
  end

  test "a custom property loads a picture only where an image value uses it" do
    css = """
    :root {
      --idle: url("idle.png");
      --bg: url("shown.png");
      --file: url("file.png");
      --alias: var(--file);
      --face: url("idle.woff2");
    }
    body { background: var(--bg); color: var(--idle); }
    p { background: var(--alias); }
    div { background: var(--missing, url("fallback.png")); }
    section { background: var(--bg, url("other.png")); }
    @font-face { font-family: Direct; src: url("shown.woff2") format("woff2"); }
    @font-face { font-family: Indirect; src: var(--face); }
    """

    assert values(css) == [
             {"shown.png", :url},
             {"file.png", :url},
             {"fallback.png", :url},
             {"shown.woff2", :font}
           ]
  end

  test "an unregistered picture uses the sheet that reads the variable" do
    scope = System.unique_integer([:positive])
    on_exit(fn -> Crawler.Store.dispose_scope(scope) end)
    group = "http://example.com/start"

    app = """
    @import "/tokens/tokens.css";
    html { background: var(--plain); }
    body { background: var(--icon); }
    """

    tokens = """
    @property --icon {
      syntax: "<url>";
      inherits: true;
      initial-value: url("initial.png");
    }
    :root { --icon: url("shown.png"); --plain: url("plain.png"); --idle: url("idle.png"); }
    """

    app_url = "http://example.com/css/app.css"
    tokens_url = "http://example.com/tokens/tokens.css"

    assert links(app, scope, group, app_url) == [
             {"/tokens/tokens.css", "http://example.com/tokens/tokens.css"}
           ]

    assert links(tokens, scope, group, tokens_url) == [
             {"shown.png", "http://example.com/tokens/shown.png"},
             {"http://example.com/css/plain.png", "http://example.com/css/plain.png"}
           ]
  end

  test "a media-query list keeps its import" do
    assert values(~s|@import "print.css" screen, print;|) == [{"print.css", :import}]
    assert values(~s|@import "ok.css" layer(base), print;|) == [{"ok.css", :import}]
    assert values(~s|@import "a.css", "b.css";|) == []
    assert values(~s|@import "idle.css" layer(one, two);|) == []
  end

  test "the last property descriptor wins" do
    color = """
    @property --icon { syntax: "<url>"; syntax: "<color>"; initial-value: url("a.png"); }
    body { background: var(--icon); }
    """

    assert values(color) == []

    url = """
    @property --icon {
      syntax: "<color>";
      syntax: "<url>";
      initial-value: url("a.png");
      initial-value: url("b.png");
    }
    body { background: var(--icon); }
    """

    assert values(url) == [{"b.png", :url}]
  end

  test "a later page and a srcdoc keep their own style groups" do
    scope = System.unique_integer([:positive])
    on_exit(fn -> Crawler.Store.dispose_scope(scope) end)
    page = "http://example.com/a.html"

    html = """
    <style>:root { --from-a: url("from-a.png"); }</style>
    <link rel="stylesheet" href="app.css">
    <a href="b.html">b</a>
    <iframe srcdoc="<style>body { background: var(--from-a); }</style>"></iframe>
    """

    opts = %{
      scope: scope,
      generation: Crawler.Store.generation(scope),
      url: page,
      referrer_url: page,
      content_type: "text/html",
      html_tag: "a",
      assets: ["css", "images"]
    }

    found = links_with_opts(html, opts)
    sheet = opt_for(found, "app.css")
    other = opt_for(found, "b.html")

    assert sheet.style_group == page
    assert other[:style_group] == nil
    refute Enum.any?(url_values(found), &String.ends_with?(&1, "from-a.png"))

    app_url = "http://example.com/app.css"

    app_opts =
      sheet
      |> Map.put(:url, app_url)
      |> Map.put(:referrer_url, app_url)
      |> Map.put(:content_type, "text/css")

    assert Enum.any?(
             fetched_urls("html { background: var(--from-a); }", app_opts),
             &String.ends_with?(&1, "/from-a.png")
           )

    other_url = "http://example.com/b.html"

    other_opts =
      other
      |> Map.put(:url, other_url)
      |> Map.put(:referrer_url, other_url)
      |> Map.put(:content_type, "text/html")

    refute Enum.any?(
             fetched_urls("<style>body { background: var(--from-a); }</style>", other_opts),
             &String.ends_with?(&1, "from-a.png")
           )
  end

  test "a fragment or bad import url occupies the address" do
    assert values(~s|@import url(#foo) url(real.css);|) == []
    assert values(~s|@import url(foo bar) url(real.css);|) == []
    assert values(~s|@import url(#foo); @layer x; @import "a.css";|) == []
    assert values(~s|@import "#bar"; @layer x; @import "a.css";|) == []
    assert values(~s|@import url(foo bar); @import "ok.css";|) == [{"ok.css", :import}]
    assert values(~s|@import url(#foo) url(real.css); @import "ok.css";|) == [{"ok.css", :import}]

    assert values(~s|@import url(#foo) url(paint.png)|, mode: :declarations) == [
             {"paint.png", :url}
           ]

    assert values(~s|@import url(foo bar) url(paint.png)|, mode: :declarations) == [
             {"paint.png", :url}
           ]
  end

  test "an empty layer clause is not an import" do
    assert values(~s|@import "a.css" layer();|) == []
    assert values(~s|@import "a.css" layer( );|) == []
    assert values(~s|@import "idle.css" layer(); @import "ok.css";|) == [{"ok.css", :import}]
    assert values(~s|@import "a.css" layer;|) == [{"a.css", :import}]
    assert values(~s|@import "a.css" layer(base);|) == [{"a.css", :import}]

    assert values(~s|@import "ok.css" layer(a.b); @layer x; @import "no.css";|) == [
             {"ok.css", :import}
           ]

    assert values(~s|@import "ok.css" layer(a.b.c);|) == [{"ok.css", :import}]

    for css <- [
          ~s|@import "no.css" layer(a b); @layer x; @import "yes.css";|,
          ~s|@import "no.css" layer(foo(bar)); @layer x; @import "yes.css";|,
          ~s|@import "no.css" layer(1px); @layer x; @import "yes.css";|,
          ~s|@import "no.css" layer(a..b); @layer x; @import "yes.css";|,
          ~s|@import "no.css" layer(.a); @layer x; @import "yes.css";|,
          ~s|@import "no.css" layer(a.); @layer x; @import "yes.css";|,
          ~s|@import "no.css" layer((a)); @layer x; @import "yes.css";|,
          ~s|@import "no.css" layer((a.b)); @layer x; @import "yes.css";|,
          ~s|@import "no.css" layer(a.(b)); @import "yes.css";|
        ] do
      assert values(css) == [{"yes.css", :import}]
    end

    assert values(~s|@import "ok.css" supports((display: grid));|) == [{"ok.css", :import}]
  end

  test "an alias uses a registered initial value" do
    css = """
    @property --b { syntax: "<url>"; inherits: true; initial-value: url("initial.png"); }
    :root { --a: var(--b); }
    body { background: var(--a); }
    """

    assert values(css) == [{"initial.png", :url}]

    chain = """
    @property --c { syntax: "<url>"; inherits: true; initial-value: url("initial.png"); }
    :root { --a: var(--b); --b: var(--c); }
    body { background: var(--a); }
    """

    assert values(chain) == [{"initial.png", :url}]

    guarded = """
    @property --b { syntax: "<url>"; inherits: true; initial-value: url("initial.png"); }
    :root { --a: var(--b, url("fallback.png")); }
    body { background: var(--a); }
    """

    assert values(guarded) == [{"initial.png", :url}]

    several = """
    :root {
      --a: var(--color), var(--icon);
      --color: red;
      --icon: url("icon.png");
      --pair: var(--b), var(--c);
      --b: url("b.png");
      --c: url("c.png");
      --open: var(--missing, url("a.png")), var(--also, url("b.png"));
      --mixed: url("own.png"), var(--c);
    }
    body { background: var(--a); }
    p { background: var(--pair); }
    div { background: var(--open); }
    section { background: var(--mixed); }
    """

    assert values(several) == [
             {"icon.png", :url},
             {"b.png", :url},
             {"c.png", :url},
             {"a.png", :url},
             {"b.png", :url},
             {"own.png", :url}
           ]
  end

  test "a var fallback loads only when the variable is unset" do
    css = """
    :root {
      --bg: url("shown.png");
      --b: url("b.png");
      --alias: var(--b, image-set("hidden.png" 1x));
    }
    body { background: var(--bg, image-set("other.png" 1x)); }
    p { background: var(--gone, image-set("fallback.png" 1x, "also.png" 2x)); }
    div { background: var(--gone, image(url("boxed.png"))); }
    section { background: var(--gone, cross-fade(url("fade.png"), url("fade-b.png"))); }
    article { background: var(--a, var(--b)); }
    aside { background: var(--a, var(--b, url("no.png"))); }
    figure { background: var(--missing, var(--also, url("nested.png"))); }
    h1 { background: var(--alias); }
    """

    assert values(css) == [
             {"shown.png", :url},
             {"b.png", :url},
             {"fallback.png", :url},
             {"also.png", :url},
             {"boxed.png", :url},
             {"fade.png", :url},
             {"fade-b.png", :url},
             {"nested.png", :url}
           ]
  end

  test "the declaration on the using rule wins" do
    same_rule = """
    .other { --bg: url("other.png"); }
    .icon { background: var(--bg); --bg: url("shown.png"); }
    .later { --bg: url("later.png"); }
    """

    assert values(same_rule) == [{"shown.png", :url}]

    later_rule = """
    .other { --bg: url("other.png"); }
    .icon { background: var(--bg); }
    .later { --bg: url("later.png"); }
    """

    assert values(later_rule) == [{"later.png", :url}]

    nested = """
    .icon {
      --bg: url("shown.png");
      background: var(--bg);
      .inner { --bg: url("other.png"); background: var(--bg); }
    }
    """

    assert values(nested) == [{"shown.png", :url}, {"other.png", :url}]

    aliased = """
    .icon { --a: var(--b); background: var(--a); --b: url("shown.png"); }
    .later { --b: url("later.png"); }
    """

    assert values(aliased) == [{"shown.png", :url}]

    after_nested = """
    .card {
      --bg: url("card.png");
      .title { --bg: url("title.png"); }
      background: var(--bg);
    }
    """

    assert values(after_nested) == [{"card.png", :url}]

    after_media = """
    .card {
      background: var(--bg);
      @media (min-width: 600px) {
        .title { color: red; }
      }
      --bg: url("card.png");
    }
    .other { --bg: url("other.png"); }
    """

    assert values(after_media) == [{"card.png", :url}]
  end

  test "a fallback waits until the imported sheet joins" do
    scope = System.unique_integer([:positive])
    on_exit(fn -> Crawler.Store.dispose_scope(scope) end)
    group = "http://example.com/start"
    app_url = "http://example.com/css/app.css"
    tokens_url = "http://example.com/tokens/tokens.css"

    parent = """
    @import "/tokens/tokens.css";
    body { background: url("direct.png"), var(--bg, url("fallback.png")); }
    """

    assert links(parent, scope, group, app_url) == [
             {"/tokens/tokens.css", tokens_url},
             {"direct.png", "http://example.com/css/direct.png"}
           ]

    shown = """
    :root { --bg: url("shown.png"); }
    """

    assert links(shown, scope, group, tokens_url) == [
             {"http://example.com/css/shown.png", "http://example.com/css/shown.png"}
           ]

    alias_scope = System.unique_integer([:positive])
    on_exit(fn -> Crawler.Store.dispose_scope(alias_scope) end)

    alias_parent = """
    @import "/tokens/tokens.css";
    :root { --bg: var(--icon, url("fallback.png")); }
    body { background: var(--bg); }
    """

    assert links(alias_parent, alias_scope, group, app_url) == [
             {"/tokens/tokens.css", tokens_url}
           ]

    alias_tokens = """
    :root { --icon: url("shown.png"); }
    """

    assert links(alias_tokens, alias_scope, group, tokens_url) == [
             {"http://example.com/css/shown.png", "http://example.com/css/shown.png"}
           ]
  end

  test "an import that leaves the variable unset still loads the fallback" do
    scope = System.unique_integer([:positive])
    on_exit(fn -> Crawler.Store.dispose_scope(scope) end)
    group = "http://example.com/start"
    app_url = "http://example.com/css/app.css"
    tokens_url = "http://example.com/tokens/tokens.css"

    parent = """
    @import "/tokens/tokens.css";
    body { background: var(--bg, url("fallback.png")); }
    """

    assert links(parent, scope, group, app_url) == [
             {"/tokens/tokens.css", tokens_url}
           ]

    other = """
    body { background: url("direct.png"); }
    """

    assert links(other, scope, group, tokens_url) == [
             {"direct.png", "http://example.com/tokens/direct.png"},
             {"http://example.com/css/fallback.png", "http://example.com/css/fallback.png"}
           ]
  end

  test "a missing import still loads the fallback" do
    scope = System.unique_integer([:positive])
    on_exit(fn -> Crawler.Store.dispose_scope(scope) end)
    group = "http://example.com/start"
    app_url = "http://example.com/css/app.css"
    tokens_url = "http://example.com/tokens/tokens.css"

    parent = """
    @import "/tokens/tokens.css";
    body { background: var(--bg, url("fallback.png")); }
    """

    assert links(parent, scope, group, app_url) == [
             {"/tokens/tokens.css", tokens_url}
           ]

    assert CssSheets.settle(%{
             scope: scope,
             generation: Crawler.Store.generation(scope),
             url: tokens_url
           }) == [
             "http://example.com/css/fallback.png"
           ]

    initial_scope = System.unique_integer([:positive])
    on_exit(fn -> Crawler.Store.dispose_scope(initial_scope) end)

    initial = """
    @import "/tokens/tokens.css";
    @property --bg { syntax: "<url>"; inherits: true; initial-value: url("initial.png"); }
    body { background: var(--bg); }
    """

    assert links(initial, initial_scope, group, app_url) == [
             {"/tokens/tokens.css", tokens_url}
           ]

    assert CssSheets.settle(%{
             scope: initial_scope,
             generation: Crawler.Store.generation(initial_scope),
             url: tokens_url
           }) == [
             "http://example.com/css/initial.png"
           ]
  end

  test "a later sheet does not wait on an import that already failed" do
    scope = System.unique_integer([:positive])
    on_exit(fn -> Crawler.Store.dispose_scope(scope) end)
    group = "http://example.com/start"
    app_url = "http://example.com/css/app.css"
    missing = "http://example.com/css/missing.css"
    later_url = "http://example.com/css/later.css"

    parent = """
    @import "missing.css";
    @import "later.css";
    body { background: var(--bg, url("fallback.png")); }
    """

    assert links(parent, scope, group, app_url) == [
             {"missing.css", missing},
             {"later.css", later_url}
           ]

    assert CssSheets.settle(%{
             scope: scope,
             generation: Crawler.Store.generation(scope),
             url: missing
           }) == []

    later = """
    @import "missing.css";
    body { background: url("direct.png"); }
    """

    assert links(later, scope, group, later_url) == [
             {"missing.css", missing},
             {"direct.png", "http://example.com/css/direct.png"},
             {"http://example.com/css/fallback.png", "http://example.com/css/fallback.png"}
           ]

    other = "http://example.com/other"
    again_url = "http://example.com/css/again.css"

    again = """
    @import "missing.css";
    body { background: var(--bg, url("again.png")); }
    """

    assert links(again, scope, other, again_url) == [
             {"missing.css", "http://example.com/css/missing.css"},
             {"again.png", "http://example.com/css/again.png"}
           ]
  end

  test "a redirected import stays joined for a later sheet in that group" do
    scope = System.unique_integer([:positive])
    on_exit(fn -> Crawler.Store.dispose_scope(scope) end)
    group = "http://example.com/start"
    app_url = "http://example.com/css/app.css"
    request = "http://example.com/css/b.css"
    landed = "http://example.com/css/b-final.css"
    later_url = "http://example.com/css/later.css"

    app = """
    @import "b.css";
    @import "later.css";
    body { background: var(--missing, url("fallback.png")); }
    """

    assert links(app, scope, group, app_url) == [
             {"b.css", request},
             {"later.css", later_url}
           ]

    assert sheet_links("body { color: red; }", scope, group, request, landed) == []

    later = """
    @import "b.css";
    body { background: url("direct.png"); }
    """

    assert links(later, scope, group, later_url) == [
             {"b.css", request},
             {"direct.png", "http://example.com/css/direct.png"},
             {"http://example.com/css/fallback.png", "http://example.com/css/fallback.png"}
           ]

    other = "http://example.com/other"

    waiting = """
    @import "b.css";
    body { background: var(--missing, url("other.png")); }
    """

    assert links(waiting, scope, other, later_url) == [
             {"b.css", request}
           ]
  end

  test "a style attribute is not a stylesheet" do
    assert values(~s|@import 'idle.css'; background: url('shown.png')|, mode: :declarations) == [
             {"shown.png", :url}
           ]

    assert values(~s|@import url('idle.css') url(paint.png)|, mode: :declarations) == [
             {"paint.png", :url}
           ]

    assert values(~s|@import 'idle.css'|, mode: :declarations) == []

    assert values(
             ~s|@import "x.css" supports(background: url("idle.png"));|,
             mode: :declarations
           ) == []

    assert values(
             ~s|@import "x.css" { background: url("inner.png"); }|,
             mode: :declarations
           ) == []

    assert values(
             ~s|@import "x.css" supports(display: grid) url(paint.png)|,
             mode: :declarations
           ) == [{"paint.png", :url}]

    assert values(
             ~s|.a { background: var(--bg); --bg: url("a.png"); } .b { --bg: url("b.png"); }|,
             mode: :declarations
           ) == [{"b.png", :url}]
  end

  defp values(css, opts \\ []) do
    css
    |> CssParser.spans(opts)
    |> Enum.map(&{&1.value, &1.kind})
  end

  defp links_with_opts(body, opts) do
    body
    |> Parser.parse_links(opts, fn element, link_opts -> {element, link_opts} end)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp opt_for(found, name) do
    {_element, opts} =
      Enum.find(found, fn {element, _opts} ->
        element |> Tuple.to_list() |> Enum.any?(&(is_binary(&1) and String.ends_with?(&1, name)))
      end)

    opts
  end

  defp url_values(found) do
    Enum.map(found, fn {element, _opts} -> element |> Tuple.to_list() |> List.last() end)
  end

  defp fetched_urls(body, opts) do
    body |> links_with_opts(opts) |> url_values()
  end

  defp links(body, scope, group, url), do: sheet_links(body, scope, group, url, url)

  defp sheet_links(body, scope, group, url, referrer) do
    opts = %{
      scope: scope,
      generation: Crawler.Store.generation(scope),
      url: url,
      referrer_url: referrer,
      style_group: group,
      content_type: "text/css",
      html_tag: "link",
      assets: ["css", "images"]
    }

    body
    |> Parser.parse_links(opts, fn
      {_, raw, _, absolute}, _link_opts -> {raw, absolute}
      {_, absolute}, _link_opts -> {absolute, absolute}
    end)
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end
end
