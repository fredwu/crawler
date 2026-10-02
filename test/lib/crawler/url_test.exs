defmodule Crawler.URLTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker.Snapshot
  alias Crawler.URL

  test "folds host case, default ports, and dot segments" do
    assert URL.normalize("HTTP://Example.COM:80/a/../b") == "http://example.com/b"
    assert URL.normalize("https://Example.COM:443/a/./c/") == "https://example.com/a/c/"
    assert URL.normalize("http://example.com/a/../../about") == "http://example.com/about"
    assert URL.normalize("http://User:Pass@Example.COM/a") == "http://User:Pass@example.com/a"
    assert URL.normalize("http://Example.com/A/../B") == "http://example.com/B"
  end

  test "keeps a trailing slash on the request and drops it from the store key" do
    assert URL.normalize("http://options/") == "http://options/"
    assert URL.normalize("http://host/dir/docs/") == "http://host/dir/docs/"
    assert URL.normalize("http://host/foo") == "http://host/foo"
    assert URL.canonical("http://host/foo/") == "http://host/foo"
    assert URL.canonical("http://host/foo") == "http://host/foo"
    assert URL.canonical("http://host/?q=1") == "http://host?q=1"
    assert URL.normalize("http://host/foo/?q=1") == "http://host/foo/?q=1"
  end

  test "preserves repeated trailing slashes in requests and store identities" do
    for path <- ["//", "/a//", "/a///", "/app.js//"] do
      assert URL.normalize("http://host" <> path) == "http://host" <> path
      assert URL.canonical("http://host" <> path) == "http://host" <> path

      assert URL.canonical("http://host" <> path <> "?q=1#section") ==
               "http://host" <> path <> "?q=1"
    end

    assert URL.canonical("http://host/a/") == URL.canonical("http://host/a")
    assert Snapshot.path("http://host/a/") == Snapshot.path("http://host/a")

    identities = Enum.map(["/a", "/a//", "/a///"], &URL.canonical("http://host" <> &1))
    assert length(Enum.uniq(identities)) == 3
    assert_different("http://host/a/", "http://host/a//")
    assert_different("http://host/a//", "http://host/a///")
    assert_different("http://host/app.js", "http://host/app.js//")
  end

  test "preserves empty trailing segments when removing dot segments" do
    for {input, expected} <- [
          {"/a//.", "/a//"},
          {"/a//./", "/a//"},
          {"/a//..", "/a/"},
          {"/a///..", "/a//"},
          {"/a/./b/..//", "/a//"},
          {"/a/x/..///", "/a///"},
          {"/a/..//", "//"},
          {"/a//%2e", "/a//"}
        ] do
      assert URL.normalize("http://host" <> input) == "http://host" <> expected
    end
  end

  test "resolves relative paths without losing repeated trailing slashes" do
    base = "http://host/dir/page"

    assert URL.resolve("a//", base) == {:ok, "http://host/dir/a//"}
    assert URL.resolve("a///", base) == {:ok, "http://host/dir/a///"}
    assert URL.resolve("a/x/..//", base) == {:ok, "http://host/dir/a//"}
    assert URL.resolve("a//.", base) == {:ok, "http://host/dir/a//"}
    assert URL.resolve("../a//?q=1", base) == {:ok, "http://host/a//?q=1"}
  end

  test "drops the fragment from the request and the store key" do
    assert URL.normalize("http://Example.com/a/../b#x") == "http://example.com/b"
    assert URL.canonical("http://Example.com/a/../b#x") == "http://example.com/b"

    assert URL.canonical("http://example.com/page#a") ==
             URL.canonical("http://example.com/page#b")

    assert URL.canonical("http://example.com/page") == "http://example.com/page"
  end

  test "folds percent-encoded dot segments and keeps triple dots and internal slashes" do
    assert URL.normalize("http://example.com/a/%2e%2e/b") == "http://example.com/b"
    assert URL.normalize("http://example.com/a/%2E/%2e%2E/b") == "http://example.com/b"
    assert URL.normalize("http://example.com/a/%2e%2e") == "http://example.com/"
    assert URL.canonical("http://example.com/a/%2e%2e") == "http://example.com"
    assert URL.normalize("http://example.com/a/.../c") == "http://example.com/a/.../c"
    assert URL.normalize("http://example.com/a/%2e%2e%2e/c") == "http://example.com/a/.../c"
    assert URL.canonical("http://example.com/a/.../c") == "http://example.com/a/.../c"
    assert URL.normalize("http://example.com//a") == "http://example.com//a"
    assert URL.normalize("http://example.com/a//b/") == "http://example.com/a//b/"
    assert URL.canonical("http://example.com/a//b/") == "http://example.com/a//b"
  end

  test "does not fold a query as a path" do
    assert URL.normalize("http://host/search?q=foo/../bar") == "http://host/search?q=foo/../bar"

    assert URL.canonical("http://host/search/?q=foo/../bar") ==
             "http://host/search?q=foo/../bar"
  end

  test "keeps non-http store keys stable" do
    assert URL.normalize("url1") == "url1"
    assert URL.normalize("url1#frag") == "url1"
    assert URL.canonical("url1") == "url1"
    assert URL.canonical("url1/") == "url1"
    assert URL.canonical("url1#frag") == "url1"
  end

  test "keeps a directory slash after a final dot segment" do
    assert URL.normalize("http://ex.com/a/b/.") == "http://ex.com/a/b/"
    assert URL.canonical("http://ex.com/a/b/.") == "http://ex.com/a/b"
    assert URL.normalize("http://ex.com/a/b/..") == "http://ex.com/a/"
    assert URL.canonical("http://ex.com/a/b/..") == "http://ex.com/a"
    assert URL.normalize("http://ex.com/a/b/../.") == "http://ex.com/a/"
    assert URL.normalize("http://ex.com/a/...") == "http://ex.com/a/..."
    assert URL.normalize("http://ex.com/a/%2e%2e") == "http://ex.com/"
    assert URL.canonical("http://ex.com/a/%2e%2e") == "http://ex.com"
    assert URL.resolve("c", "http://ex.com/a/b/.") == {:ok, "http://ex.com/a/b/c"}
    assert URL.resolve("c", "http://ex.com/a/b/..") == {:ok, "http://ex.com/a/c"}

    assert URL.resolve("http://ex.com/a/b/.", "http://ex.com/blog/post") ==
             {:ok, "http://ex.com/a/b/"}
  end

  test "resolves parent links and dotted absolute urls onto one page" do
    assert URL.resolve("../../about", "http://example.com/blog/post") ==
             {:ok, "http://example.com/about"}

    assert URL.resolve("../../images/a.png", "http://example.com/css/app.css") ==
             {:ok, "http://example.com/images/a.png"}

    assert URL.resolve("http://example.com/a/../../about", "http://example.com/blog/post") ==
             {:ok, "http://example.com/about"}

    assert URL.resolve("intro", "http://host/dir/docs/") ==
             {:ok, "http://host/dir/docs/intro"}

    assert URL.resolve("#section", "http://example.com/blog/post") ==
             {:ok, "http://example.com/blog/post"}

    assert URL.resolve("mailto:a@b.c", "http://example.com/blog/post") == :skip
  end

  test "treats host spellings as one page" do
    assert_one_page([
      "http://éxample.com/a",
      "http://xn--xample-9ua.com/a",
      "http://ÉXAMPLE.COM./a",
      "HTTP://éxample.com:80/a#section"
    ])

    assert_one_page([
      "http://www.éxample.com/a",
      "http://www.xn--xample-9ua.com./a"
    ])

    assert URL.normalize("http://例.com/a") == "http://xn--fsq.com/a"
    assert URL.normalize("http://München.com/a") == "http://xn--mnchen-3ya.com/a"
    assert URL.normalize("http://café.com/a") == "http://xn--caf-dma.com/a"
    assert_different("http://example.com../a", "http://example.com/a")
    assert_different("http://example.com./a", "http://example.com../a")
    assert URL.normalize("http://./a") == "http://./a"
    assert URL.normalize("http://example.com./a") == "http://example.com/a"
  end

  test "treats ipv6 spellings as one page" do
    assert_one_page([
      "http://[::1]/a",
      "http://[0::1]/a",
      "http://[0:0:0:0:0:0:0:1]/a",
      "http://[::1]:80/a#section"
    ])

    assert URL.normalize("http://[2001:0db8:0000:0000:0000:0000:0000:0001]/a") ==
             "http://[2001:db8::1]/a"

    assert URL.normalize("http://[fe80:1::1]/a") == "http://[fe80:1::1]/a"
    assert URL.normalize("http://[ff02:1::1]/a") == "http://[ff02:1::1]/a"
    assert URL.canonical("http://[FE80:1::1]/a") == "http://[fe80:1::1]/a"
    assert URL.normalize("http://[::ffff:192.0.2.1]/a") == "http://[::ffff:c000:201]/a"
    assert URL.normalize("http://[::ffff:c000:201]/a") == "http://[::ffff:c000:201]/a"
  end

  test "folds percent-encoding, spaces, breaks, and path backslashes" do
    assert_one_page([
      "http://ex.com/a%7Eb",
      "http://ex.com/a%7eb",
      "http://ex.com/a~b"
    ])

    assert_one_page([
      "http://ex.com/%41",
      "http://ex.com/A"
    ])

    assert_one_page([
      "http://ex.com/caf%C3%A9",
      "http://ex.com/café"
    ])

    assert_one_page([
      "http://ex.com/a b",
      "http://ex.com/a%20b",
      "http://ex.com/a%20b#top"
    ])

    assert URL.normalize("http://ex.com/a\tb") == "http://ex.com/ab"
    assert URL.normalize("http://ex.com/a\r\nb") == "http://ex.com/ab"
    assert URL.normalize("  http://ex.com/a  ") == "http://ex.com/a"
    assert URL.normalize("http://ex.com/a\\b") == "http://ex.com/a/b"
    assert URL.normalize("http:\\\\ex.com\\a") == "http://ex.com/a"
    assert URL.normalize("http://ex.com/a?b\\c") == "http://ex.com/a?b%5cc"
    assert URL.normalize("http://ex.com/a?b%5C") == "http://ex.com/a?b%5c"
    assert URL.normalize("http://ex.com/a?q=%7E") == "http://ex.com/a?q=~"
    assert URL.normalize("http://ex.com/a?q=%2E%2E") == "http://ex.com/a?q=.."
    assert URL.normalize("http://ex.com/a?q=%41") == "http://ex.com/a?q=A"

    assert Snapshot.path("http://ex.com/%7E") == "ex.com/~/__index.html"
    refute Snapshot.path("http://ex.com/%7E") =~ "__u_"
    refute Snapshot.path("http://ex.com/a%2Fb") =~ "__u_"
  end

  test "keeps different pages on different files" do
    assert_different("http://ex.com/a", "https://ex.com/a")
    assert_different("http://a:b@ex.com/a", "http://A:B@ex.com/a")
    assert_different("http://a:b@ex.com/a", "http://ex.com/a")
    assert_different("http://ex.com/Docs", "http://ex.com/docs")
    assert_different("http://ex.com/a%2Fb", "http://ex.com/a/b")
    assert_one_page(["http://ex.com/a%2Fb", "http://ex.com/a%2fb"])
    assert_different("http://ex.com/search?", "http://ex.com/search")
    assert_different("http://ex.com/a//b", "http://ex.com/a/b")
    assert_different("http://ex.com/q?a=1&b=2", "http://ex.com/q?b=2&a=1")
    assert_different("http://ex.com/q?q=a+b", "http://ex.com/q?q=a%20b")
    assert_different("http://ex.com/a/...", "http://ex.com/a/..")
    assert URL.normalize("http://ex.com/a?q=foo/../bar") == "http://ex.com/a?q=foo/../bar"
    assert URL.normalize("http://ex.com/dir?q=%2e%2e") == "http://ex.com/dir?q=.."

    assert Snapshot.path("http://ex.com/search?") == "ex.com/search/__index__q_.html"
    assert Snapshot.path("http://ex.com/search") == "ex.com/search/__index.html"
    assert Snapshot.path("https://ex.com/a") =~ "__scheme_https"
    assert Snapshot.path("http://ex.com/a//b") =~ "__e_"
  end

  test "resolves a path backslash and an encoded dot onto the fetched page" do
    assert URL.resolve("a\\b", "http://ex.com/dir/page") == {:ok, "http://ex.com/dir/a/b"}
    assert URL.resolve("%2e%2e/about", "http://ex.com/dir/page") == {:ok, "http://ex.com/about"}
    assert URL.resolve("my page", "http://ex.com/dir/") == {:ok, "http://ex.com/dir/my%20page"}
  end

  test "sanitizes a link before deciding whether it is the same page" do
    base = "http://other.com/dir/page"

    assert URL.resolve("ht\ttp://ex.com/a", base) == {:ok, "http://ex.com/a"}
    assert URL.resolve("http:\\\\ex.com\\a", base) == {:ok, "http://ex.com/a"}
    assert URL.resolve(<<1, "http://ex.com/a">>, base) == {:ok, "http://ex.com/a"}
    assert URL.resolve(" \thttp://ex.com/a\r\n", base) == {:ok, "http://ex.com/a"}
    assert URL.resolve("java\nscript:alert(1)", base) == :skip
    assert URL.resolve("a\\b", base) == {:ok, "http://other.com/dir/a/b"}
    refute URL.resolve("\u00A0http://ex.com/a", base) == {:ok, "http://ex.com/a"}
  end

  defp assert_one_page(spellings) do
    [first | rest] = Enum.map(spellings, &page_identity/1)

    Enum.each(rest, fn spelling ->
      assert spelling == first
    end)
  end

  defp page_identity(url) do
    {URL.normalize(url), URL.canonical(url), Snapshot.path(url)}
  end

  defp assert_different(left, right) do
    refute URL.normalize(left) == URL.normalize(right)
    refute Snapshot.path(left) == Snapshot.path(right)
  end
end
