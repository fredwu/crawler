defmodule Crawler.URLTest do
  use ExUnit.Case, async: true

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

  test "drops the fragment from the request and keeps it on the store key" do
    assert URL.normalize("http://Example.com/a/../b#x") == "http://example.com/b"
    assert URL.canonical("http://Example.com/a/../b#x") == "http://example.com/b#x"
    assert URL.canonical("http://example.com/page") == "http://example.com/page"
  end

  test "leaves percent-encoded dots and literal triple dots alone" do
    assert URL.normalize("http://example.com/a/%2e%2e/b") == "http://example.com/a/%2e%2e/b"
    assert URL.normalize("http://example.com/a/.../c") == "http://example.com/a/.../c"
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
    assert URL.canonical("url1#frag") == "url1#frag"
  end

  test "keeps a directory slash after a final dot segment" do
    assert URL.normalize("http://ex.com/a/b/.") == "http://ex.com/a/b/"
    assert URL.canonical("http://ex.com/a/b/.") == "http://ex.com/a/b"
    assert URL.normalize("http://ex.com/a/b/..") == "http://ex.com/a/"
    assert URL.canonical("http://ex.com/a/b/..") == "http://ex.com/a"
    assert URL.normalize("http://ex.com/a/b/../.") == "http://ex.com/a/"
    assert URL.normalize("http://ex.com/a/...") == "http://ex.com/a/..."
    assert URL.normalize("http://ex.com/a/%2e%2e") == "http://ex.com/a/%2e%2e"
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
end
