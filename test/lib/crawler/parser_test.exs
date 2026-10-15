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

  test "a base href ending in a non-breaking space is not a directory" do
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

    body = "<html><head><base href=\"docs/\u00A0\"></head><a href=\"x\"></a></html>"

    Parser.parse_links(body, opts, fn element, link_opts ->
      send(parent, {:link, element, link_opts[:referrer_url]})
      element
    end)

    assert_receive {:link, {"link", "x", "href", "http://example.com/dir/docs/x"},
                    "http://example.com/dir/docs/\u00A0"}
  end

  test "a redirected manifest resolves against the response url" do
    opts = %{
      fetch_kind: :manifest,
      url: "http://example.com/old/app.webmanifest",
      referrer_url: "http://example.com/landed/app.webmanifest",
      assets: ["images"]
    }

    body = ~s|{"start_url":"home","icons":[{"src":"icon.png"}]}|

    assert Parser.parse_links(
             body,
             opts,
             &{&1, &2[:html_tag], &2[:reference_tag], &2[:fetch_kind]}
           ) ==
             [
               {{"link", "home", "href", "http://example.com/landed/home"}, "a", "a", nil},
               {{"link", "icon.png", "href", "http://example.com/landed/icon.png"}, "img", "img",
                nil}
             ]
  end

  test "a redirected rules file resolves list urls against the response" do
    opts = %{
      fetch_kind: :speculation_rules,
      url: "http://example.com/old/rules.json",
      referrer_url: "http://example.com/landed/rules.json",
      document_base: "http://example.com/blog/"
    }

    body =
      ~s|{"prefetch":[{"urls":["file-next"]},{"urls":["set-next"],"relative_to":"ruleset"},{"urls":["doc-next"],"relative_to":"document"}]}|

    assert Parser.parse_links(body, opts, &{&1, &2[:html_tag], &2[:fetch_kind]}) == [
             {{"link", "file-next", "href", "http://example.com/landed/file-next"}, "a", nil},
             {{"link", "set-next", "href", "http://example.com/landed/set-next"}, "a", nil},
             {{"link", "doc-next", "href", "http://example.com/blog/doc-next"}, "a", nil}
           ]
  end

  test "a manifest uses the last duplicate start_url" do
    opts = %{
      fetch_kind: :manifest,
      url: "http://example.com/app.webmanifest",
      referrer_url: "http://example.com/app.webmanifest"
    }

    body = ~s|{"start_url":"https://other.test/away","start_url":"home"}|

    assert [{"link", "home", "href", "http://example.com/home"}] ==
             Parser.parse_links(body, opts, fn element, _link_opts -> element end)
  end

  test "a manifest span belongs to the url member" do
    opts = %{
      fetch_kind: :manifest,
      url: "http://example.com/app.webmanifest",
      referrer_url: "http://example.com/app.webmanifest",
      assets: ["images"]
    }

    body =
      ~s|{"name":"Demo","scope":"/","start_url":"/","icons":[{"src":"/","type":"image/png"}]}|

    assert [
             {{"link", "/", "href", "http://example.com/"}, start_span},
             {{"link", "/", "href", "http://example.com/"}, icon_span}
           ] =
             Parser.parse_links(body, opts, fn element, link_opts ->
               {element, link_opts.json_span}
             end)

    assert span_text(body, start_span) == ~s("/")
    assert binary_part(body, 0, elem(start_span, 0)) =~ ~s("start_url")
    refute binary_part(body, 0, elem(start_span, 0)) =~ ~s("src")
    assert span_text(body, icon_span) == ~s("/")
    assert binary_part(body, 0, elem(icon_span, 0)) =~ ~s("src")
  end

  test "speculation rules use the last duplicate prefetch key" do
    opts = %{
      fetch_kind: :speculation_rules,
      url: "http://example.com/rules.json",
      referrer_url: "http://example.com/rules.json"
    }

    body = ~s|{"prefetch":[{"urls":["old"]}],"prefetch":[{"urls":["new"]}]}|

    assert [{"link", "new", "href", "http://example.com/new"}] ==
             Parser.parse_links(body, opts, fn element, _link_opts -> element end)
  end

  test "a speculation rule uses the last duplicate urls key" do
    opts = %{
      fetch_kind: :speculation_rules,
      url: "http://example.com/rules.json",
      referrer_url: "http://example.com/rules.json"
    }

    body = ~s|{"prefetch":[{"urls":["old"],"urls":["new"]}]}|

    assert [{"link", "new", "href", "http://example.com/new"}] ==
             Parser.parse_links(body, opts, fn element, _link_opts -> element end)
  end

  test "manifest and rules pages keep the referring document depth" do
    manifest_opts = %{
      fetch_kind: :manifest,
      url: "http://example.com/app.webmanifest",
      referrer_url: "http://example.com/app.webmanifest",
      assets: ["images"],
      depth: 3
    }

    manifest = ~s|{"start_url":"home","icons":[{"src":"icon.png"}]}|

    assert [
             {{"link", "home", "href", "http://example.com/home"}, 2, "a"},
             {{"link", "icon.png", "href", "http://example.com/icon.png"}, 3, "img"}
           ] =
             Parser.parse_links(manifest, manifest_opts, fn element, link_opts ->
               {element, link_opts.depth, link_opts.html_tag}
             end)

    rules_opts = %{
      fetch_kind: :speculation_rules,
      url: "http://example.com/rules.json",
      referrer_url: "http://example.com/rules.json",
      depth: 3
    }

    rules = ~s|{"prefetch":[{"urls":["next"]}]}|

    assert [{{"link", "next", "href", "http://example.com/next"}, 2, "a"}] =
             Parser.parse_links(rules, rules_opts, fn element, link_opts ->
               {element, link_opts.depth, link_opts.html_tag}
             end)
  end

  test "speculation rules keep list entries that share one raw url" do
    opts = %{
      fetch_kind: :speculation_rules,
      url: "http://example.com/rules/rules.json",
      referrer_url: "http://example.com/rules/rules.json",
      document_base: "http://example.com/blog/"
    }

    body = ~s|{"prefetch":[{"urls":["next"]},{"urls":["next"],"relative_to":"document"}]}|

    assert [
             {{"link", "next", "href", "http://example.com/rules/next"}, first_span},
             {{"link", "next", "href", "http://example.com/blog/next"}, second_span}
           ] =
             Parser.parse_links(body, opts, fn element, link_opts ->
               {element, link_opts.json_span}
             end)

    assert first_span != second_span
    assert span_text(body, first_span) == ~s("next")
    assert span_text(body, second_span) == ~s("next")
  end

  defp span_text(body, {start, length}), do: binary_part(body, start, length)
end
