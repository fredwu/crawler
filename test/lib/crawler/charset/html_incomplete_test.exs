defmodule Crawler.Charset.HTMLIncompleteTest do
  use ExUnit.Case, async: true

  alias Crawler.Charset
  alias Crawler.Charset.HTML
  alias Crawler.Charset.HTMLScanner

  for incomplete <- [
        "<meta charset=latin1",
        ~s|<meta charset="latin1"|,
        ~s|<meta charset="latin1|,
        ~s|<meta charset='latin1|,
        ~s|<meta http-equiv="content-type" content="text/html; charset=latin1"|,
        ~s|<meta charset="latin1><meta charset='latin1'>|
      ] do
    test "#{incomplete} neither selects a charset nor changes its unfinished source" do
      source = "café" <> unquote(incomplete)
      assert HTML.charset(source) == nil
      assert HTMLScanner.meta_spans(source) == []
      assert Charset.decode(source, %{content_type: "text/html"}) == source
    end
  end

  test "a preceding complete Latin-1 meta is used while a trailing incomplete meta is unchanged" do
    suffix = ~s|<meta charset="latin1"|
    source = ~s|<meta charset="latin1">caf| <> <<0xE9>> <> suffix
    expected = ~s|<meta charset="utf-8">café| <> suffix

    assert HTMLScanner.meta_spans(source) == [{0, 23}]
    assert Charset.decode(source, %{content_type: "text/html"}) == expected
  end
end
