defmodule Crawler.LinkerTest do
  use Crawler.TestCase, async: true

  alias Crawler.Linker

  doctest Linker

  test "offline fragments use sanitized URL input and preserve existing escapes" do
    page = "http://example.com/blog/post"
    target = Linker.offline_link(page, "next")

    for {fragment, expected} <- [
          {"x\ny", "xy"},
          {"x\ry", "xy"},
          {"x\ty", "xy"},
          {"xy\0\x1F ", "xy"},
          {"x%0Ay%0D%09%00%2F", "x%0Ay%0D%09%00%2F"},
          {"x%ZZ", "x%25ZZ"}
        ] do
      assert Linker.offline_link(page, "next#" <> fragment) == target <> "#" <> expected
    end
  end
end
