defmodule Crawler.Parser.CssCommentsTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.CssParser
  alias Crawler.Parser.CssParser.Scanner

  test "ignores URL, import, and image-set syntax in comments" do
    source = """
    /* url("hidden.png"); @import "hidden.css"; image-set("hidden-set.png" 1x); */
    .image { background: url("real.png"); }
    """

    assert urls(source) == ["real.png"]
  end

  test "keeps comment-like text in quoted URLs, URL tokens, and escaped text" do
    source = ~S|
    @import "themes/*draft.css";
    .note { --text: \/*; }
    .image { background: url("images/*draft.png"), url(raw/*draft.png); }
    .set { background: image-set("sets/*draft.png" 1x); }
    .other { background: url("real.png"); }
    |

    assert urls(source) == [
             "images/*draft.png",
             "raw/*draft.png",
             "real.png",
             "sets/*draft.png",
             "themes/*draft.css"
           ]
  end

  test "escaped URL identifiers keep their payload opaque before a later live URL" do
    for identifier <- [~S|\75rl|, ~S|u\72l|, ~S|\000075 rl|, ~S|\u\r\l|, "\\000075\r\nrl"] do
      source =
        ".a{background:#{identifier}(raw/*draft.png)} " <>
          ~s|/* url("hidden.png") */ .b{background:url("real.png")}|

      assert urls(source) == ["raw/*draft.png", "real.png"]
      assert [{start, length}] = Scanner.comment_spans(source)
      assert binary_part(source, start, length) == ~s|/* url("hidden.png") */|
    end
  end

  test "comments separate values without changing image-set byte positions" do
    source =
      ~s|/* café */ @import/**/"theme.css"; .x { background: image-set(/* a */"wide.png" 1x,/* b */narrow.png 2x); }|

    assert urls(source) == ["narrow.png", "theme.css", "wide.png"]
    tokens = CssParser.spans(source)

    assert Enum.map(tokens, &binary_part(source, &1.start, &1.length)) ==
             [~s|"theme.css"|, ~s|"wide.png"|, "narrow.png"]
  end

  test "an unterminated comment hides its remaining URL syntax" do
    source = ~s|.x { background:url("real.png") } /* url("hidden.png") @import "hidden.css"|
    assert urls(source) == ["real.png"]
  end

  test "ordinary strings cannot create imports, URL calls, or image-set candidates" do
    source =
      ~S|.label{content:"url(hidden.png) @import 'hidden.css'; image-set('hidden-set.png' 1x)"}.live{background:url(real.png)}|

    assert urls(source) == ["real.png"]
  end

  test "URL token spans keep escaped parentheses, Unicode and quote escapes intact" do
    source = ~S|.x{background:url(foo\)bar.png),url("caf\e9 .png"),url('O\'Reilly.png')}|
    tokens = CssParser.spans(source)

    assert Enum.map(tokens, & &1.value) == ["foo)bar.png", "café.png", "O'Reilly.png"]

    assert Enum.map(tokens, &binary_part(source, &1.start, &1.length)) ==
             [~S|foo\)bar.png|, ~S|"caf\e9 .png"|, ~S|'O\'Reilly.png'|]
  end

  test "HTML entities decode before CSS escapes and spans still cover the source value" do
    source = ~S|url(&quot;foo&#92;)bar.png&quot;),url(&quot;\26 amp;.png&quot;)|
    tokens = CssParser.spans(source, entity_quotes: true)

    assert Enum.map(tokens, & &1.value) == ["foo)bar.png", "&amp;.png"]

    assert Enum.map(tokens, &binary_part(source, &1.start, &1.length)) ==
             [~S|&quot;foo&#92;)bar.png&quot;|, ~S|&quot;\26 amp;.png&quot;|]
  end

  test "string continuations and nested image sets preserve resource boundaries" do
    source =
      "@import \"the\\\r\nme.css\";" <>
        ~S|image-set(image-set("inner.png" type("image/png") 1x) 1x, "outer.png" 2x)|

    assert urls(source) == ["inner.png", "outer.png", "theme.css"]
  end

  defp urls(source) do
    source
    |> CssParser.parse()
    |> Enum.map(fn {"link", [{"href", url}], []} -> url end)
    |> Enum.sort()
  end
end
