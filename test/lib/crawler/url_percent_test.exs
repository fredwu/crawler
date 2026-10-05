defmodule Crawler.URLPercentTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker.Snapshot
  alias Crawler.URL
  alias Crawler.URL.Percent

  test "raw path bytes in the browser encode set share their escaped identity" do
    for {raw, escaped} <- [
          {"a<b", "a%3cb"},
          {"a>b", "a%3eb"},
          {~s(a"b), "a%22b"},
          {"a`b", "a%60b"},
          {"a{b}", "a%7bb%7d"},
          {"a^b", "a%5eb"},
          {"a|b", "a%7cb"},
          {"a%ZZ", "a%25ZZ"},
          {"a\0b", "a%00b"},
          {"a\x01b", "a%01b"},
          {"a\x7fb", "a%7fb"}
        ] do
      assert_same_page("http://example.com/#{raw}", "http://example.com/#{escaped}")
    end
  end

  test "special-query encoding uses the query rules rather than the path rules" do
    for {raw, escaped} <- [
          {"a<b", "a%3cb"},
          {~s(a"b), "a%22b"},
          {"a'b", "a%27b"},
          {"a`{}|b", "a%60%7b%7d%7cb"},
          {"a%ZZ", "a%25ZZ"},
          {"a\0b", "a%00b"}
        ] do
      assert_same_page(
        "http://example.com/search?q=#{raw}",
        "http://example.com/search?q=#{escaped}"
      )
    end

    assert URL.normalize("http://example.com/search?q=`{}?/:@&=") ==
             "http://example.com/search?q=%60%7b%7d?/:@&="

    assert URL.normalize("http://example.com/a'b") == "http://example.com/a'b"
  end

  test "reserved escapes and Unicode identities are preserved" do
    assert URL.normalize("http://example.com/caf%C3%A9?q=%C3%A9") ==
             "http://example.com/café?q=é"

    refute URL.canonical("http://example.com/a%2fb") == URL.canonical("http://example.com/a/b")
    refute URL.canonical("http://example.com/a%3fb") == URL.canonical("http://example.com/a?b")
    refute URL.canonical("http://example.com/a%26b") == URL.canonical("http://example.com/a&b")

    refute URL.canonical("http://example.com/search?q=%26") ==
             URL.canonical("http://example.com/search?q=&")
  end

  test "the contextual wire encoder preserves valid escapes and encodes raw bytes" do
    assert Percent.encode("café/a%2Fb?q", :path) == "caf%c3%a9/a%2Fb%3fq"
    assert Percent.encode("q=é&x=%26", :query) == "q=%c3%a9&x=%26"
    assert Percent.encode("%ZZ", :path) == "%25ZZ"
  end

  test "canonical and wire escaping agree for ASCII bytes without double encoding" do
    for context <- [:path, :query],
        byte <- 0..0x7F,
        not URI.char_unescaped?(byte) do
      raw = "a" <> <<byte>> <> "b"
      encoded = Percent.encode(raw, context)
      assert Percent.canonicalize(raw, context) == encoded
      assert Percent.canonicalize(encoded, context) == encoded
      assert Percent.encode(encoded, context) == encoded
    end

    assert Percent.canonicalize("a%2Fb", :path) == "a%2fb"
    assert Percent.encode("a%2Fb", :path) == "a%2Fb"
    assert Percent.canonicalize("café", :path) == "café"
    assert Percent.encode("café", :path) == "caf%c3%a9"
  end

  test "offline fragments encode source delimiters without changing decoded data" do
    fragment = ~s|quotes'"`\\()&${}<>| <> "\0é%ZZ"
    encoded = Percent.encode(fragment, :fragment)

    assert URI.decode(encoded) == fragment
    refute encoded =~ ~r/["'`\\()&${}<>\x00]/
    assert Percent.encode("part%2Ftwo%3a", :fragment) == "part%2Ftwo%3a"
  end

  defp assert_same_page(left, right) do
    assert URL.normalize(left) == right
    assert URL.canonical(left) == URL.canonical(right)
    assert URL.resolve(left, nil) == {:ok, right}
    assert Snapshot.path(left) == Snapshot.path(right)
  end
end
