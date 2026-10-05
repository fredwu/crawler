defmodule Crawler.URLAuthorityTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker
  alias Crawler.URL

  @base "http://example.com/dir/page"

  test "rejects malformed authorities before URI fields can discard invalid text" do
    for authority <- [
          "host:bad",
          "host:80bad",
          "host:-1",
          "host:+80",
          "host:65536",
          "host:80:90",
          "[bad]",
          "[::1",
          "[::1]suffix",
          "[::1]:bad",
          "[::1]:65536",
          "[]",
          "::1",
          "user@:80",
          ":80",
          ""
        ] do
      url = "http://#{authority}/target"
      assert URL.resolve(url, @base) == :skip
      assert URL.resolve("//#{authority}/target", @base) == :skip
      assert URL.normalize(url) == url
      assert Linker.offline_link(@base, url) == url
    end
  end

  test "rejects a missing absolute host and invalid bases" do
    for link <- ["http:", "http:/", "http:/path", "https:?q=1", "https:#fragment"] do
      assert URL.resolve(link, @base) == :skip
    end

    for base <- ["http://host:bad/path", "http://[bad]/path", "http:///path"] do
      assert URL.resolve("child", base) == :skip
      assert URL.resolve("?q=1", base) == :skip
    end
  end

  test "keeps decimal ports and bracketed IPv6 authorities" do
    for {authority, expected} <- [
          {"host:0", "host:0"},
          {"host:65535", "host:65535"},
          {"host:00081", "host:81"},
          {"host:", "host"},
          {"user:pass@host:80", "user:pass@host"},
          {"[0:0:0:0:0:0:0:1]:81", "[::1]:81"}
        ] do
      assert URL.resolve("http://#{authority}/target", @base) ==
               {:ok, "http://#{expected}/target"}

      assert URL.resolve("//#{authority}/target", @base) ==
               {:ok, "http://#{expected}/target"}
    end
  end

  test "keeps relative paths and browser backslash authority separators" do
    assert URL.resolve("../child", @base) == {:ok, "http://example.com/child"}
    assert URL.resolve("/child", @base) == {:ok, "http://example.com/child"}
    assert URL.resolve("?q=1", @base) == {:ok, "http://example.com/dir/page?q=1"}
    assert URL.resolve("//other.com/child", @base) == {:ok, "http://other.com/child"}
    assert URL.resolve("\\\\other.com\\child", @base) == {:ok, "http://other.com/child"}
    assert URL.resolve("\\\\other.com:bad\\child", @base) == :skip

    assert URL.resolve("a\\b?q=\\tail", @base) ==
             {:ok, "http://example.com/dir/a/b?q=%5ctail"}
  end
end
