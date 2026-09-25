defmodule Crawler.Parser.LinkParserTest do
  use Crawler.TestCase, async: true

  alias Crawler.Parser.LinkParser

  doctest LinkParser

  test "skips non-navigation links and resolves protocol-relative and fragment links" do
    opts = %{referrer_url: "http://example.com/dir/page", assets: ["js"]}

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

  test "skips data srcset fragments and still follows a css file without the css flag" do
    parent = self()

    Crawler.Parser.parse_links(
      ~s(<img srcset="data:image/png;base64,AAAA 1x, c.jpg 2x">),
      %{
        assets: ["images"],
        html_tag: "a",
        content_type: "text/html",
        referrer_url: "http://example.com/archive/page"
      },
      fn element, _opts -> send(parent, {:link, element}) end
    )

    assert_receive {:link, {"link", "c.jpg", "srcset", "http://example.com/archive/c.jpg"}}
    refute_receive {:link, _}, 50

    Crawler.Parser.parse_links(
      ~s(<img srcset="DATA:image/png;base64,AAAA 1x, c.jpg 2x">),
      %{
        assets: ["images"],
        html_tag: "a",
        content_type: "text/html",
        referrer_url: "http://example.com/archive/page"
      },
      fn element, _opts -> send(parent, {:upper, element}) end
    )

    assert_receive {:upper, {"link", "c.jpg", "srcset", "http://example.com/archive/c.jpg"}}
    refute_receive {:upper, _}, 50

    Crawler.Parser.parse_links(
      "body { background: url(a.png) }",
      %{
        content_type: "text/css",
        html_tag: "a",
        assets: [],
        referrer_url: "http://example.com/a.css"
      },
      fn element, _opts -> send(parent, {:css, element}) end
    )

    assert_receive {:css, {"link", "a.png", "href", "http://example.com/a.png"}}

    Crawler.Parser.parse_links(
      "<style>body { background: url(&#x27;hex.png&#x27;); }</style>",
      %{
        assets: ["css"],
        html_tag: "a",
        content_type: "text/html",
        referrer_url: "http://example.com/page"
      },
      fn element, _opts -> send(parent, {:hex, element}) end
    )

    assert_receive {:hex, {"link", "hex.png", "href", "http://example.com/hex.png"}}
  end
end
