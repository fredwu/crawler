defmodule Crawler.Parser.LinkParserTest do
  use Crawler.TestCase, async: true

  alias Crawler.Parser.LinkParser

  doctest LinkParser

  test "skips non-navigation links and resolves protocol-relative and fragment links" do
    opts = %{referrer_url: "http://example.com/dir/page"}

    assert nil ==
             LinkParser.parse(
               {"a", [{"href", "mailto:a@b.c"}], []},
               opts,
               fn element, _opts -> element end
             )

    assert nil ==
             LinkParser.parse(
               {"a", [{"href", "javascript:void(0)"}], []},
               opts,
               fn element, _opts -> element end
             )

    assert {"link", "//cdn.example/lib.js", "src", "http://cdn.example/lib.js"} ==
             LinkParser.parse(
               {"script", [{"src", "//cdn.example/lib.js"}], []},
               opts,
               fn element, _opts -> element end
             )

    assert nil ==
             LinkParser.parse(
               {"a", [{"href", " javascript:alert(1)"}], []},
               opts,
               fn element, _opts -> element end
             )

    assert {"link", "#top", "href", "http://example.com/dir/page"} ==
             LinkParser.parse(
               {"a", [{"href", "#top"}], []},
               opts,
               fn element, _opts -> element end
             )
  end
end
