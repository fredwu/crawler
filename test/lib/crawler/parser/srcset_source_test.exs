defmodule Crawler.Parser.SrcsetSourceTest do
  use ExUnit.Case, async: true

  alias Crawler.Parser.Srcset

  test "encoded candidate boundaries preserve descriptor and separator source bytes" do
    source = "a.png&#32;1x&#44;&#x20;b.png&#x09;2x"

    assert Srcset.replace(source, "a.png", "saved/a.png") ==
             "saved/a.png&#32;1x&#44;&#x20;b.png&#x09;2x"

    assert Srcset.replace(source, "b.png", "saved/b.png") ==
             "a.png&#32;1x&#44;&#x20;saved/b.png&#x09;2x"
  end

  test "URL entities belong to the URL span while trailing candidate commas do not" do
    source = "a&#44;b.png&#32;1x&#44; next.png&#44;"

    assert Srcset.replace(source, "a,b.png", "saved/comma.png") ==
             "saved/comma.png&#32;1x&#44; next.png&#44;"

    assert Srcset.replace(source, "next.png", "saved/next.png") ==
             "a&#44;b.png&#32;1x&#44; saved/next.png&#44;"
  end

  test "data payloads and entity spellings outside the matching candidate stay unchanged" do
    source = "DATA:image/png;base64,AAAA&#32;1x&#44; b.png?x=1&amp;y=2&#32;2x"

    assert Srcset.replace(source, "b.png?x=1&y=2", "saved/b.png") ==
             "DATA:image/png;base64,AAAA&#32;1x&#44; saved/b.png&#32;2x"
  end
end
