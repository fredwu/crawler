defmodule Crawler.Charset.HTMLContextTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset
  alias Crawler.Charset.HTMLScanner

  test "an invalid integration-point meta does not reset the following SVG script context" do
    prefix = ~s|<svg><foreignObject><meta charset="unknown"></foreignObject><script/></svg>|

    source =
      prefix <>
        ~s|<meta charset="latin1"><a href="caf| <> <<0xE9>> <> ~s|">caf| <> <<0xE9>> <> ~s|</a>|

    expected = String.replace(prefix, "charset=\"unknown\"", "charset=\"utf-8\"")
    expected = expected <> ~s|<meta charset="utf-8"><a href="café">café</a>|

    assert Charset.decode(source, %{content_type: "text/html"}) == expected
    assert length(HTMLScanner.meta_spans(source)) == 2
  end

  test "a real meta before SVG CDATA does not expose a later literal meta declaration" do
    literal = ~s|<![CDATA[x><meta charset="latin1">]]>|
    source = ~s|<meta charset="utf-8"><svg>#{literal}</svg><p>café</p>|

    assert Charset.decode(source, %{content_type: "text/html"}) == source
    assert HTMLScanner.meta_spans(source) == [{0, byte_size(~s|<meta charset="utf-8">|)}]
  end

  test "a real Latin-1 meta leaves CDATA declaration bytes intact after decoding" do
    literal =
      ~s|<![CDATA[x><meta http-equiv="content-type" content="text/html; charset=latin1">]]>|

    source = ~s|<meta charset="latin1"><svg>#{literal}</svg><p>caf| <> <<0xE9>> <> ~s|</p>|
    expected = ~s|<meta charset="utf-8"><svg>#{literal}</svg><p>café</p>|

    assert Charset.decode(source, %{content_type: "text/html"}) == expected
  end
end
