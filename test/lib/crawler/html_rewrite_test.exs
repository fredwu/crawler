defmodule Crawler.HTMLRewriteTest do
  use ExUnit.Case, async: true

  alias Crawler.HTMLSpans
  alias Crawler.Parser.HtmlParser

  test "unordered source edits preserve untouched text and support adjacent spans" do
    edits = [{{4, 1}, ""}, {{2, 2}, "XY"}, {{1, 1}, "B"}]
    assert HTMLSpans.rewrite("abcdef", edits) == "aBXYf"
    assert HTMLSpans.rewrite("abcdef", []) == "abcdef"
  end

  test "insertions at replacement boundaries and EOF retain their input order" do
    edits = [
      {{6, 0}, "!"},
      {{2, 2}, "XY"},
      {{0, 0}, "<"},
      {{4, 1}, ""},
      {{1, 1}, "B"},
      {{2, 0}, "["},
      {{2, 0}, "]"},
      {{4, 0}, ">"}
    ]

    assert HTMLSpans.rewrite("abcdef", edits) == "<aB[]XY>f!"
    assert HTMLSpans.rewrite("", [{{0, 0}, "first"}, {{0, 0}, "second"}]) == "firstsecond"
  end

  test "replacement spans use byte offsets and preserve arbitrary untouched bytes" do
    body = <<0, 0xE9, ?-, 0xC3, 0xA9, ?!, 0xFF>>

    assert HTMLSpans.rewrite(body, [{{3, 2}, "é"}, {{2, 1}, "XY"}]) ==
             <<0, 0xE9>> <> "XYé" <> <<?!, 0xFF>>
  end

  for edits <- [
        [{{1, 3}, "x"}, {{2, 1}, "y"}],
        [{{1, 3}, "x"}, {{2, 0}, "y"}],
        [{{1, 1}, "x"}, {{1, 1}, "y"}],
        [{{6, 1}, "x"}],
        [{{7, 0}, "x"}],
        [{{0, 7}, "x"}],
        [{{-1, 0}, "x"}],
        [{{0, -1}, "x"}],
        [{{0.5, 1}, "x"}],
        [{{0, 1}, nil}],
        [:invalid]
      ] do
    test "invalid or overlapping edits #{inspect(edits)} raise" do
      assert_raise ArgumentError, fn ->
        HTMLSpans.rewrite("abcdef", unquote(Macro.escape(edits)))
      end
    end
  end

  test "many replacements preserve the exact result without a timing assertion" do
    count = 5_000
    body = String.duplicate("a-b-", count)
    edits = for index <- (count - 1)..0, do: {{index * 4, 1}, "LONG"}
    assert HTMLSpans.rewrite(body, edits) == String.duplicate("LONG-b-", count)
  end

  test "public HTML parsing preserves children across many unquoted attributes" do
    count = 1_000
    body = String.duplicate("<a href=next title=keep>go</a>", count)
    nodes = HtmlParser.parse(body, %{})
    assert length(nodes) == count
    assert Enum.all?(nodes, &(&1 == {"a", [{"href", "next"}, {"title", "keep"}], ["go"]}))
  end
end
