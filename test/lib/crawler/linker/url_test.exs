defmodule Crawler.Linker.URLTest do
  use ExUnit.Case, async: true

  alias Crawler.Linker

  test "absolute targets retain their scheme across HTTP and HTTPS sources" do
    for source <- ["http://a.test/page", "https://a.test/page"],
        target <- ["http://b.test/file", "https://b.test/file"] do
      assert Linker.url(source, target) == target
    end
  end

  test "relative references use the source authority and scheme" do
    for {source, link, expected} <- [
          {"http://another.domain:8888/page", "/dir/page2",
           "http://another.domain:8888/dir/page2"},
          {"http://another.domain:8888/parent/page", "dir/page2",
           "http://another.domain:8888/parent/dir/page2"},
          {"https://a.test/parent/page", "../file", "https://a.test/file"},
          {"https://a.test/page", "//b.test/file", "https://b.test/file"},
          {"http://a.test/page", "//b.test/file", "http://b.test/file"},
          {"https://a.test/page", "?q=1", "https://a.test/page?q=1"}
        ] do
      assert Linker.url(source, link) == expected
    end
  end

  test "absolute targets use the canonical resolver without requiring a source" do
    target = "HTTPS://B.TEST:443/dir/../café?q={}&x=%26#part"
    expected = "https://b.test/café?q=%7b%7d&x=%26"

    for source <- ["http://a.test/page", nil, "invalid"] do
      assert Linker.url(source, target) == expected
    end
  end

  test "unsupported or unresolved references are returned unchanged" do
    source = "http://a.test/page"

    for link <- [nil, 123, "", "mailto:user@example.com", "http://b.test:bad/file"] do
      assert Linker.url(source, link) == link
    end

    assert Linker.url(nil, "child") == "child"
    assert Linker.url("invalid", "child") == "child"
    assert Linker.url(nil, "//b.test/file") == "//b.test/file"
  end
end
