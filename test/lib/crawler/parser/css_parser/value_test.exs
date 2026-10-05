defmodule Crawler.Parser.CssParser.ValueTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.CssParser.Scanner
  alias Crawler.Parser.CssParser.Value

  test "trivia keeps reverse source order and byte offsets across whitespace and EOF comments" do
    source = " \t/* café */\r\n/**/\f/* unfinished"
    assert {"", finish, comments} = Value.trivia(source, 7)
    assert finish == 7 + byte_size(source)

    assert Enum.map(comments, fn {start, length} ->
             binary_part(source, start - 7, length)
           end) == ["/* unfinished", "/**/", "/* café */"]
  end

  test "a large consecutive comment run retains every span and the following resource" do
    count = 16_000
    comments = String.duplicate("/**/", count)
    tail = "url(real.png)"
    spans = Enum.map((count - 1)..0, &{4 * &1, 4})

    assert {^tail, finish, ^spans} = Value.trivia(comments <> tail, 0)
    assert finish == 4 * count
    assert Scanner.comment_spans(comments <> tail) == spans

    assert Scanner.resources(comments <> tail) == [
             %{start: finish + 4, length: 8, value: "real.png", quote: ""}
           ]
  end
end
