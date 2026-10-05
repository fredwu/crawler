defmodule Crawler.Charset.HTMLBoundariesTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset
  alias Crawler.Charset.HTMLScanner

  for comment <- [
        "<!-->",
        "<!--->",
        ~s|<!-- <meta charset="utf-8"><a href="next">literal</a> --!>|,
        "<!-- outer <!-- nested --!>"
      ] do
    test "#{comment} exposes the following Latin-1 declaration" do
      comment = unquote(comment)

      source =
        comment <>
          ~s|<meta charset="latin1"><a href="caf| <> <<0xE9>> <> ~s|">caf| <> <<0xE9>> <> "</a>"

      expected =
        comment <>
          ~s|<meta charset="utf-8"><a href="café">café</a>|

      assert Charset.decode(source, %{content_type: "text/html"}) == expected
      assert HTMLScanner.meta_spans(source) == [{byte_size(comment), 23}]
    end
  end

  test "a double-escaped literal meta neither selects Latin-1 nor changes its source" do
    script = ~s|<script><!--<script></script><meta charset="latin1">--></script>|
    source = script <> "café"

    assert Charset.decode(source, %{content_type: "text/html"}) == source
    assert HTMLScanner.meta_spans(source) == []
  end

  test "the real declaration after a double-escaped script decodes Latin-1" do
    script = ~s|<script><!--<script></script><meta charset="utf-8">--></script>|
    source = script <> ~s|<meta charset="latin1"><p>caf| <> <<0xE9>> <> "</p>"
    expected = script <> ~s|<meta charset="utf-8"><p>café</p>|

    assert Charset.decode(source, %{content_type: "text/html"}) == expected
    assert HTMLScanner.meta_spans(source) == [{byte_size(script), 23}]
  end

  test "an escaped script close exposes a real charset while comment lookalikes stay literal" do
    script = ~s|<script><!--<script!></script>|
    source = script <> ~s|<meta charset="latin1"><p>caf| <> <<0xE9>> <> "</p>"
    expected = script <> ~s|<meta charset="utf-8"><p>café</p>|
    assert Charset.decode(source, %{content_type: "text/html"}) == expected
  end

  test "EOF inside double-escaped script content leaves all literal declarations intact" do
    source = ~s|<script><!--<script></script><meta charset="latin1">café|
    assert Charset.decode(source, %{content_type: "text/html"}) == source
    assert HTMLScanner.meta_spans(source) == []
  end
end
