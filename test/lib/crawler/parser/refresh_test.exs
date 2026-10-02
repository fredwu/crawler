defmodule Crawler.Parser.RefreshTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.LinkParser

  test "keeps the full unquoted target after the refresh prefix" do
    for target <- ["/next;v=2", "/next?q=1;v=2", "/next;v=2?q=1;v=3"] do
      assert {"link", ^target, "content", url} = parse("0; url=#{target}")
      assert url == "http://example.com#{target}"
    end
  end

  test "keeps quoted targets and their surrounding refresh syntax separate" do
    for quote <- ["'", "\""] do
      target = "/next;v=2?q=1;v=3"

      assert {"link", ^target, "content", "http://example.com/next;v=2?q=1;v=3"} =
               parse("5; URL = #{quote}#{target}#{quote}; ignored")
    end
  end

  test "keeps trailing target whitespace for replacement while resolving the trimmed URL" do
    assert {"link", "/next;v=2  ", "content", "http://example.com/next;v=2"} =
             parse("0; url=/next;v=2  ")
  end

  test "keeps the opposite quote inside each quoted target" do
    for {quote, target} <- [{"\"", "/next?name=O'Reilly"}, {"'", ~s|/next?name="Reilly"|}] do
      assert {"link", ^target, "content", url} = parse("0; url=#{quote}#{target}#{quote}")
      assert url == "http://example.com#{target}"
    end
  end

  test "skips missing, empty, and unclosed targets" do
    for content <- [
          "0",
          "0; url=",
          "0; url=   ",
          "0; url=''",
          "0; url=\"\"",
          "0; url='/next",
          "0; url=\"/next",
          "0; url='/next\"",
          "0; url=\"/next'"
        ] do
      assert parse(content) == nil
    end
  end

  defp parse(content) do
    LinkParser.parse(
      {"meta", [{"http-equiv", "refresh"}, {"content", content}], []},
      %{referrer_url: "http://example.com/page"},
      fn element, _opts -> element end
    )
  end
end
