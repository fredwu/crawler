defmodule Crawler.ParserTest do
  use Crawler.TestCase, async: true

  alias Crawler.Parser
  alias Crawler.Store.Page

  doctest Parser

  test "resolves relative links against a base href" do
    parent = self()

    opts = %{
      scraper: Crawler.Scraper,
      html_tag: "a",
      content_type: "text/html",
      referrer_url: "http://example.com/dir/page",
      url: "http://example.com/dir/page",
      depth: 1,
      max_depths: 3,
      assets: []
    }

    body = """
    <html><head><base href="http://example.com/other/"></head>
    <a href="next">next</a></html>
    """

    Parser.parse_links(body, opts, fn element, link_opts ->
      send(parent, {:link, element, link_opts[:referrer_url]})
      element
    end)

    assert_receive {:link, {"link", "next", "href", "http://example.com/other/next"},
                    "http://example.com/other/"}
  end
end
