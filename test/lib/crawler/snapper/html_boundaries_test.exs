defmodule Crawler.Snapper.HTMLBoundariesTest do
  use Crawler.OfflineLinkCase, async: true

  import Crawler.SnapshotHelpers, only: [saved: 2]
  import Crawler.TestHelpers, only: [tmp: 1]

  alias Crawler.Charset
  alias Crawler.HTMLSpans
  alias Crawler.Parser
  alias Crawler.Parser.HtmlParser
  alias Crawler.Snapper

  for comment <- [
        "<!-->",
        "<!--->",
        ~s|<!-- <base href="/wrong/"><a href="next">literal</a> --!>|,
        ~s|<!-- outer <!-- <a href="next">literal</a> --!>|
      ] do
    test "#{comment} preserves its source and exposes the real base and link" do
      comment = unquote(comment)
      source = comment <> ~s|<base href="/docs/"><a href="next">real</a>|
      target = "http://example.com/docs/next"
      href = Linker.offline_link(@page, target)

      assert discovered(source) == [target]
      assert source |> HtmlParser.parse(%{}) |> Floki.attribute("href") == ["next"]
      assert rewrite(source, @page) == comment <> ~s|<a href="#{href}">real</a>|
    end
  end

  test "double-escaped base and link literals neither affect discovery nor change their source" do
    script =
      ~s|<script><!--<script></script><base href="/wrong/"><a href="next">literal</a>--></script>|

    source = script <> ~s|<base href="/docs/"><a href="next">real</a>|
    target = "http://example.com/docs/next"
    href = Linker.offline_link(@page, target)

    assert discovered(source) == [target]
    assert rewrite(source, @page) == script <> ~s|<a href="#{href}">real</a>|
    assert [base] = HTMLSpans.base_tags(source)
    assert HTMLSpans.value(base, "href") == "/docs/"
  end

  test "a literal base in a script without a real closing tag remains inactive" do
    source = ~s|<script><!--<script></script><base href="/wrong/"><a href="next">literal</a>|
    assert discovered(source) == []
    assert rewrite(source, @page) == source
  end

  test "a script lookalike exposes real links after the escaped closing tag" do
    script = ~s|<script><!--<script!></script>|
    source = script <> ~s|<base href="/docs/"><a href="next">real</a>|
    target = "http://example.com/docs/next"
    href = Linker.offline_link(@page, target)
    assert discovered(source) == [target]
    assert rewrite(source, @page) == script <> ~s|<a href="#{href}">real</a>|
  end

  test "ordinary comments and literal script markup retain their parser source bytes" do
    source =
      ~s|<!-- <a href="next">literal</a> -->| <>
        ~s|<script><!--<script></script><meta charset="latin1">--></script>|

    assert HTMLSpans.parser_source(source) == source
  end

  test "the saved UTF-8 document preserves alternate comments and double-escaped script literals" do
    root = tmp("snapshot-html-boundaries")
    page = "http://example.com/index.html"
    target = "http://example.com/docs/café"
    comment = ~s|<!-- <a href="café">literal</a> --!>|

    script =
      ~s|<script><!--<script></script><meta charset="latin1"><base href="/wrong/"><a href="café">literal</a>--></script>|

    source =
      comment <> script <> ~s|<meta charset="utf-8"><base href="/docs/"><a href="café">real</a>|

    assert Charset.decode(source, %{content_type: "text/html"}) == source

    for {url, body} <- [{target, "TARGET"}, {page, source}] do
      assert {:ok, _opts} =
               Snapper.snap(body, %{
                 url: url,
                 save_to: root,
                 content_type: "text/html",
                 html_tag: "a",
                 assets: [],
                 depth: 1,
                 max_depths: 3
               })
    end

    href = Linker.offline_link(page, target)

    assert File.read!(saved(root, page)) ==
             <<0xEF, 0xBB, 0xBF>> <>
               comment <> script <> ~s|<meta charset="utf-8"><a href="#{href}">real</a>|
  end

  defp discovered(source) do
    source
    |> Parser.parse_links(
      %{
        url: @page,
        referrer_url: @page,
        content_type: "text/html",
        html_tag: "a",
        assets: [],
        depth: 1,
        max_depths: 3
      },
      fn
        {_attribute, url}, _opts -> url
        {"link", _raw, _attribute, url}, _opts -> url
      end
    )
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end
end
